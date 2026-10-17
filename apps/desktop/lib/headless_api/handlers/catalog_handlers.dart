// Catalog management endpoints for the headless API.
//
// Problem these handlers solve. On a fresh server install the catalog
// directory is empty — plate solving fails and target search returns
// nothing. The desktop `CatalogSettingsScreen` calls
// `CatalogManager.instance.downloadStarCatalog()` directly, which means
// when the mobile app is run as a remote client the download runs on
// the *phone*, not the server. The server's plate-solve catalog stays
// empty.
//
// Endpoints (all under /api/catalog):
//
//   GET    /api/catalog/status          — view scope; per-catalog state
//                                         on disk (size, version, hash).
//   GET    /api/catalog/available       — view scope; manifest of
//                                         catalogs available for
//                                         download.
//   POST   /api/catalog/download        — admin scope; kicks off a Job
//                                         that downloads + installs the
//                                         requested catalog server-side.
//   POST   /api/catalog/upload          — admin scope; air-gap install
//                                         from an uploaded archive/CSV.
//   POST   /api/catalog/verify          — admin scope; recompute SHA-256
//                                         of installed catalogs against
//                                         the recorded hash.
//   DELETE /api/catalog/<name>          — admin scope; uninstall a
//                                         catalog (delete its files).
//   POST   /api/catalog/reload          — admin scope; force the manager
//                                         to drop cached loaders.
//
// Catalog naming. The wire `name` is one of `stars`, `dso`,
// `annotation` — the canonical keys in [CatalogManager.knownCatalogs].
// New catalogs are added by extending that map.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../job_manager.dart';
import '../response_helpers.dart';
import '../validation.dart';

/// REST surface for [CatalogManager].
class CatalogHandlers {
  /// Job manager that owns long-running downloads. Catalog downloads
  /// can be 35+ MB over a slow link, so we expose them as Jobs
  /// — `POST /api/catalog/download` returns `{jobId}` immediately and
  /// progress flows over the WS event stream.
  final JobManager jobManager;

  /// Logging service (resolved at construction time so tests can wire
  /// a fake). Optional because most handler tests don't care about log
  /// emission; when null we no-op.
  final LoggingService? logger;

  /// Real free-disk-space query backend (the same [DiskSpaceService] the
  /// overnight watchdog uses). Optional because most handler tests don't
  /// exercise the capacity field; when null `GET /status` omits
  /// `availableSpaceBytes` instead of reporting a bogus number.
  final DiskSpaceService? diskSpaceService;

  /// Cache lifetime for `GET /api/catalog/available`. The brief asks
  /// for an hour; we honour that so a client that polls every minute
  /// during the install wizard does not hammer the upstream manifest.
  static const Duration _availableCacheTtl = Duration(hours: 1);

  /// Hard upper bound on uploaded archive size. The audit specifies
  /// 1 GiB. The route metadata layer enforces this on the
  /// `Content-Length` header; we apply a per-chunk running check on
  /// top so a chunked-transfer client cannot bypass.
  static const int catalogUploadMaxBytes = 1024 * 1024 * 1024;

  /// Cached response payload for `GET /api/catalog/available`.
  ({DateTime fetchedAt, List<AvailableCatalog> entries})? _availableCache;

  CatalogHandlers({
    required this.jobManager,
    this.logger,
    this.diskSpaceService,
  });

  CatalogManager get _manager => CatalogManager.instance;

  void _logInfo(String message) {
    logger?.info(message, source: 'CatalogHandlers');
  }

  void _logWarn(String message) {
    logger?.warning(message, source: 'CatalogHandlers');
  }

  void _logError(String message, {Object? error}) {
    logger?.error(
      message,
      source: 'CatalogHandlers',
      fields: error == null ? null : {'error': error.toString()},
    );
  }

  // GET /api/catalog/status

