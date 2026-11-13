part of '../ffi_backend.dart';

mixin _FfiSessionHeartbeatOperations on _FfiBackendBase {
  @override
  Future<List<CapturedImage>> getSessionImages(int sessionId) async {
    if (_database == null) {
      throw const dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.system,
        message: 'Database not available in FFI backend',
      );
    }

    try {
      final imagesDao = ImagesDao(_database);
      final dbImages = await imagesDao.getImagesForSession(sessionId);

      return dbImages.map((dbImg) {
        return CapturedImage(
          id: dbImg.id.toString(),
          filePath: dbImg.filePath,
          capturedAt: dbImg.capturedAt,
          settings: ExposureSettings(
            exposureTime: dbImg.exposureDuration,
            gain: dbImg.gain ?? 0,
            offset: dbImg.offset ?? 0,
            binningX: dbImg.binX,
            binningY: dbImg.binY,
            filter: dbImg.filter,
            frameType: _frameTypeFromString(dbImg.frameType),
          ),
          stats: dbImg.hfr != null || dbImg.starCount != null
              ? ImageStats(
                  hfr: dbImg.hfr,
                  starCount: dbImg.starCount,
                  background: dbImg.background,
                  noise: dbImg.noise,
                )
              : null,
          targetName: null, // Would need to join with targets table
          format: _imageFormatFromString(dbImg.fileFormat),
        );
      }).toList();
    } catch (e) {
      throw _toSkotiqError(e, 'Failed to get session images');
    }
  }

  @override
  Future<Uint8List> getImageThumbnail(int imageId) async {
    if (_database == null) {
      throw const dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.system,
        message: 'Database not available in FFI backend',
      );
    }

    try {
      final imagesDao = ImagesDao(_database);
      final dbImage = await imagesDao.getImageById(imageId);

      if (dbImage == null) {
        throw dart_error.SkotiqError(
          category: dart_error.BackendErrorCategory.imaging,
          message: 'Image not found: $imageId',
        );
      }

      // Sidecar first. `ThumbnailSidecarService` writes a `.thumb.jpg` beside
      // every captured FITS, and reading that back is a ~30 KB file read
      // instead of a full-frame FITS decode. This path used to go straight to
      // the cold decode, so on the desktop a night's worth of frames cost one
      // full decode per frame per navigation even though the cache was sitting
      // right there on disk. The remote-mode HTTP handler has always read it
      // first; now both backends agree.
      final sidecarBytes = await _thumbnailSidecars.readSidecar(
        dbImage.filePath,
        stampedPath: await imagesDao.getThumbnailPath(imageId),
      );
      if (sidecarBytes != null) return sidecarBytes;

      final file = File(dbImage.filePath);
      if (!await file.exists()) {
        throw dart_error.SkotiqError(
          category: dart_error.BackendErrorCategory.io,
          message: 'Image file not found: ${dbImage.filePath}',
        );
      }

      // Cold path: no sidecar yet (a frame captured before sidecars existed, or
      // one whose sidecar was deleted). The generator reads the FITS,
      // downscales to ~512x512, auto-stretches and JPEG-encodes it on Rust's
      // blocking pool — the binding is async, so none of that runs on this
      // isolate — then caches the sidecar so this frame is cheap from now on.
      return await _thumbnailSidecars.generateAndCacheSidecar(
        imageId: imageId,
        fitsPath: dbImage.filePath,
        imagesDao: imagesDao,
      );
    } catch (e) {
      throw _toSkotiqError(e, 'Failed to get image thumbnail');
    }
  }

  @override
  Future<void> downloadImage(
    int imageId,
    String localPath, {
    void Function(double)? onProgress,
  }) async {
    if (_database == null) {
      throw const dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.system,
        message: 'Database not available in FFI backend',
      );
    }

    try {
      final imagesDao = ImagesDao(_database);
      final dbImage = await imagesDao.getImageById(imageId);

      if (dbImage == null) {
        throw dart_error.SkotiqError(
          category: dart_error.BackendErrorCategory.imaging,
          message: 'Image not found: $imageId',
        );
      }

      final sourceFile = File(dbImage.filePath);
      if (!await sourceFile.exists()) {
        throw dart_error.SkotiqError(
          category: dart_error.BackendErrorCategory.io,
          message: 'Image file not found: ${dbImage.filePath}',
        );
      }

      final destFile = File(localPath);
      await destFile.parent.create(recursive: true);

      final fileSize = await sourceFile.length();

      final sourceStream = sourceFile.openRead();
      final sink = destFile.openWrite();

      try {
        int bytesWritten = 0;
        await for (final chunk in sourceStream) {
          sink.add(chunk);
          bytesWritten += chunk.length;

          if (onProgress != null && fileSize > 0) {
            onProgress(bytesWritten / fileSize);
          }
        }
      } finally {
        await sink.close();
      }

      if (onProgress != null) {
        onProgress(1.0);
      }
    } catch (e) {
      throw _toSkotiqError(e, 'Failed to download image');
    }
  }

  FrameType _frameTypeFromString(String str) {
    switch (str.toLowerCase()) {
      case 'light':
        return FrameType.light;
      case 'dark':
        return FrameType.dark;
      case 'flat':
        return FrameType.flat;
      case 'bias':
        return FrameType.bias;
      case 'darkflat':
        return FrameType.darkFlat;
      default:
        return FrameType.light;
    }
  }

  ImageFileFormat _imageFormatFromString(String str) =>
      ImageFileFormat.fromRecord(str) ?? ImageFileFormat.fits;

  @override
  Set<DeviceType> get nativeReconnectedDeviceTypes {
    if (!bridge.NativeBridge.isNativeAvailable) return const {};
    return _NativeProcessState.nativeReconnectedDeviceTypes ??= {
      for (final type in bridge.apiNativeReconnectedDeviceTypes())
        _fromBridgeDeviceType(type),
    };
  }

  @override
  Future<(int, bool)> getDeviceHealth(String deviceId) async {
    final result = await bridge.apiGetDeviceHealth(deviceId: deviceId);
    final timestamp = result.$1.toInt();
    final isHealthy = result.$2;
    return (timestamp, isHealthy);
  }
}
