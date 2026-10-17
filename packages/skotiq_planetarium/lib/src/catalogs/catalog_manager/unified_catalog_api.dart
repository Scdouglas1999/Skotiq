part of '../catalog_manager.dart';

extension CatalogManagerUnifiedApi on CatalogManager {
  /// Returns the on-disk state for every known catalog.
  ///
  /// Used by `GET /api/catalog/status`. Catalogs that have never been
  /// downloaded show `status: missing`. Catalogs whose metadata file is
  /// missing or corrupted show `status: partial`. SHA-256 verification is
  /// NOT run here (it would scan multi-MB files on every status poll);
  /// callers that want a deep check use `POST /api/catalog/verify`.
  Future<List<InstalledCatalogStatus>> _getInstalledCatalogStatuses() async {
    if (!isInitialized) {
      return CatalogManager.knownCatalogs.values
          .map(
            (d) => InstalledCatalogStatus(
              name: d.name,
              status: CatalogInstallStatus.missing,
            ),
          )
          .toList(growable: false);
    }

    final results = <InstalledCatalogStatus>[];
    for (final descriptor in CatalogManager.knownCatalogs.values) {
      results.add(await _statusFor(descriptor));
    }
    return results;
  }

  Future<InstalledCatalogStatus> _statusFor(
    CatalogDescriptor descriptor,
  ) async {
    final filePath = path.join(
      catalogDirectory,
      descriptor.resolveInstalledName(catalogDirectory),
    );
    final file = File(filePath);
    if (!await file.exists()) {
      return InstalledCatalogStatus(
        name: descriptor.name,
        status: CatalogInstallStatus.missing,
      );
    }

    int fileSize = 0;
    try {
      fileSize = await file.length();
    } on FileSystemException {
      return InstalledCatalogStatus(
        name: descriptor.name,
        status: CatalogInstallStatus.corrupted,
        errors: ['Failed to stat catalog file'],
      );
    }

    if (fileSize == 0) {
      return InstalledCatalogStatus(
        name: descriptor.name,
        sizeBytes: 0,
        fileCount: 1,
        status: CatalogInstallStatus.corrupted,
        errors: ['Catalog file is empty'],
      );
    }

    final metaPath = path.join(catalogDirectory, descriptor.metadataFileName);
    final metaFile = File(metaPath);
    String? version;
    DateTime? installedAt;
    DateTime? lastVerified;
    String? expectedHash;
    int? objectCount;
    if (await metaFile.exists()) {
      try {
        final raw = jsonDecode(await metaFile.readAsString());
        if (raw is Map<String, dynamic>) {
          version = raw['version'] as String?;
          installedAt = DateTime.tryParse(
            raw['installedDate']?.toString() ?? '',
          );
          lastVerified = DateTime.tryParse(
            raw['lastVerified']?.toString() ?? '',
          );
          expectedHash = raw['sha256'] as String?;
          objectCount = raw['objectCount'] is int
              ? raw['objectCount'] as int
              : (raw['objectCount'] as num?)?.toInt();
        }
      } catch (e) {
        developer.log(
          '[Catalog] _statusFor($descriptor): malformed metadata: $e',
          name: 'CatalogManager',
          level: 900,
        );
        return InstalledCatalogStatus(
          name: descriptor.name,
          sizeBytes: fileSize,
          fileCount: 1,
          status: CatalogInstallStatus.partial,
          errors: ['Metadata file is malformed'],
        );
      }
    }

    return InstalledCatalogStatus(
      name: descriptor.name,
      version: version ?? descriptor.version,
      sizeBytes: fileSize,
      fileCount: await metaFile.exists() ? 2 : 1,
      installedAt: installedAt,
      lastVerified: lastVerified,
      expectedHash: expectedHash,
      objectCount: objectCount,
      status: CatalogInstallStatus.installed,
    );
  }