  /// `GET /api/catalog/status` — view-scope. Returns the per-catalog
  /// install state currently on disk.
  ///
  /// Response shape:
  /// ```json
  /// {
  ///   "catalogs": [{"name":"stars","version":"4.2","sizeBytes":12345,
  ///                 "fileCount":2,"installedAt":"...","status":"installed"}, ...],
  ///   "totalBytes": 12345,
  ///   "dataDir": "/path/to/.../catalogs",
  ///   "availableSpaceBytes": 12345
  /// }
  /// ```
  Future<Response> handleStatus(Request request) async {
    _logInfo('[API] GET /api/catalog/status');
    if (!_manager.isInitialized) {
      throw HandlerFailure(
        code: 'catalog_manager_uninitialized',
        message: 'CatalogManager has not been initialised on the server',
        statusCode: 503,
      );
    }
    final statuses = await _manager.getInstalledStatuses();
    final totalBytes = statuses.fold<int>(0, (sum, s) => sum + s.sizeBytes);

    int? availableSpaceBytes;
    final diskSpace = diskSpaceService;
    if (diskSpace != null) {
      try {
        // Real free space on the volume holding the catalog directory, so a
        // client can judge whether a multi-GB catalog download will fit. On a
        // query failure (e.g. path not yet created) we leave the field null
        // rather than fail the status call.
        final info = await diskSpace.query(_manager.catalogDirectory);
        availableSpaceBytes = info.freeBytes;
      } on DiskSpaceException catch (e) {
        _logWarn('Failed to query catalog directory free space: $e');
      }
    }

    return jsonOk({
      'catalogs': statuses.map((s) => s.toJson()).toList(growable: false),
      'totalBytes': totalBytes,
      'dataDir': _manager.catalogDirectory,
      if (availableSpaceBytes != null)
        'availableSpaceBytes': availableSpaceBytes,
    });
  }

  // GET /api/catalog/available

  /// `GET /api/catalog/available` — view-scope. Lists catalogs the
  /// server knows how to download. Cached for 1 hour to keep the
  /// upstream manifest sources unbothered when a client polls.
  Future<Response> handleAvailable(Request request) async {
    _logInfo('[API] GET /api/catalog/available');
    final cache = _availableCache;
    final now = DateTime.now();
    final List<AvailableCatalog> entries;
    final String cacheStatus;
    if (cache != null && now.difference(cache.fetchedAt) < _availableCacheTtl) {
      entries = cache.entries;
      cacheStatus = 'hit';
    } else {
      entries = await _manager.listAvailable();
      _availableCache = (fetchedAt: now, entries: entries);
      cacheStatus = 'miss';
    }
    return jsonOk({
      'available': entries.map((e) => e.toJson()).toList(growable: false),
      'cache': cacheStatus,
      'fetchedAt': (_availableCache?.fetchedAt ?? now)
          .toUtc()
          .toIso8601String(),
    });
  }

  // POST /api/catalog/download

  /// `POST /api/catalog/download` — admin scope, high-risk,
  /// audit-action `catalog_download`. Body: `{name: 'stars'}`.
  /// Returns `{jobId}` immediately; the download runs in the
  /// background and progress flows as `CatalogDownloadProgress`
  /// events on the WS event stream.
  Future<Response> handleDownload(Request request) async {
    _logInfo('[API] POST /api/catalog/download');
    if (!_manager.isInitialized) {
      throw HandlerFailure(
        code: 'catalog_manager_uninitialized',
        message: 'CatalogManager has not been initialised on the server',
        statusCode: 503,
      );
    }
    final payload = await readJsonObject(request);
    final name = requireString(payload, 'name');
    if (!CatalogManager.knownCatalogs.containsKey(name)) {
      throw BadRequestError(
        field: 'name',
        expected: 'one of: ${CatalogManager.knownCatalogs.keys.join(', ')}',
        message: '"$name" is not a known catalog',
      );
    }

    final job = jobManager.start(
      operation: 'catalog.download',
      work: (sink, cancellation) async {
        try {
          final result = await _manager.downloadAndInstall(
            name,
            onProgress: (downloaded, total) {
              if (total > 0) {
                sink.update(
                  downloaded / total,
                  'Downloading $name: '
                  '${(downloaded / 1024 / 1024).toStringAsFixed(1)} MB / '
                  '${(total / 1024 / 1024).toStringAsFixed(1)} MB',
                );
              } else {
                sink.update(
                  null,
                  'Downloading $name: '
                  '${(downloaded / 1024 / 1024).toStringAsFixed(1)} MB',
                );
              }
            },
            isCancelled: () async => cancellation.isCancelled,
          );
          return result.toJson();
        } on CatalogCancelled {
          throw const JobCancelledException('catalog download cancelled');
        } on CatalogDownloadException catch (e) {
          throw HandlerFailure(
            code: 'catalog_download_failed',
            message: e.message,
            details: {'phase': e.phase, 'name': name},
          );
        }
      },
    );

    return jsonOk({
      'jobId': job.jobId,
      'commandId': job.commandId,
      'state': job.state.wireName,
      'operation': job.operation,
    });
  }

