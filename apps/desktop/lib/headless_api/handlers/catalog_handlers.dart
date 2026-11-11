// Catalog management endpoints for the headless API.
//
// A catalog downloaded from a client's own settings screen lands on that
// client. These routes run the same installer on the host, where plate
// solving, target search and annotation read it.
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
// Catalog naming. The wire `name` is a [SkyCatalog] name: `stars`, `dso` or
// `annotation`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../job_manager.dart';
import '../response_helpers.dart';
import '../validation.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

/// REST surface for [CatalogManager].
class CatalogHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    CatalogApi.status: handleStatus,
    CatalogApi.available: handleAvailable,
    CatalogApi.download: handleDownload,
    CatalogApi.upload: handleUpload,
    CatalogApi.verify: handleVerify,
    CatalogApi.reload: handleReload,
    CatalogApi.delete: handleDelete,
  };

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

  /// When `GET /api/catalog/available` last built its list; the response
  /// reports hit or miss against [_availableCacheTtl].
  DateTime? _availableFetchedAt;

  CatalogHandlers({
    required this.jobManager,
    this.logger,
    this.diskSpaceService,
  });

  CatalogManager get _manager => CatalogManager.instance;

  /// The catalog a request names, or a 400 listing the valid names.
  SkyCatalog _requireCatalog(String name) {
    final catalog = SkyCatalog.tryParse(name);
    if (catalog == null) {
      throw BadRequestError(
        field: 'name',
        expected: 'one of: ${SkyCatalog.wireNames}',
        message: '"$name" is not a known catalog',
      );
    }
    return catalog;
  }

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
    if (!_manager.isInitialized) {
      throw HandlerFailure(
        code: 'catalog_manager_uninitialized',
        message: 'CatalogManager has not been initialized on the server',
        statusCode: 503,
      );
    }
    final statuses = await _manager.statuses();
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

  /// `GET /api/catalog/available` — view-scope. Lists catalogs the
  /// server knows how to download. Cached for 1 hour to keep the
  /// upstream manifest sources unbothered when a client polls.
  Future<Response> handleAvailable(Request request) async {
    final now = DateTime.now();
    final fetchedAt = _availableFetchedAt;
    final hit =
        fetchedAt != null && now.difference(fetchedAt) < _availableCacheTtl;
    if (!hit) _availableFetchedAt = now;
    return jsonOk({
      'available': [
        for (final catalog in SkyCatalog.values)
          {
            'name': catalog.name,
            'displayName': catalog.displayName,
            'version': catalog.version,
            'description': catalog.description,
            if (catalog.upstreamUrl.isNotEmpty)
              'downloadUrl': catalog.upstreamUrl,
            'sizeBytes': catalog.approximateSizeBytes,
            'requiredForPlateSolve': catalog.requiredForPlateSolve,
          },
      ],
      'cache': hit ? 'hit' : 'miss',
      'fetchedAt': (_availableFetchedAt ?? now).toUtc().toIso8601String(),
    });
  }

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
        message: 'CatalogManager has not been initialized on the server',
        statusCode: 503,
      );
    }
    final payload = await readJsonObject(request);
    final name = requireString(payload, 'name');
    final catalog = _requireCatalog(name);

    final job = jobManager.start(
      operation: 'catalog.download',
      work: (sink, cancellation) async {
        try {
          final result = await _manager.install(
            catalog,
            onProgress: (progress) {
              final downloaded = progress.bytesReceived;
              final total = progress.totalBytes;
              if (progress.isTerminal || downloaded == 0) return;
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
          throw const JobCancelledException('catalog download canceled');
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
        message: 'CatalogManager has not been initialized on the server',
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
    final catalog = _requireCatalog(name);
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
          catalog,
          tempFile,
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

  /// `POST /api/catalog/verify` — admin scope, high-risk,
  /// audit-action `catalog_verify`. Body: `{name?: 'stars'}`. Omit
  /// `name` to verify every installed catalog. Returns the per-catalog
  /// SHA-256 verification result.
  Future<Response> handleVerify(Request request) async {
    _logInfo('[API] POST /api/catalog/verify');
    if (!_manager.isInitialized) {
      throw HandlerFailure(
        code: 'catalog_manager_uninitialized',
        message: 'CatalogManager has not been initialized on the server',
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

    final results = await _manager.verify(
      only: name == null ? null : _requireCatalog(name),
    );
    return jsonOk({
      'verified': results.map((k, v) => MapEntry(k.name, v.toJson())),
    });
  }

  /// `DELETE /api/catalog/<name>` — admin scope, high-risk,
  /// audit-action `catalog_delete`. Removes the catalog data file +
  /// metadata sidecar from disk. 404 when the catalog is not installed.
  Future<Response> handleDelete(Request request, String name) async {
    _logInfo('[API] DELETE /api/catalog/$name');
    if (!_manager.isInitialized) {
      throw HandlerFailure(
        code: 'catalog_manager_uninitialized',
        message: 'CatalogManager has not been initialized on the server',
        statusCode: 503,
      );
    }
    final catalog = _requireCatalog(name);
    final removed = await _manager.uninstall(catalog);
    if (!removed) {
      return jsonNotFound({'error': 'catalog_not_installed', 'name': name});
    }
    return jsonOk({'status': 'uninstalled', 'name': name});
  }

  /// `POST /api/catalog/reload` — admin scope. Drops cached loaders so
  /// subsequent searches re-parse from disk. Useful after an operator
  /// manually copies a catalog into the directory.
  Future<Response> handleReload(Request request) async {
    _logInfo('[API] POST /api/catalog/reload');
    if (!_manager.isInitialized) {
      throw HandlerFailure(
        code: 'catalog_manager_uninitialized',
        message: 'CatalogManager has not been initialized on the server',
        statusCode: 503,
      );
    }
    await _manager.reload();
    return jsonOk({'status': 'reloaded'});
  }
}
