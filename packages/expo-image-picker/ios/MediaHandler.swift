// Copyright 2022-present 650 Industries. All rights reserved.

import ExpoModulesCore
import MobileCoreServices
import Photos
import PhotosUI
import UniformTypeIdentifiers

internal struct MediaHandler {
  internal weak var fileSystem: EXFileSystemInterface?
  internal let options: ImagePickerOptions

  internal func handleMedia(_ mediaInfo: MediaInfo) async throws -> AssetInfo {
    let mediaType: String? = mediaInfo[UIImagePickerController.InfoKey.mediaType] as? String

    switch mediaType {
    case UTType.image.identifier:
      return try await handleImage(mediaInfo: mediaInfo)
    case UTType.movie.identifier:
      return try await handleVideo(mediaInfo: mediaInfo)
    default:
      throw InvalidMediaTypeException(mediaType)
    }
  }

  internal func handleMultipleMedia(_ selection: [PHPickerResult]) async throws -> [AssetInfo] {
    // Process each selected asset in parallel.
    // TaskGroup is faster than the old serial asyncMap and still
    // propagates the first thrown error and preserves result order.
    return try await withThrowingTaskGroup(of: AssetInfo.self) { group in
      // Add a task for each selected item
      for selectedItem in selection {
        group.addTask {
          let itemProvider = selectedItem.itemProvider

          if itemProvider.canLoadObject(ofClass: PHLivePhoto.self) && options.mediaTypes.contains(.livePhotos) {
            return try await handleLivePhoto(from: selectedItem)
          }
          if itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return try await handleImage(from: selectedItem)
          }
          if itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return try await handleVideo(from: selectedItem)
          }
          throw InvalidMediaTypeException(itemProvider.registeredTypeIdentifiers.first)
        }
      }