  // POST /api/catalog/upload

  /// `POST /api/catalog/upload?name=stars&sha256=...` — admin scope,
  /// audit-action `catalog_upload`. The body is the raw catalog
  /// file (CSV) the operator transferred out-of-band. The server
  /// computes SHA-256 of the received bytes and compares with the
  /// `sha256` query parameter; mismatch → 400.
  ///
  /// We use query parameters for the metadata rather than multipart
  /// form-data because every other large-upload endpoint (`/api/backup/
  /// upload-restore`) already uses that pattern and parses cleanly with
  /// shelf's stream API. Multipart would require a separate dependency.
  Future<Response> handleUpload(Request request) async {
    _logInfo('[API] POST /api/catalog/upload');
    if (!_manager.isInitialized) {
      throw HandlerFailure(
        code: 'catalog_manager_uninitialized',
        message: 'CatalogManager has not been initialised on the server',
        statusCode: 503,
      );
    }

    final name = request.url.queryParameters['name'];
    if (name == null || name.isEmpty) {
      throw BadRequestError(
        field: 'name',
        expected: 'query string parameter',
        message: 'name query parameter is required',
      );
    }
    if (!CatalogManager.knownCatalogs.containsKey(name)) {
      throw BadRequestError(
        field: 'name',
        expected: 'one of: ${CatalogManager.knownCatalogs.keys.join(', ')}',
        message: '"$name" is not a known catalog',
      );
    }
    final expectedSha256 = request.url.queryParameters['sha256']?.trim();
    if (expectedSha256 == null || expectedSha256.isEmpty) {
      throw BadRequestError(
        field: 'sha256',
        expected: 'query string parameter',
        message: 'sha256 query parameter is required',
      );
    }
    if (expectedSha256.length != 64 ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(expectedSha256)) {
      throw BadRequestError(
        field: 'sha256',
        expected: '64 hex characters',
        message: 'sha256 must be a 64-character hex SHA-256 digest',
      );
    }

    final contentLength = int.tryParse(request.headers['content-length'] ?? '');
    if (contentLength != null && contentLength > catalogUploadMaxBytes) {
      return jsonTooLarge({
        'error': 'Catalog upload is too large',
        'maxBytes': catalogUploadMaxBytes,
      });
    }

    // Stream the upload to a temp file so a 1 GiB transfer doesn't
    // materialise in-memory. Use a unique name so concurrent uploads of
    // the same catalog don't collide.
    final tempDir = await Directory.systemTemp.createTemp('sk_catalog_upload_');
    final tempPath = p.join(
      tempDir.path,
      'upload.${DateTime.now().millisecondsSinceEpoch}',
    );
    final tempFile = File(tempPath);
    final sink = tempFile.openWrite();
    var bytesWritten = 0;
    try {
      await for (final chunk in request.read()) {
        bytesWritten += chunk.length;
        if (bytesWritten > catalogUploadMaxBytes) {
          await sink.close();
          await _bestEffortDelete(tempFile);
          await _bestEffortDelete(tempDir);
          return jsonTooLarge({
            'error': 'Catalog upload is too large',
            'maxBytes': catalogUploadMaxBytes,
          });
        }
        sink.add(chunk);
      }
      await sink.close();

      if (bytesWritten == 0) {
        await _bestEffortDelete(tempFile);
        await _bestEffortDelete(tempDir);
        throw BadRequestError(
          field: 'body',
          expected: 'non-empty file',
          message: 'Upload body is empty',
        );
      }

      try {
        final result = await _manager.installFromFile(
          name: name,
          source: tempFile,
          expectedSha256: expectedSha256,
        );
        return jsonOk({'installed': result.toJson()});
      } on CatalogHashMismatchException catch (e) {
        return jsonBadRequest({
          'error': 'sha256_mismatch',
          'expected': e.expected,
          'actual': e.actual,
        });
      } on CatalogDownloadException catch (e) {
        throw HandlerFailure(
          code: 'catalog_upload_failed',
          message: e.message,
          details: {'phase': e.phase, 'name': name},
        );
      }
    } catch (e, st) {
      _logError('[API] catalog upload error', error: e);
      if (e is BadRequestError || e is HandlerFailure) rethrow;
      throw HandlerFailure(
        code: 'catalog_upload_failed',
        message: 'Failed to install uploaded catalog',
        details: {'name': name},
        cause: e,
        stackTrace: st,
      );
    } finally {
      // Always clean up the staging area; either installFromFile
      // already consumed the bytes or we failed and the temp file is
      // an orphan.
      await _bestEffortDelete(tempFile);
      await _bestEffortDelete(tempDir);
    }
  }

