part of '../catalog_manager.dart';

extension CatalogManagerAnnotationIo on CatalogManager {
  /// Check if annotation catalog is installed
  Future<CatalogStatus> _getAnnotationCatalogStatus() async {
    if (!isInitialized) return CatalogStatus.notInstalled();
    return _getCatalogStatus(gladePlusCatalog.fileName, 'annotation');
  }

  /// Download and install annotation catalog (GLADE+ via VizieR TAP)
  Future<bool> _downloadAnnotationCatalogEntry({
    AnnotationPackage package = AnnotationPackage.standard,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    return _downloadAnnotationCatalog(
      source: gladePlusCatalog,
      package: package,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  Future<bool> _downloadAnnotationCatalog({
    required CatalogSource source,
    required AnnotationPackage package,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    // Build the VizieR TAP URL based on the selected package tier
    final downloadUrl = buildGladePlusUrl(package);

    developer.log(
      '[Catalog] Starting download of ${source.name} (${package.displayName} tier)',
      name: 'CatalogManager',
      level: 800,
    );
    developer.log(
      '[Catalog] VizieR TAP URL: $downloadUrl',
      name: 'CatalogManager',
      level: 800,
    );

    _emitProgress(
      DownloadProgress.starting(source.name, catalogKey: 'annotation'),
      onProgress,
    );

    // Download to a `.partial` sibling and atomically promote on success so an
    // existing annotation catalog survives a failed or abandoned download.
    final filePath = path.join(catalogDirectory, source.fileName);
    final tempPath = '$filePath.partial';
    final tempFile = File(tempPath);

    try {
      if (!isInitialized) {
        throw StateError('CatalogManager not initialized');
      }

      final dir = Directory(catalogDirectory);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final client = CatalogManager.httpClientFactory();

      try {
        developer.log(
          '[Catalog] Sending HTTP GET request to VizieR TAP...',
          name: 'CatalogManager',
          level: 800,
        );

        final request = http.Request('GET', Uri.parse(downloadUrl));
        final streamedResponse = await _sendCatalogRequest(client, request);

        developer.log(
          '[Catalog] Response status: ${streamedResponse.statusCode}',
          name: 'CatalogManager',
          level: 800,
        );

        if (streamedResponse.statusCode != 200) {
          final errorMsg =
              'HTTP ${streamedResponse.statusCode}: Failed to download from VizieR TAP';
          developer.log(errorMsg, name: 'CatalogManager', level: 1000);
          _emitProgress(
            DownloadProgress.error(
              source.name,
              errorMsg,
              catalogKey: 'annotation',
            ),
            onProgress,
          );
          return false;
        }

        final contentLength = streamedResponse.contentLength ?? 0;
        developer.log(
          '[Catalog] Writing to $tempPath, expected size: $contentLength bytes',
          name: 'CatalogManager',
          level: 800,
        );

        // VizieR TAP returns CSV directly (not gzipped). Stream straight to
        // disk — the "complete" tier is multiple GB and must not be buffered.
        var bytesReceived = 0;
        var lastEmittedBytes = 0;
        const emitThresholdBytes = 512 * 1024;
        // Cancellation and stall detection are driven by the guard, not by
        // chunk arrival: a stalled connection produces no chunk, so a token
        // polled from inside the loop is never read again. This tier can be
        // multiple GB, so a mid-transfer stall is the likeliest failure here.
        final body = _guardCatalogTransfer(
          streamedResponse.stream,
          idleTimeout: CatalogManager.streamIdleTimeout,
          cancelPollInterval: CatalogManager.cancelPollInterval,
          isCancelled: isCancelled,
        );

        final sink = tempFile.openWrite();
        try {
          await for (final chunk in body) {
            sink.add(chunk);
            bytesReceived += chunk.length;
            if (bytesReceived - lastEmittedBytes < emitThresholdBytes) {
              continue;
            }
            lastEmittedBytes = bytesReceived;

            _emitProgress(
              DownloadProgress(
                catalogName: source.name,
                catalogKey: 'annotation',
                progress: contentLength > 0 ? bytesReceived / contentLength : 0,
                bytesReceived: bytesReceived,
                totalBytes: contentLength,
                status:
                    'Downloading... ${(bytesReceived / 1024 / 1024).toStringAsFixed(1)} MB',
              ),
              onProgress,
            );
          }
        } finally {
          await sink.close();
        }

        if (!await tempFile.exists()) {
          throw Exception('File was not created after download');
        }
        final fileSize = await tempFile.length();
        if (fileSize == 0) {
          throw Exception('Downloaded file is empty');
        }

        developer.log(
          '[Catalog] Temp file verified: $fileSize bytes',
          name: 'CatalogManager',
          level: 800,
        );

        final objectCount = await _countObjects(tempPath);
        await _promoteTempFile(tempFile, filePath);
        await _saveAnnotationMetadata(source, package, objectCount);

        developer.log(
          '[Catalog] Annotation catalog saved with $objectCount objects',
          name: 'CatalogManager',
          level: 800,
        );

        _emitProgress(
          DownloadProgress.complete(
            source.name,
            bytesReceived,
            catalogKey: 'annotation',
          ),
          onProgress,
        );

        return true;
      } finally {
        client.close();
      }
    } on CatalogCancelled {
      developer.log(
        '[Catalog] Download of ${source.name} cancelled by user',
        name: 'CatalogManager',
        level: 800,
      );
      _emitProgress(
        DownloadProgress.cancelled(source.name, catalogKey: 'annotation'),
        onProgress,
      );
      return false;
    } catch (e, stackTrace) {
      final errorMsg = 'Download error: $e';
      developer.log(
        errorMsg,
        name: 'CatalogManager',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );

      _emitProgress(
        DownloadProgress.error(source.name, errorMsg, catalogKey: 'annotation'),
        onProgress,
      );
      return false;
    } finally {
      await _cleanupTempFile(tempFile);
    }
  }

  Future<void> _saveAnnotationMetadata(
    CatalogSource source,
    AnnotationPackage package,
    int objectCount,
  ) async {
    final metaPath = path.join(catalogDirectory, 'annotation_metadata.json');
    final metaFile = File(metaPath);

    final metadata = {
      'source': source.name,
      'version': source.version,
      'package': package.name,
      'magnitudeLimit': package.magnitudeLimit,
      'objectCount': objectCount,
      'installedDate': DateTime.now().toIso8601String(),
    };

    await metaFile.writeAsString(jsonEncode(metadata));
  }

  /// Import annotation catalog from a local file
  /// Accepts CSV files with galaxy data (e.g., from VizieR GLADE+ export)
  /// Expected format: CSV with columns for RA, Dec, magnitude, etc.
  Future<bool> _importAnnotationCatalog({
    required String sourcePath,
    AnnotationPackage package = AnnotationPackage.standard,
  }) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        developer.log(
          '[Catalog] Import source file not found: $sourcePath',
          name: 'CatalogManager',
          level: 900,
        );
        return false;
      }

      final destPath = path.join(catalogDirectory, gladePlusCatalog.fileName);
      final tempPath = '$destPath.partial';
      final tempFile = File(tempPath);

      try {
        // Copy to temp first, then atomically promote, so a failed copy can't
        // clobber a good existing annotation catalog.
        await sourceFile.copy(tempPath);
        if (await tempFile.length() == 0) {
          throw Exception('Imported file is empty');
        }

        final objectCount = await _countObjects(tempPath);
        await _promoteTempFile(tempFile, destPath);
        await _saveAnnotationMetadata(gladePlusCatalog, package, objectCount);

        developer.log(
          '[Catalog] Annotation catalog imported: $objectCount objects from $sourcePath',
          name: 'CatalogManager',
          level: 800,
        );
        return true;
      } finally {
        await _cleanupTempFile(tempFile);
      }
    } catch (e) {
      developer.log(
        '[Catalog] Import annotation catalog error: $e',
        name: 'CatalogManager',
        level: 1000,
      );
      return false;
    }
  }

  /// Delete annotation catalog
  Future<void> _deleteAnnotationCatalog() async {
    final files = [gladePlusCatalog.fileName, 'annotation_metadata.json'];

    final failures = <(String, Object)>[];
    for (final fileName in files) {
      final file = File(path.join(catalogDirectory, fileName));
      if (!await file.exists()) continue;
      try {
        await file.delete();
      } catch (e) {
        failures.add((file.path, e));
      }
    }
    if (failures.isNotEmpty) {
      final first = failures.first;
      throw FileSystemException(
        'Could not delete ${failures.length} annotation catalog '
        'file${failures.length == 1 ? '' : 's'}: ${first.$2}',
        first.$1,
      );
    }
  }

  /// Get installed annotation package info
  Future<AnnotationPackage?> _getInstalledAnnotationPackage() async {
    final status = await getAnnotationCatalogStatus();
    return status.installedPackage != null
        ? AnnotationPackage.values.firstWhere(
            (p) => p.name == status.installedPackage!.name,
            orElse: () => AnnotationPackage.standard,
          )
        : null;
  }
}
