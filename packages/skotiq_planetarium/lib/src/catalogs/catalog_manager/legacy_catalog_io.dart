part of '../catalog_manager.dart';

extension CatalogManagerLegacyIo on CatalogManager {
  /// Download and install star catalog
  Future<bool> _downloadStarCatalog({
    CatalogPackage package = CatalogPackage.standard,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    return _downloadCatalog(
      source: hygStarCatalog,
      type: 'stars',
      package: package,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// Download and install DSO catalog
  Future<bool> _downloadDsoCatalog({
    CatalogPackage package = CatalogPackage.standard,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    return _downloadCatalog(
      source: openNgcCatalog,
      type: 'dso',
      package: package,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  Future<bool> _downloadCatalog({
    required CatalogSource source,
    required String type,
    required CatalogPackage package,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    if (!isInitialized) {
      throw StateError('CatalogManager not initialized');
    }

    // Ordered candidates: the GitHub release asset (integrity-verified,
    // CDN-backed) FIRST, then the upstream third-party host as a fallback.
    final baseUrl = await getCatalogBaseUrl();
    final candidates = resolveCatalogDownloadCandidates(
      source,
      baseUrl: baseUrl,
    );

    developer.log(
      '[Catalog] Starting download of ${source.name}; '
      'candidates: ${candidates.join(', ')}',
      name: 'CatalogManager',
      level: 800,
    );

    _emitProgress(
      DownloadProgress.starting(source.name, catalogKey: type),
      onProgress,
    );

    // Download into a sibling `.partial` file and only promote it onto the
    // live catalog path once the bytes are fully written and validated. This
    // keeps an existing install intact if the download fails or is abandoned
    // mid-flight, and guarantees the final path is never a truncated file.
    final filePath = path.join(catalogDirectory, source.fileName);
    final tempPath = '$filePath.partial';
    final tempFile = File(tempPath);

    try {
      final dir = Directory(catalogDirectory);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      if (candidates.isEmpty) {
        throw Exception('No download URL configured for ${source.name}');
      }

      // Try each candidate in order. A candidate fails (HTTP status, SHA-256
      // mismatch of the AS-DOWNLOADED bytes, gunzip failure, empty payload)
      // ⇒ discard its partial and fall through to the next. A user cancel is
      // terminal and propagates without trying the next candidate.
      int? bytesReceived;
      Object? lastError;
      for (var i = 0; i < candidates.length; i++) {
        final url = candidates[i];
        final isPrimary = i == 0;
        try {
          bytesReceived = await _fetchCatalogCandidate(
            source: source,
            type: type,
            url: url,
            tempFile: tempFile,
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
          developer.log(
            '[Catalog] ${source.name} downloaded from '
            '${isPrimary ? 'primary' : 'fallback'} candidate $url',
            name: 'CatalogManager',
            level: 800,
          );
          break;
        } on CatalogCancelled {
          rethrow;
        } catch (e) {
          lastError = e;
          final more = i + 1 < candidates.length;
          developer.log(
            '[Catalog] Candidate ${i + 1}/${candidates.length} for '
            '${source.name} ($url) failed: $e'
            '${more ? ' — trying next candidate' : ''}',
            name: 'CatalogManager',
            level: 900,
          );
          // Never carry a partial from a failed candidate into the next try.
          await _cleanupTempFile(tempFile);
        }
      }

      if (bytesReceived == null) {
        throw lastError ??
            Exception('All download candidates failed for ${source.name}');
      }

      // Validate the freshly written temp file before promoting it.
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

      // Count objects, then atomically promote temp -> final.
      final objectCount = await _countObjects(tempPath);
      await _promoteTempFile(tempFile, filePath);
      await _removeSupersededFiles(source);
      await _saveMetadata(type, source, package, objectCount);
      _invalidateLocalCatalogLoaders(
        stars: type == 'stars',
        dsos: type == 'dso',
      );

      developer.log(
        '[Catalog] Catalog saved with $objectCount objects ($bytesReceived bytes received)',
        name: 'CatalogManager',
        level: 800,
      );

      _emitProgress(
        DownloadProgress.complete(source.name, bytesReceived, catalogKey: type),
        onProgress,
      );

      return true;
    } on CatalogCancelled {
      developer.log(
        '[Catalog] Download of ${source.name} cancelled by user',
        name: 'CatalogManager',
        level: 800,
      );
      _emitProgress(
        DownloadProgress.cancelled(source.name, catalogKey: type),
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
        DownloadProgress.error(source.name, errorMsg, catalogKey: type),
        onProgress,
      );
      return false;
    } finally {
      // Never leave a half-written `.partial` behind, regardless of outcome
      // (on success it has already been renamed away).
      await _cleanupTempFile(tempFile);
    }
  }

  /// Fetch [source] from a single [url] into [tempFile], verifying the SHA-256
  /// of the AS-DOWNLOADED bytes against [CatalogSource.sha256] BEFORE any
  /// decompression or parse. Returns the number of bytes received on success.
  ///
  /// Throws on any failure (HTTP status, hash mismatch, gunzip failure) so the
  /// caller can fall through to the next candidate. [CatalogCancelled]
  /// propagates unchanged so a user cancel is never mistaken for a candidate
  /// failure.
  Future<int> _fetchCatalogCandidate({
    required CatalogSource source,
    required String type,
    required String url,
    required File tempFile,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    final client = CatalogManager.httpClientFactory();
    try {
      developer.log(
        '[Catalog] Sending HTTP GET request to $url',
        name: 'CatalogManager',
        level: 800,
      );

      final request = http.Request('GET', Uri.parse(url));
      final streamedResponse = await _sendCatalogRequest(client, request);

      developer.log(
        '[Catalog] Response status: ${streamedResponse.statusCode}',
        name: 'CatalogManager',
        level: 800,
      );

      if (streamedResponse.statusCode != 200) {
        throw Exception(
          'HTTP ${streamedResponse.statusCode} downloading ${source.name} from $url',
        );
      }

      final contentLength = streamedResponse.contentLength ?? 0;

      // Gzip is decided per-URL (a candidate could serve compressed or not),
      // not per-source: every HYG candidate ends in `.gz`, OpenNGC's do not.
      final isGzipped = url.endsWith('.gz');

      var bytesReceived = 0;
      var lastEmittedBytes = 0;
      // Coalesce progress so fast connections don't fire a setState per
      // network chunk (thousands/sec).
      const emitThresholdBytes = 512 * 1024;

      void onChunk(int length) {
        bytesReceived += length;
        if (bytesReceived - lastEmittedBytes < emitThresholdBytes) return;
        lastEmittedBytes = bytesReceived;
        _emitProgress(
          DownloadProgress(
            catalogName: source.name,
            catalogKey: type,
            progress: contentLength > 0 ? bytesReceived / contentLength : 0,
            bytesReceived: bytesReceived,
            totalBytes: contentLength,
            status:
                'Downloading... ${(bytesReceived / 1024 / 1024).toStringAsFixed(1)} MB',
          ),
          onProgress,
        );
      }

      // Cancellation and stall detection are driven by the guard, not by chunk
      // arrival: a stalled connection produces no chunk, so a token polled from
      // inside the loop is never read again.
      final body = _guardCatalogTransfer(
        streamedResponse.stream,
        idleTimeout: CatalogManager.streamIdleTimeout,
        cancelPollInterval: CatalogManager.cancelPollInterval,
        isCancelled: isCancelled,
      );

      if (isGzipped) {
        // Gzip needs the whole compressed payload before it can decode, so
        // buffer the (smaller) compressed bytes. Verify their SHA-256 (this is
        // the AS-DOWNLOADED hash) BEFORE decoding, then write the inflated
        // result to the temp file in one shot.
        final compressed = BytesBuilder(copy: false);
        await for (final chunk in body) {
          compressed.add(chunk);
          onChunk(chunk.length);
        }
        final compressedBytes = compressed.takeBytes();

        if (!catalogBytesMatchSha256(source.sha256, compressedBytes)) {
          throw CatalogHashMismatchException(
            expected: source.sha256,
            actual: sha256.convert(compressedBytes).toString(),
          );
        }

        developer.log(
          '[Catalog] Decompressing gzip data...',
          name: 'CatalogManager',
          level: 800,
        );
        // Hash already matched, so a decode failure is real corruption of an
        // otherwise-authentic payload — surface it (caller falls through).
        final finalBytes = Uint8List.fromList(gzip.decode(compressedBytes));
        await tempFile.writeAsBytes(finalBytes, flush: true);
      } else {
        // Stream straight to disk so we never hold the whole catalog in
        // memory, while hashing the AS-DOWNLOADED bytes incrementally so we can
        // verify before the file is promoted/parsed.
        Digest? streamedDigest;
        final digestSink = ChunkedConversionSink<Digest>.withCallback(
          (digests) => streamedDigest = digests.single,
        );
        final hashInput = sha256.startChunkedConversion(digestSink);
        final sink = tempFile.openWrite();
        try {
          await for (final chunk in body) {
            sink.add(chunk);
            hashInput.add(chunk);
            onChunk(chunk.length);
          }
        } finally {
          await sink.close();
        }
        hashInput.close();
        final downloadedHash = streamedDigest!.toString();
        if (!catalogSha256Matches(source.sha256, downloadedHash)) {
          throw CatalogHashMismatchException(
            expected: source.sha256,
            actual: downloadedHash,
          );
        }
      }

      return bytesReceived;
    } finally {
      client.close();
    }
  }

  /// Atomically replace [finalPath] with [tempFile]. POSIX `rename` overwrites
  /// in place; Windows `rename` throws if the destination exists, so remove it
  /// first there. The replacement window is microseconds on the success path.
  Future<void> _promoteTempFile(File tempFile, String finalPath) async {
    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await tempFile.rename(finalPath);
  }

  /// Drop any pre-rename copy of [source] once the current file is installed,
  /// so an upgraded install does not keep tens of MB of dead catalog around.
  /// Only legacy names are considered, never [CatalogSource.fileName].
  Future<void> _removeSupersededFiles(CatalogSource source) async {
    for (final legacy in source.legacyFileNames) {
      try {
        final file = File(path.join(catalogDirectory, legacy));
        if (await file.exists()) await file.delete();
      } catch (e) {
        developer.log(
          '[Catalog] superseded $legacy cleanup failed: $e',
          name: 'CatalogManager',
          level: 900,
        );
      }
    }
  }

  Future<void> _cleanupTempFile(File tempFile) async {
    try {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (_) {
      // Best-effort cleanup; a stale `.partial` is harmless and ignored by
      // status checks (which only look at the final catalog path).
    }
  }

  Future<int> _countObjects(String filePath) async {
    try {
      // Stream the file through a line splitter rather than reading it whole:
      // catalogs range from a few MB up to multiple GB (GLADE+ complete), and
      // readAsLines() would load and materialize the entire file in memory.
      var lineCount = 0;
      final stream = File(
        filePath,
      ).openRead().transform(utf8.decoder).transform(const LineSplitter());
      await for (final _ in stream) {
        lineCount++;
      }
      // Subtract 1 for the header row (guard against an empty file).
      return lineCount > 0 ? lineCount - 1 : 0;
    } catch (e) {
      developer.log(
        '[Catalog] Error counting objects: $e',
        name: 'CatalogManager',
        level: 900,
      );
      return 0;
    }
  }

  Future<void> _saveMetadata(
    String type,
    CatalogSource source,
    CatalogPackage package,
    int objectCount,
  ) async {
    final metaPath = path.join(catalogDirectory, '${type}_metadata.json');
    final metaFile = File(metaPath);

    // Record the SHA-256 of the installed data file so a later
    // `POST /api/catalog/verify` has an expected digest to compare against —
    // without it, verify can only ever report `no_expected_hash`. Streamed
    // from disk rather than read whole to avoid a memory spike on the
    // multi-MB catalog payloads.
    String? sha256Hash;
    final dataFile = File(path.join(catalogDirectory, source.fileName));
    if (await dataFile.exists()) {
      try {
        final digest = await sha256.bind(dataFile.openRead()).first;
        sha256Hash = digest.toString();
      } catch (e) {
        developer.log(
          '[Catalog] _saveMetadata($type): sha256 computation failed: $e',
          name: 'CatalogManager',
          level: 900,
        );
      }
    }

    final metadata = {
      'source': source.name,
      'version': source.version,
      'package': package.name,
      'objectCount': objectCount,
      'installedDate': DateTime.now().toIso8601String(),
      if (sha256Hash != null) 'sha256': sha256Hash,
    };

    await metaFile.writeAsString(jsonEncode(metadata));
  }

  /// Import a catalog from a custom location
  Future<bool> _importCatalog({
    required String sourcePath,
    required String type, // 'stars' or 'dso'
  }) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        return false;
      }

      final fileName = type == 'stars'
          ? hygStarCatalog.fileName
          : openNgcCatalog.fileName;
      final destPath = path.join(catalogDirectory, fileName);
      final tempPath = '$destPath.partial';
      final tempFile = File(tempPath);

      try {
        // Copy to a temp file first, then atomically promote, so a failed copy
        // can't clobber a good existing catalog.
        await sourceFile.copy(tempPath);
        if (await tempFile.length() == 0) {
          throw Exception('Imported file is empty');
        }

        final objectCount = await _countObjects(tempPath);
        await _promoteTempFile(tempFile, destPath);
        final source = type == 'stars' ? hygStarCatalog : openNgcCatalog;
        await _removeSupersededFiles(source);
        await _saveMetadata(type, source, CatalogPackage.complete, objectCount);
        _invalidateLocalCatalogLoaders(
          stars: type == 'stars',
          dsos: type == 'dso',
        );

        return true;
      } finally {
        await _cleanupTempFile(tempFile);
      }
    } catch (e) {
      developer.log(
        '[Catalog] Import error: $e',
        name: 'CatalogManager',
        level: 1000,
      );
      return false;
    }
  }

  /// Delete installed catalogs
  Future<void> _deleteCatalogs() async {
    final files = [
      // Legacy names included so an install made before a rename is not
      // stranded on disk (e.g. the pre-v44 hyg_v42.csv).
      ...hygStarCatalog.candidateFileNames,
      ...openNgcCatalog.candidateFileNames,
      'stars_metadata.json',
      'dso_metadata.json',
    ];

    final failures = <(String, Object)>[];
    try {
      for (final fileName in files) {
        final file = File(path.join(catalogDirectory, fileName));
        if (!await file.exists()) continue;
        try {
          await file.delete();
        } catch (e) {
          failures.add((file.path, e));
        }
      }
    } finally {
      // A partially successful cleanup still invalidates in-memory loaders;
      // otherwise searches can keep serving data from files already removed.
      _invalidateLocalCatalogLoaders(stars: true, dsos: true);
    }
    if (failures.isNotEmpty) {
      final first = failures.first;
      throw FileSystemException(
        'Could not delete ${failures.length} catalog '
        'file${failures.length == 1 ? '' : 's'}: ${first.$2}',
        first.$1,
      );
    }
  }
}