  Future<void> _bestEffortDelete(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) {
        if (entity is Directory) {
          await entity.delete(recursive: true);
        } else {
          await entity.delete();
        }
      }
    } catch (e) {
      _logWarn('Failed to delete catalog upload staging ${entity.path}: $e');
    }
  }

  // POST /api/catalog/verify

  /// `POST /api/catalog/verify` — admin scope, high-risk,
  /// audit-action `catalog_verify`. Body: `{name?: 'stars'}`. Omit
  /// `name` to verify every installed catalog. Returns the per-catalog
  /// SHA-256 verification result.
  Future<Response> handleVerify(Request request) async {
    _logInfo('[API] POST /api/catalog/verify');
    if (!_manager.isInitialized) {
      throw HandlerFailure(
        code: 'catalog_manager_uninitialized',
        message: 'CatalogManager has not been initialised on the server',
        statusCode: 503,
      );
    }

    String? name;
    try {
      final raw = await request.readAsString();
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          name = optionalString(decoded, 'name');
        }
      }
    } on FormatException catch (e) {
      throw BadRequestError(
        field: 'body',
        expected: 'json_object',
        message: 'Malformed JSON: ${e.message}',
      );
    }

    if (name != null && !CatalogManager.knownCatalogs.containsKey(name)) {
      throw BadRequestError(
        field: 'name',
        expected: 'one of: ${CatalogManager.knownCatalogs.keys.join(', ')}',
        message: '"$name" is not a known catalog',
      );
    }

    final results = await _manager.verify(name: name);
    return jsonOk({'verified': results.map((k, v) => MapEntry(k, v.toJson()))});
  }

  // DELETE /api/catalog/<name>

  /// `DELETE /api/catalog/<name>` — admin scope, high-risk,
  /// audit-action `catalog_delete`. Removes the catalog data file +
  /// metadata sidecar from disk. 404 when the catalog is not installed.
  Future<Response> handleDelete(Request request, String name) async {
    _logInfo('[API] DELETE /api/catalog/$name');
    if (!_manager.isInitialized) {
      throw HandlerFailure(
        code: 'catalog_manager_uninitialized',
        message: 'CatalogManager has not been initialised on the server',
        statusCode: 503,
      );
    }
    if (!CatalogManager.knownCatalogs.containsKey(name)) {
      throw BadRequestError(
        field: 'name',
        expected: 'one of: ${CatalogManager.knownCatalogs.keys.join(', ')}',
        message: '"$name" is not a known catalog',
      );
    }
    final removed = await _manager.uninstall(name);
    if (!removed) {
      return jsonNotFound({'error': 'catalog_not_installed', 'name': name});
    }
    return jsonOk({'status': 'uninstalled', 'name': name});
  }

  // POST /api/catalog/reload

  /// `POST /api/catalog/reload` — admin scope. Drops cached loaders so
  /// subsequent searches re-parse from disk. Useful after an operator
  /// manually copies a catalog into the directory.
  Future<Response> handleReload(Request request) async {
    _logInfo('[API] POST /api/catalog/reload');
    if (!_manager.isInitialized) {
      throw HandlerFailure(
        code: 'catalog_manager_uninitialized',
        message: 'CatalogManager has not been initialised on the server',
        statusCode: 503,
      );
    }
    await _manager.reload();
    return jsonOk({'status': 'reloaded'});
  }
}