  /// Lists the catalogs available for download.
  ///
  /// In the current implementation the manifest is the static
  /// [CatalogManager.knownCatalogs] map; a future revision can swap this for a live
  /// fetch from a configured catalog manifest server. The method is
  /// declared async so the wire shape does not need to change when that
  /// happens.
  ///
  /// The returned `sha256` is omitted (null) when the descriptor does
  /// not have a known canonical hash. A future manifest server can
  /// publish per-version hashes; clients then call
  /// `POST /api/catalog/verify` after downloading to confirm.
  Future<List<AvailableCatalog>> _listAvailableCatalogs() async {
    return CatalogManager.knownCatalogs.values
        .map(
          (d) => AvailableCatalog(
            name: d.name,
            displayName: d.displayName,
            version: d.version,
            description: d.description,
            downloadUrl: d.downloadUrl.isNotEmpty ? d.downloadUrl : null,
            sizeBytes: d.approximateSizeBytes,
            sha256: null,
            requiredForPlateSolve: d.requiredForPlateSolve,
          ),
        )
        .toList(growable: false);
  }

  /// Download + install a catalog by name.
  ///
  /// `name` must be one of the keys in [CatalogManager.knownCatalogs]. Throws
  /// [ArgumentError] otherwise.
  ///
  /// The bytes land in a temp file inside the catalog directory and are only
  /// renamed into place once the hash is recorded, so a partial download can
  /// never overwrite a working install.
  ///
  /// [onProgress] is invoked with `(downloadedBytes, totalBytes)`; totalBytes is
  /// -1 when the server sends no `Content-Length`. [isCancelled], when supplied,
  /// is polled on every chunk and throws [CatalogCancelled] mid-download.
  Future<CatalogInstallResult> _downloadAndInstallCatalog(
    String name, {
    String? jobId,
    void Function(int downloaded, int total)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    final descriptor = CatalogManager.knownCatalogs[name];
    if (descriptor == null) {
      throw ArgumentError.value(name, 'name', 'Unknown catalog name');
    }
    if (!isInitialized) {
      throw StateError('CatalogManager not initialized');
    }
    // Upstream fallback URL: static for stars/dso, dynamically built for the
    // GLADE+ (`annotation`) TAP query which has no release asset.
    final upstreamUrl = descriptor.downloadUrl.isNotEmpty
        ? descriptor.downloadUrl
        : (name == 'annotation'
              ? buildGladePlusUrl(AnnotationPackage.standard)
              : '');

    // Ordered candidates: GitHub release asset first, then upstream fallback.
    final baseUrl = await getCatalogBaseUrl();
    final candidates = catalogDownloadCandidates(
      githubAssetName: descriptor.githubAssetName,
      upstreamUrl: upstreamUrl,
      baseUrl: baseUrl,
    );
    if (candidates.isEmpty) {
      throw StateError('No download URL configured for catalog $name');
    }

    final dir = Directory(catalogDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final finalPath = path.join(catalogDirectory, descriptor.fileName);
    final tempPath = path.join(
      catalogDirectory,
      '.${descriptor.fileName}.partial',
    );
    final metaPath = path.join(catalogDirectory, descriptor.metadataFileName);

    _eventController.add(
      CatalogEvent.downloadStarted(
        jobId: jobId,
        name: descriptor.name,
        downloadUrl: candidates.first,
        totalBytes: descriptor.approximateSizeBytes,
      ),
    );

    try {
      // Try each candidate in order. A candidate fails (HTTP status, SHA-256
      // mismatch of the AS-DOWNLOADED bytes, gunzip failure, empty payload) ⇒
      // discard its partial and fall through to the next. A user cancel is
      // terminal and propagates without trying the next candidate.
      Uint8List? finalBytes;
      String? usedUrl;
      Object? lastError;
      for (var i = 0; i < candidates.length; i++) {
        final url = candidates[i];
        final isPrimary = i == 0;
        try {
          finalBytes = await _fetchUnifiedCandidate(
            descriptor: descriptor,
            url: url,
            tempPath: tempPath,
            jobId: jobId,
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
          usedUrl = url;
          developer.log(
            '[Catalog] ${descriptor.name} downloaded from '
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
            '[Catalog] downloadAndInstall($name) candidate '
            '${i + 1}/${candidates.length} ($url) failed: $e'
            '${more ? ' — trying next candidate' : ''}',
            name: 'CatalogManager',
            level: 900,
          );
          final t = File(tempPath);
          if (await t.exists()) {
            try {
              await t.delete();
            } catch (_) {
              // A stale partial is harmless; the next attempt overwrites it.
            }
          }
        }
      }

      if (finalBytes == null) {
        throw lastError ??
            const CatalogDownloadException(
              phase: 'download',
              message: 'All download candidates failed',
            );
      }

      // SHA-256 over the FINAL bytes (post-decompression). This is what
      // a subsequent `verify` call will re-compute. We record this in
      // the metadata sidecar so verify can compare against it.
      final actualHash = sha256.convert(finalBytes).toString();

      // Atomic rename.
      final finalFile = File(finalPath);
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await File(tempPath).rename(finalPath);

      // Object count for the metadata sidecar.
      final objectCount = await _countObjects(finalPath);
      final installedAt = DateTime.now().toUtc();
      final metadata = <String, Object?>{
        'source': descriptor.displayName,
        'name': descriptor.name,
        'version': descriptor.version,
        'sha256': actualHash,
        'objectCount': objectCount,
        'sizeBytes': finalBytes.length,
        'installedDate': installedAt.toIso8601String(),
        'downloadUrl': usedUrl,
        if (descriptor.name == 'annotation') 'package': 'standard',
      };
      await File(metaPath).writeAsString(jsonEncode(metadata));

      // Invalidate cached loaders so the next search picks up the new file.
      _invalidateLocalCatalogLoaders(
        stars: descriptor.name == 'stars',
        dsos: descriptor.name == 'dso',
      );

      _eventController.add(
        CatalogEvent.downloadComplete(
          jobId: jobId,
          name: descriptor.name,
          version: descriptor.version,
          sizeBytes: finalBytes.length,
          sha256: actualHash,
        ),
      );

      return CatalogInstallResult(
        name: descriptor.name,
        sha256: actualHash,
        sizeBytes: finalBytes.length,
        objectCount: objectCount,
        version: descriptor.version,
        installedAt: installedAt,
      );
    } on CatalogCancelled {
      // Best-effort cleanup; not throwing here because the cancel itself
      // is the signal that should propagate.
      final tempFile = File(tempPath);
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {
          // Cleanup failure is logged but does not mask the cancel.
          developer.log(
            '[Catalog] downloadAndInstall($name): failed to delete partial after cancel',
            name: 'CatalogManager',
            level: 900,
          );
        }
      }
      _eventController.add(
        CatalogEvent.downloadFailed(
          jobId: jobId,
          name: descriptor.name,
          error: 'cancelled',
          phase: 'cancelled',
        ),
      );
      rethrow;
    } catch (e) {
      // Surface failure events before rethrowing so subscribers always
      // see a terminating event for the started download.
      _eventController.add(
        CatalogEvent.downloadFailed(
          jobId: jobId,
          name: descriptor.name,
          error: e.toString(),
          phase: e is CatalogDownloadException ? e.phase : 'unknown',
        ),
      );
      final tempFile = File(tempPath);
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {
          // The partial file is now the operator's to clean up, so say so
          // loudly rather than leaving stale bytes in the catalog directory
          // unmentioned.
          developer.log(
            '[Catalog] downloadAndInstall($name): failed to delete partial after error',
            name: 'CatalogManager',
            level: 1000,
          );
        }
      }
      rethrow;
    }
  }

  /// Fetch [descriptor] from a single [url] into [tempPath], verifying the
  /// SHA-256 of the AS-DOWNLOADED bytes against [CatalogDescriptor.sha256]
  /// BEFORE any gunzip. Returns the decompressed (final) bytes on success.
  ///
  /// Throws on any failure (HTTP status, hash mismatch, gunzip failure, empty
  /// payload) so the caller can fall through to the next candidate.
  /// [CatalogCancelled] propagates unchanged. Each call owns its own HTTP
  /// client so a failed candidate never leaks a connection.
  Future<Uint8List> _fetchUnifiedCandidate({
    required CatalogDescriptor descriptor,
    required String url,
    required String tempPath,
    String? jobId,
    void Function(int downloaded, int total)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    final client = CatalogManager.httpClientFactory();
    int totalBytes = -1;
    int downloadedBytes = 0;
    DateTime lastProgressEmit = DateTime.fromMillisecondsSinceEpoch(
      0,
      isUtc: true,
    );
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await _sendCatalogRequest(client, request);
      if (response.statusCode != 200) {
        throw CatalogDownloadException(
          phase: 'http_send',
          message:
              'HTTP ${response.statusCode} downloading ${descriptor.name} from $url',
        );
      }
      totalBytes = response.contentLength ?? -1;

      // Gzip is decided per-URL (a candidate could serve compressed or not).
      final isGzipped = url.endsWith('.gz');

      // Stream into the temp file. We collect bytes for SHA when gzip is
      // off (so the on-disk file IS the hashed bytes); when gzip is on
      // we keep the compressed bytes in-memory because we need to
      // decompress before writing the final file anyway.
      final tempFile = File(tempPath);
      // Ensure no leftover partial from a prior failed run.
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      final compressedSink = isGzipped ? null : tempFile.openWrite();
      final compressedBuffer = isGzipped ? <int>[] : null;

      // Cancellation and stall detection are driven by the guard, not by chunk
      // arrival: a stalled connection produces no chunk, so a token polled from
      // inside the loop is never read again.
      final body = _guardCatalogTransfer(
        response.stream,
        idleTimeout: CatalogManager.streamIdleTimeout,
        cancelPollInterval: CatalogManager.cancelPollInterval,
        isCancelled: isCancelled,
      );

      try {
        await for (final chunk in body) {
          if (compressedSink != null) {
            compressedSink.add(chunk);
          } else {
            compressedBuffer!.addAll(chunk);
          }
          downloadedBytes += chunk.length;
          onProgress?.call(downloadedBytes, totalBytes);

          final now = DateTime.now();
          if (now.difference(lastProgressEmit).inMilliseconds >= 1000) {
            lastProgressEmit = now;
            _eventController.add(
              CatalogEvent.downloadProgress(
                jobId: jobId,
                name: descriptor.name,
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
              ),
            );
          }
        }
      } finally {
        await compressedSink?.close();
      }

      // Decompression / final-file materialisation. Verify the AS-DOWNLOADED
      // hash BEFORE any gunzip.
      Uint8List finalBytes;
      if (isGzipped) {
        final compressed = Uint8List.fromList(compressedBuffer!);
        if (!catalogBytesMatchSha256(descriptor.sha256, compressed)) {
          throw CatalogHashMismatchException(
            expected: descriptor.sha256,
            actual: sha256.convert(compressed).toString(),
          );
        }
        try {
          finalBytes = Uint8List.fromList(gzip.decode(compressed));
        } catch (e) {
          throw CatalogDownloadException(
            phase: 'decompress',
            message: 'Failed to gunzip ${descriptor.name}: $e',
          );
        }
        // Now write the decompressed payload to the temp file.
        await tempFile.writeAsBytes(finalBytes, flush: true);
      } else {
        finalBytes = await tempFile.readAsBytes();
        // For a non-gzipped source the on-disk bytes ARE the as-downloaded
        // bytes. Only hash when a canonical digest is known (GLADE+ has none),
        // so we don't scan a multi-GB TAP payload for nothing.
        if (descriptor.sha256.trim().isNotEmpty &&
            !catalogBytesMatchSha256(descriptor.sha256, finalBytes)) {
          throw CatalogHashMismatchException(
            expected: descriptor.sha256,
            actual: sha256.convert(finalBytes).toString(),
          );
        }
      }

      if (finalBytes.isEmpty) {
        throw CatalogDownloadException(
          phase: 'verify',
          message: 'Downloaded ${descriptor.name} is empty after decompression',
        );
      }

      return finalBytes;
    } finally {
      client.close();
    }
  }

  /// Install a catalog from a pre-staged file on disk. Used by the
  /// `/api/catalog/upload` air-gap flow: the operator uploads a CSV
  /// (already-decompressed) and we move/copy it into the catalog
  /// directory with a recorded hash.
  ///
  /// [expectedSha256], when supplied, is compared against the actual
  /// SHA-256 of the source file before installation; mismatch throws
  /// [CatalogHashMismatchException] and the source file is NOT moved.
  Future<CatalogInstallResult> _installCatalogFromFile({
    required String name,
    required File source,
    String? expectedSha256,
  }) async {
    final descriptor = CatalogManager.knownCatalogs[name];
    if (descriptor == null) {
      throw ArgumentError.value(name, 'name', 'Unknown catalog name');
    }
    if (!isInitialized) {
      throw StateError('CatalogManager not initialized');
    }
    if (!await source.exists()) {
      throw FileSystemException('Source file does not exist', source.path);
    }
    final dir = Directory(catalogDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final sourceBytes = await source.readAsBytes();
    if (sourceBytes.isEmpty) {
      throw const CatalogDownloadException(
        phase: 'install_from_file',
        message: 'Source file is empty',
      );
    }
    final actualHash = sha256.convert(sourceBytes).toString();
    if (expectedSha256 != null &&
        expectedSha256.toLowerCase() != actualHash.toLowerCase()) {
      throw CatalogHashMismatchException(
        expected: expectedSha256,
        actual: actualHash,
      );
    }

    final finalPath = path.join(catalogDirectory, descriptor.fileName);
    final metaPath = path.join(catalogDirectory, descriptor.metadataFileName);

    // Write to a temp file in the catalog directory then atomically
    // rename — same flow as downloadAndInstall.
    final tempPath = path.join(
      catalogDirectory,
      '.${descriptor.fileName}.upload',
    );
    final tempFile = File(tempPath);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
    await tempFile.writeAsBytes(sourceBytes, flush: true);

    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await tempFile.rename(finalPath);

    final objectCount = await _countObjects(finalPath);
    final installedAt = DateTime.now().toUtc();
    final metadata = <String, Object?>{
      'source': 'upload',
      'name': descriptor.name,
      'version': descriptor.version,
      'sha256': actualHash,
      'objectCount': objectCount,
      'sizeBytes': sourceBytes.length,
      'installedDate': installedAt.toIso8601String(),
    };
    await File(metaPath).writeAsString(jsonEncode(metadata));

    _invalidateLocalCatalogLoaders(
      stars: descriptor.name == 'stars',
      dsos: descriptor.name == 'dso',
    );

    _eventController.add(
      CatalogEvent.downloadComplete(
        jobId: null,
        name: descriptor.name,
        version: descriptor.version,
        sizeBytes: sourceBytes.length,
        sha256: actualHash,
      ),
    );

    return CatalogInstallResult(
      name: descriptor.name,
      sha256: actualHash,
      sizeBytes: sourceBytes.length,
      objectCount: objectCount,
      version: descriptor.version,
      installedAt: installedAt,
    );
  }

  /// Uninstall a catalog by name. Deletes the data file + metadata
  /// sidecar. No-op when the catalog is not installed (returns false).
  Future<bool> _uninstallCatalog(String name) async {
    final descriptor = CatalogManager.knownCatalogs[name];
    if (descriptor == null) {
      throw ArgumentError.value(name, 'name', 'Unknown catalog name');
    }
    if (!isInitialized) {
      return false;
    }

    final metaFile = File(
      path.join(catalogDirectory, descriptor.metadataFileName),
    );
    var removedAnything = false;
    for (final candidate in descriptor.candidateFileNames) {
      final dataFile = File(path.join(catalogDirectory, candidate));
      if (await dataFile.exists()) {
        await dataFile.delete();
        removedAnything = true;
      }
    }
    if (await metaFile.exists()) {
      await metaFile.delete();
      removedAnything = true;
    }
    _invalidateLocalCatalogLoaders(
      stars: descriptor.name == 'stars',
      dsos: descriptor.name == 'dso',
    );

    if (removedAnything) {
      _eventController.add(CatalogEvent.uninstalled(name: descriptor.name));
    }
    return removedAnything;
  }

  /// Re-load any cached catalog loaders. Useful when files were
  /// modified out-of-band (e.g. operator manually copied a catalog into
  /// the directory). Synchronous side: drops the in-memory loaders so
  /// the next search re-parses the file from disk.
  Future<void> _reloadCatalogs() async {
    _invalidateLocalCatalogLoaders(stars: true, dsos: true);
    _eventController.add(const CatalogEvent.reloaded());
  }

  /// Verify the SHA-256 of installed catalogs against the value
  /// recorded in their metadata sidecar.
  ///
  /// [name] selects a single catalog; null means "verify every
  /// installed catalog". A catalog that is not installed surfaces as
  /// `ok: false` with `error: 'not_installed'`.
  Future<Map<String, CatalogVerifyResult>> _verifyCatalogs({
    String? name,
  }) async {
    if (!isInitialized) {
      throw StateError('CatalogManager not initialized');
    }
    final targets = <CatalogDescriptor>[];
    if (name == null) {
      targets.addAll(CatalogManager.knownCatalogs.values);
    } else {
      final descriptor = CatalogManager.knownCatalogs[name];
      if (descriptor == null) {
        throw ArgumentError.value(name, 'name', 'Unknown catalog name');
      }
      targets.add(descriptor);
    }

    final results = <String, CatalogVerifyResult>{};
    for (final descriptor in targets) {
      results[descriptor.name] = await _verifyOne(descriptor);
    }
    return results;
  }

  Future<CatalogVerifyResult> _verifyOne(CatalogDescriptor descriptor) async {
    final dataFile = File(
      path.join(
        catalogDirectory,
        descriptor.resolveInstalledName(catalogDirectory),
      ),
    );
    if (!await dataFile.exists()) {
      const result = CatalogVerifyResult(
        ok: false,
        expectedHash: null,
        actualHash: null,
        errors: ['not_installed'],
      );
      _eventController.add(
        CatalogEvent.verified(
          name: descriptor.name,
          ok: false,
          errors: result.errors,
        ),
      );
      return result;
    }

    String? expectedHash;
    final metaFile = File(
      path.join(catalogDirectory, descriptor.metadataFileName),
    );
    if (await metaFile.exists()) {
      try {
        final raw = jsonDecode(await metaFile.readAsString());
        if (raw is Map<String, dynamic>) {
          expectedHash = raw['sha256'] as String?;
        }
      } catch (e) {
        developer.log(
          '[Catalog] _verifyOne(${descriptor.name}): malformed metadata: $e',
          name: 'CatalogManager',
          level: 900,
        );
      }
    }

    // Stream the file rather than reading it whole — catalog files are
    // multi-MB and verifying them all at once would spike memory.
    final digest = await sha256.bind(dataFile.openRead()).first;
    final actualHash = digest.toString();

    final ok =
        expectedHash != null &&
        expectedHash.toLowerCase() == actualHash.toLowerCase();
    final errors = <String>[];
    if (expectedHash == null) {
      errors.add('no_expected_hash');
    } else if (!ok) {
      errors.add('hash_mismatch');
    }

    // Update lastVerified in the metadata sidecar.
    if (await metaFile.exists()) {
      try {
        final raw = jsonDecode(await metaFile.readAsString());
        if (raw is Map<String, dynamic>) {
          raw['lastVerified'] = DateTime.now().toUtc().toIso8601String();
          await metaFile.writeAsString(jsonEncode(raw));
        }
      } catch (e) {
        developer.log(
          '[Catalog] _verifyOne(${descriptor.name}): failed to update lastVerified: $e',
          name: 'CatalogManager',
          level: 900,
        );
      }
    }

    final result = CatalogVerifyResult(
      ok: ok,
      expectedHash: expectedHash,
      actualHash: actualHash,
      errors: errors,
    );
    _eventController.add(
      CatalogEvent.verified(name: descriptor.name, ok: ok, errors: errors),
    );
    return result;
  }
}