      var results: [AssetInfo] = []
      for try await asset in group {
        results.append(asset)
      }
      return results
    }
  }

  // MARK: - Image

  private func handleImage(mediaInfo: MediaInfo) async throws -> AssetInfo {
    do {
      guard let image = ImageUtils.readImageFrom(mediaInfo: mediaInfo, shouldReadCroppedImage: options.allowsEditing) else {
        throw FailedToReadImageException()
      }

      let (imageData, fileExtension) = try ImageUtils.readDataAndFileExtension(
        image: image,
        mediaInfo: mediaInfo,
        options: options
      )

      let targetUrl = try generateUrl(withFileExtension: fileExtension)
      let mimeType = getMimeType(from: targetUrl.pathExtension)

      // no modification requested
      let imageModified = options.allowsEditing || options.quality < 1
      let fileWasCopied = !imageModified && ImageUtils.tryCopyingOriginalImageFrom(mediaInfo: mediaInfo, to: targetUrl)
      if !fileWasCopied {
        try ImageUtils.write(imageData: imageData, to: targetUrl)
      }

      // as calling this already requires media library permission, we can access it here
      // if user gave limited permissions, in the worst case this will be null
      let asset = mediaInfo[.phAsset] as? PHAsset
      var fileName = asset?.value(forKey: "filename") as? String
      // Extension will change to png when editing BMP files, reflect that change in fileName
      if let unwrappedName = fileName {
        fileName = replaceFileExtension(fileName: unwrappedName, targetExtension: fileExtension.lowercased())
      }
      let fileSize = getFileSize(from: targetUrl)

      let base64 = options.base64 ? try ImageUtils.readBase64From(imageData: imageData, orImageFileUrl: targetUrl, tryReadingFile: fileWasCopied) : nil

      let exif = options.exif ? await ImageUtils.readExifFrom(mediaInfo: mediaInfo) : nil

      // Read dimensions using ImageUtils to avoid full decode in the fast path.
      var dimensions = ImageUtils.readSizeFrom(url: targetUrl)
      if dimensions == nil {
        // Fallback: decode minimally with UIImage to get size.
        if let img = UIImage(contentsOfFile: targetUrl.path) {
          dimensions = CGSize(width: img.size.width, height: img.size.height)
        }
      }
      let size = dimensions ?? .zero

      return AssetInfo(
        assetId: asset?.localIdentifier,
        uri: targetUrl.absoluteString,
        width: Double(size.width),
        height: Double(size.height),
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
        base64: base64,
        exif: exif
      )
    } catch let exception as Exception {
      throw exception
    } catch {
      throw UnexpectedException(error)
    }
  }

  private func handleImage(from selectedImage: PHPickerResult) async throws -> AssetInfo {
    let itemProvider = selectedImage.itemProvider

    // Fast-path: copy original file when no processing is required and current representation is requested.
    let fastPath = !options.allowsEditing && options.quality >= 1 && options.preferredAssetRepresentationMode == .current

    if fastPath {
      // Attempt to obtain original file URL
      if let targetUrl = try? await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<URL, Error>) in
        itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
          guard let srcUrl = url else {
            return continuation.resume(throwing: error ?? FailedToReadImageException())
          }
          do {
            let destUrl = try generateUrl(withFileExtension: "." + srcUrl.pathExtension)
            try FileManager.default.copyItem(at: srcUrl, to: destUrl)
            continuation.resume(returning: destUrl)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }) {
        let cachedUrl = targetUrl
        let fileExtension = "." + cachedUrl.pathExtension

        // Read dimensions using ImageUtils to avoid full decode
        var dimensions = ImageUtils.readSizeFrom(url: cachedUrl)
        if dimensions == nil {
          // Fallback: decode minimally with UIImage to get size.
          if let img = UIImage(contentsOfFile: cachedUrl.path) {
            dimensions = CGSize(width: img.size.width, height: img.size.height)
          }
        }
        let size = dimensions ?? .zero
        let fileSize = getFileSize(from: cachedUrl)
        let mimeType = getMimeType(from: cachedUrl.pathExtension)
        let fileName = itemProvider.suggestedName.map { $0 + fileExtension }

        // Conditionally read raw data only if needed to avoid unnecessary I/O
        var rawData: Data?
        if options.base64 || options.exif {
          rawData = try? Data(contentsOf: cachedUrl)
        }

        let base64 = options.base64 ? rawData?.base64EncodedString() : nil
        let exif = options.exif ? (rawData.flatMap { ImageUtils.readExifFrom(data: $0) }) : nil

        log.info("expo-image-picker: Using fast path for image – no slow path available.")

        return AssetInfo(
          assetId: selectedImage.assetIdentifier,
          uri: cachedUrl.absoluteString,
          width: Double(size.width),
          height: Double(size.height),
          fileName: fileName,
          fileSize: fileSize,
          mimeType: mimeType,
          base64: base64,
          exif: exif
        )
      }
    }

    log.info("expo-image-picker: Using slow path for image – no fast path available.")

    // If fast copy path failed or was not available because of the props
    // use slow path (existing implementation)
    let rawData = try await itemProvider.loadImageDataRepresentation()

    guard let image = UIImage(data: rawData) else {
      throw Exception(name: "FailedCreatingUIImage", description: "")
    }

    let (imageData, fileExtension) = try ImageUtils.readDataAndFileExtension(
      image: image,
      rawData: rawData,
      itemProvider: itemProvider,
      options: options
    )

    let mimeType = getMimeType(from: String(fileExtension.dropFirst()))
    let targetUrl = try generateUrl(withFileExtension: fileExtension)
    try ImageUtils.write(imageData: imageData, to: targetUrl)
    let fileSize = getFileSize(from: targetUrl)
    let fileName = itemProvider.suggestedName.map { $0 + fileExtension }

    // We need to get EXIF from original image data, as it is being lost in UIImage
    let exif = options.exif ? ImageUtils.readExifFrom(data: rawData) : nil
    let base64 = options.base64 ? imageData?.base64EncodedString() : nil

    var dimensions = ImageUtils.readSizeFrom(url: targetUrl)
    if dimensions == nil {
      // Fallback: decode minimally with UIImage to get size.
      if let img = UIImage(contentsOfFile: targetUrl.path) {
        dimensions = CGSize(width: img.size.width, height: img.size.height)
      }
    }
    let size = dimensions ?? .zero

    return AssetInfo(
      assetId: selectedImage.assetIdentifier,
      uri: targetUrl.absoluteString,
      width: Double(size.width),
      height: Double(size.height),
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      base64: base64,
      exif: exif
    )
  }

  // Unlike the case of regular images, we have to operate on original data of the image in order to preserve the exif data,
  // otherwise it won't be possible to connect the image and video into a `PHLivePhoto` after reading it from the cache directory later.
  // As a result a live photo photo cannot be compressed or edited.
  private func handleLivePhoto(from selectedImage: PHPickerResult) async throws -> AssetInfo {
    let itemProvider = selectedImage.itemProvider
    let livePhotoObject = try await itemProvider.loadObject(ofClass: PHLivePhoto.self)
    guard let livePhoto = livePhotoObject as? PHLivePhoto else {
      throw FailedToPickLivePhotoException()
    }
    let assetResources = PHAssetResource.assetResources(for: livePhoto)
    guard
      let photoResource = assetResources.first(where: { $0.type == .photo }),
      let videoResource = assetResources.first(where: { $0.type == .pairedVideo })
    else {
      throw FailedToPickLivePhotoException()
    }

    let fileName = photoResource.originalFilename
    let pairedVideoFileName = videoResource.originalFilename
    let photoFileExtension = getFileExtension(from: fileName)
    let pairedVideoFileExtension = getFileExtension(from: pairedVideoFileName)
    let (photoUrl, pairedVideoUrl) = try generatePairedUrls(photoFileExtension: photoFileExtension, videoFileExtension: pairedVideoFileExtension)

    let imageData = try await PHAssetResourceManager.default().requestData(for: photoResource, options: nil)

    try await PHAssetResourceManager.default().writeData(for: photoResource, toFile: photoUrl, options: nil)
    try await PHAssetResourceManager.default().writeData(for: videoResource, toFile: pairedVideoUrl, options: nil)

    let fileSize = getFileSize(from: photoUrl)
    let mimeType = getMimeType(from: photoUrl.pathExtension)
    let base64 = options.base64 ? imageData.base64EncodedString() : nil
    let exif = options.exif ? ImageUtils.readExifFrom(data: imageData) : nil

    let pairedVideoAssetInfo = try getPairedAssetInfo(from: videoResource, fileUrl: pairedVideoUrl, assetId: selectedImage.assetIdentifier)

    return AssetInfo(
      assetId: selectedImage.assetIdentifier,
      type: "livePhoto",
      uri: photoUrl.absoluteString,
      width: livePhoto.size.width,
      height: livePhoto.size.height,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      base64: base64,
      exif: exif,
      pairedVideoAsset: pairedVideoAssetInfo
    )
  }

  private func getPairedAssetInfo(from videoResource: PHAssetResource, fileUrl: URL, assetId: String?) throws -> AssetInfo {
    let fileName = videoResource.originalFilename
    guard let dimensions = VideoUtils.readSizeFrom(url: fileUrl) else {
      throw FailedToReadVideoSizeException()
    }
    let duration = VideoUtils.readDurationFrom(url: fileUrl)
    let mimeType = getMimeType(from: fileUrl.pathExtension)
    let fileSize = getFileSize(from: fileUrl)

    return AssetInfo(
      assetId: assetId,
      type: "pairedVideo",
      uri: fileUrl.absoluteString,
      width: dimensions.width,
      height: dimensions.height,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      duration: duration
    )
  }

  private func getMimeType(from pathExtension: String) -> String? {
    return UTType(filenameExtension: pathExtension)?.preferredMIMEType
  }

  // MARK: - Video

  func handleVideo(mediaInfo: MediaInfo) async throws -> AssetInfo {
    guard let pickedVideoUrl = VideoUtils.readVideoUrlFrom(mediaInfo: mediaInfo) else {
      throw FailedToReadVideoException()
    }

    if options.videoExportPreset == .passthrough {
      log.info("expo-image-picker: Using fast path for legacy video – passthrough without transcoding.")
    }

    let targetUrl = try generateUrl(withFileExtension: ".mov")

    try VideoUtils.tryCopyingVideo(at: pickedVideoUrl, to: targetUrl)

    guard let dimensions = VideoUtils.readSizeFrom(url: targetUrl) else {
      throw FailedToReadVideoSizeException()
    }

    // If video was edited (the duration is affected) then read the duration from the original edited video.
    // Otherwise read the duration from the target video file.
    // TODO: (@bbarthec): inspect whether it makes sense to read duration from two different assets
    let videoUrlToReadDurationFrom = self.options.allowsEditing ? pickedVideoUrl : targetUrl
    let duration = VideoUtils.readDurationFrom(url: videoUrlToReadDurationFrom)

    let asset = mediaInfo[.phAsset] as? PHAsset
    let mimeType = getMimeType(from: targetUrl.pathExtension)
    let fileName = asset?.value(forKey: "filename") as? String
    let fileSize = getFileSize(from: targetUrl)

    return AssetInfo(
      assetId: asset?.localIdentifier,
      type: "video",
      uri: targetUrl.absoluteString,
      width: dimensions.width,
      height: dimensions.height,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      duration: duration
    )
  }

  private func handleVideo(from selectedVideo: PHPickerResult) async throws -> AssetInfo {
    // Fast path for videos where only metadata was adjusted in Photos (no re-encode)
    if #available(iOS 15.0, *) {
      if let assetId = selectedVideo.assetIdentifier,
         let fs = self.fileSystem,
         let fastUrl = try? await VideoUtils.tryCopyingOriginalVideoFromMetadataOnlyAsset(assetId: assetId, fileSystem: fs) {
        log.info("expo-image-picker: Using metadata-only fast path for video – original resource copied without export.")

        let mimeType = getMimeType(from: fastUrl.pathExtension)
        let fileName = selectedVideo.itemProvider.suggestedName

        return try buildVideoResult(for: fastUrl, withName: fileName, mimeType: mimeType, assetId: assetId)
      }
    }

    let videoUrl = try await VideoUtils.loadVideoRepresentation(provider: selectedVideo.itemProvider) { tmpUrl in
      // We need to copy the result into a place that we control, because the picker
      // can remove the original file during conversion.
      return try generateUrl(withFileExtension: ".\(tmpUrl.pathExtension)")
    }

    // Decide whether we need to transcode.
    let isPassthrough = options.videoExportPreset == .passthrough

    // Keep original extension for passthrough, otherwise use mp4.
    let originalFileExtension = ".\(videoUrl.pathExtension)"
    let transcodeFileExtension = isPassthrough ? originalFileExtension : ".mp4"
    let transcodeFileType: AVFileType = .mp4

    let finalUrl: URL
    if isPassthrough {
      log.info("expo-image-picker: Using fast path for video – passthrough without transcoding.")
      finalUrl = videoUrl
    } else {
      log.info("expo-image-picker: Slow path for video – transcoding with preset \(options.videoExportPreset)")
      // Create destination url for transcoded video
      let transcodedUrl = try generateUrl(withFileExtension: transcodeFileExtension)
      finalUrl = try await VideoUtils.transcodeVideoAsync(
        sourceAssetUrl: videoUrl,
        destinationUrl: transcodedUrl,
        outputFileType: transcodeFileType,
        exportPreset: options.videoExportPreset
      )
    }

    let mimeType = getMimeType(from: finalUrl.pathExtension)
    let fileName = selectedVideo.itemProvider.suggestedName.map { $0 + transcodeFileExtension }

    return try buildVideoResult(for: finalUrl, withName: fileName, mimeType: mimeType, assetId: selectedVideo.assetIdentifier)
  }

  // MARK: - utils

  private func replaceFileExtension(fileName: String, targetExtension: String) -> String {
    if !fileName.lowercased().hasSuffix(targetExtension.lowercased()) {
      return deleteFileExtension(fileName: fileName) + targetExtension
    }
    return fileName
  }

  private func deleteFileExtension(fileName: String) -> String {
    var components = fileName.components(separatedBy: ".")
    guard components.count > 1 else {
      return fileName
    }
    components.removeLast()
    return components.joined(separator: ".")
  }

  private func generateUrl(withFileExtension: String) throws -> URL {
    guard let fileSystem = self.fileSystem else {
      throw FileSystemModuleNotFoundException()
    }
    let directory = fileSystem.cachesDirectory.appending(
      fileSystem.cachesDirectory.hasSuffix("/") ? "" : "/" + "ImagePicker"
    )
    let path = fileSystem.generatePath(inDirectory: directory, withExtension: withFileExtension)
    return URL(fileURLWithPath: path)
  }

  private func generatePairedUrls(photoFileExtension: String, videoFileExtension: String) throws -> (URL, URL) {
    let parsedVideoFileExtension = videoFileExtension.starts(with: ".") ? String(videoFileExtension.dropFirst()) : videoFileExtension
    let photoUrl = try generateUrl(withFileExtension: photoFileExtension)
    let baseUrl = photoUrl.deletingLastPathComponent()
    let filename = photoUrl.deletingPathExtension().lastPathComponent
    let videoUrl = baseUrl.appendingPathComponent(filename).appendingPathExtension(parsedVideoFileExtension)
    return (photoUrl, videoUrl)
  }

  private func buildVideoResult(for videoUrl: URL, withName fileName: String?, mimeType: String?, assetId: String?) throws -> AssetInfo {
    guard let size = VideoUtils.readSizeFrom(url: videoUrl) else {
      throw FailedToReadVideoSizeException()
    }
    let duration = VideoUtils.readDurationFrom(url: videoUrl)
    let fileSize = getFileSize(from: videoUrl)

    return AssetInfo(
      assetId: assetId,
      type: "video",
      uri: videoUrl.absoluteString,
      width: size.width,
      height: size.height,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      duration: duration
    )
  }

  private func getFileSize(from fileUrl: URL) -> Int? {
    do {
      let resources = try fileUrl.resourceValues(forKeys: [.fileSizeKey])
      return resources.fileSize
    } catch {
      log.error("Failed to get file size for \(fileUrl.absoluteString)")
      return nil
    }
  }

  private func getFileExtension(from fileName: String) -> String {
    return ".\(URL(fileURLWithPath: fileName).pathExtension)"
  }
}

fileprivate extension PHAssetResourceManager {
  func requestData(for assetResource: PHAssetResource, options: PHAssetResourceRequestOptions?) async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
      var data = Data()
      let dataHandler = { (dataBatch: Data) in
        data.append(dataBatch)
      }
      let completionHandler = {(error: Error?) in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume(returning: data)
      }

      self.requestData(for: assetResource, options: options, dataReceivedHandler: dataHandler, completionHandler: completionHandler)
    }
  }
}
