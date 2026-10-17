import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for backup and restore operations
class BackupHandlers {
  static const int _maxBackupUploadBytes = 256 * 1024 * 1024;

  /// Filename pattern: skotiq-backup-{timestamp}-{uuid}.skbackup.
  ///
  /// Backup ids must survive a process restart, so the UUID lives in the
  /// filename and is the public REST identifier for delete / download /
  /// metadata. Legacy `skotiq_backup_*` / `skotiq_autosave_*` names
  /// carry no UUID and fall back to a deterministic fingerprint — see
  /// [_idForBackupFile].
  static final RegExp _uuidInFilenamePattern = RegExp(
    r'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
  );

  static const _uuid = Uuid();

  final ProviderContainer container;
  BackupHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'BackupHandlers');
  void _logWarning(String message) =>
      _logger.warning(message, source: 'BackupHandlers');
  void _logError(String message) =>
      _logger.error(message, source: 'BackupHandlers');

  // List backups

  Future<Response> handleListBackups(Request request) async {
    _logInfo('[API] GET /api/backup/list');
    final service = container.read(backupServiceProvider);
    final backupFiles = await _listContainedBackups(service);

    final backups = <Map<String, dynamic>>[];
    for (final file in backupFiles) {
      final metadata = await service.readBackupMetadata(file.path);
      final stat = await file.stat();

      backups.add({
        'id': _idForBackupFile(file),
        'filePath': file.path,
        'fileName': file.uri.pathSegments.last,
        'createdAt':
            metadata?.createdAt.millisecondsSinceEpoch ??
            stat.modified.millisecondsSinceEpoch,
        'fileSize': stat.size,
        'metadata': metadata != null
            ? {
                'version': metadata.version,
                'appVersion': metadata.appVersion,
                'platform': metadata.platform,
                'settingsCount': metadata.settingsCount,
                'profilesCount': metadata.profilesCount,
                'sequencesCount': metadata.sequencesCount,
                'targetsCount': metadata.targetsCount,
              }
            : null,
      });
    }

    return jsonOk({'backups': backups});
  }

  // Create backup

  Future<Response> handleCreateBackup(Request request) async {
    _logInfo('[API] POST /api/backup/create');
    final payload = await readJsonObject(request);
    final customPath = optionalString(payload, 'customPath');
    final autoSave = optionalBool(payload, 'autoSave') ?? false;

    // A remote client chooses *whether* to create a backup, never where the
    // host writes it. Allowing an arbitrary server path here turns an admin API
    // into an arbitrary JSON-file write primitive. Downloads provide the
    // client-side destination choice after the host creates the archive in its
    // managed backup directory.
    if (customPath != null) {
      return jsonBadRequest({
        'error': 'customPath is not supported for remote backup creation',
        'code': 'host_managed_backup_path',
      });
    }

    final service = container.read(backupServiceProvider);

    final BackupResult result;
    if (autoSave) {
      // Route auto-save through createBackup with a UUID-bearing path (rather
      // than service.autoSaveBackup) so the new backup carries a stable
      // identifier recoverable from its filename. autoSaveBackup produces a
      // `skotiq_autosave_<ts>.skbackup` name that the _idForBackupFile
      // fallback can only address as "legacy-...", so the id in the create
      // response would not survive a later list/delete round-trip.
      final autoSavePath = await _defaultUuidBackupPath(service, tag: 'auto');
      result = await service.createBackup(customPath: autoSavePath);
    } else {
      final effectivePath = await _defaultUuidBackupPath(service);
      result = await service.createBackup(customPath: effectivePath);
    }

    if (result.success) {
      return jsonOk({
        'status': 'created',
        'id': result.filePath != null
            ? _idForBackupFile(File(result.filePath!))
            : null,
        'filePath': result.filePath,
        'itemsBackedUp': result.itemsBackedUp,
        'timestamp': result.timestamp.millisecondsSinceEpoch,
      });
    }
    // A failed create is a server-side problem (disk, db, ...). The caller
    // cannot fix it by changing their request, so 500, not 200. HandlerFailure
    // gives the wire body a stable machine code instead of free-form text.
    _logError('[API] Create backup failed: ${result.errorMessage}');
    throw HandlerFailure(
      code: 'backup_create_failed',
      message: result.errorMessage ?? 'Backup creation failed',
    );
  }

  // Restore backup

  Future<Response> handleRestoreBackup(Request request) async {
    _logInfo('[API] POST /api/backup/restore');
    final blocked = _restoreBlockedResponse();
    if (blocked != null) return blocked;
    final payload = await readJsonObject(request);
    final id = optionalString(payload, 'id');
    final filePath = optionalString(payload, 'filePath');
    final replaceExisting = optionalBool(payload, 'replaceExisting') ?? false;

    final service = container.read(backupServiceProvider);

    // Resolve the restore source to a real file that lives INSIDE this host's
    // backup directory. A remote client must never be able to make
    // the host read an arbitrary absolute path off disk as a "backup".
    //   * Preferred: a stable backup `id`, resolved against listBackups() —
    //     exactly the same resolution delete/download/metadata already use.
    //   * Legacy: an absolute `filePath` from an older client, accepted ONLY
    //     when it canonicalises to a file directly inside the backup directory
    //     (a `..` segment or an out-of-tree symlink fails closed).
    final String resolvedPath;
    if (id != null && id.isNotEmpty) {
      final backupFiles = await _listContainedBackups(service);
      final file = backupFiles
          .where((f) => _idForBackupFile(f) == id)
          .firstOrNull;
      if (file == null) {
        return jsonNotFound({'error': 'Backup not found: $id'});
      }
      resolvedPath = file.path;
    } else if (filePath != null && filePath.isNotEmpty) {
      final contained = await _resolveContainedBackupFile(service, filePath);
      if (contained == null) {
        return jsonBadRequest({
          'error':
              'filePath must reference an existing backup inside the backup '
              'directory',
        });
      }
      resolvedPath = contained.path;
    } else {
      throw BadRequestError(
        field: 'id',
        expected: 'a backup id (or a contained filePath)',
      );
    }

    final result = await service.restoreBackup(
      filePath: resolvedPath,
      replaceExisting: replaceExisting,
    );

    if (result.success) {
      return jsonOk(await _restoredBody(result));
    }
    // Restore-from-disk failures aren't necessarily caused by a bad request
    // body (the file path was valid syntactically). The most common cause is a
    // corrupted/missing backup or a db write failure, both 500-class.
    // HandlerFailure keeps the wire body a structured code, which the
    // fail-closed rule requires.
    _logError('[API] Restore backup failed: ${result.errorMessage}');
    throw HandlerFailure(
      code: 'backup_restore_failed',
      message: result.errorMessage ?? 'Backup restore failed',
    );
  }

  // Delete backup

  Future<Response> handleDeleteBackup(Request request, String id) async {
    _logInfo('[API] DELETE /api/backup/$id');
    final service = container.read(backupServiceProvider);
    final backupFiles = await _listContainedBackups(service);

    final file = backupFiles
        .where((f) => _idForBackupFile(f) == id)
        .firstOrNull;

    if (file == null) {
      return jsonNotFound({'error': 'Backup not found: $id'});
    }

    await file.delete();

    return jsonOk({'status': 'deleted'});
  }

  // Download backup

  Future<Response> handleDownloadBackup(Request request, String id) async {
    _logInfo('[API] GET /api/backup/$id/download');
    final service = container.read(backupServiceProvider);
    final backupFiles = await _listContainedBackups(service);

    final file = backupFiles
        .where((f) => _idForBackupFile(f) == id)
        .firstOrNull;

    if (file == null) {
      return jsonNotFound({'error': 'Backup not found: $id'});
    }

    // Stream the file
    final fileLength = await file.length();
    return attachmentResponse(
      file.openRead(),
      fileName: file.uri.pathSegments.last,
      contentType: jsonContentType,
      contentLength: fileLength,
    );
  }

  // Get backup metadata

  Future<Response> handleGetBackupMetadata(Request request, String id) async {
    _logInfo('[API] GET /api/backup/$id/metadata');
    final service = container.read(backupServiceProvider);
    final backupFiles = await _listContainedBackups(service);

    final file = backupFiles
        .where((f) => _idForBackupFile(f) == id)
        .firstOrNull;

    if (file == null) {
      return jsonNotFound({'error': 'Backup not found: $id'});
    }

    final metadata = await service.readBackupMetadata(file.path);
    if (metadata == null) {
      return jsonOk({'metadata': null});
    }

    return jsonOk({'metadata': metadata.toJson()});
  }

  // Auto save backup

  Future<Response> handleAutoSaveBackup(Request request) async {
    _logInfo('[API] POST /api/backup/auto-save');
    final service = container.read(backupServiceProvider);
    // See handleCreateBackup — go through createBackup with a UUID-bearing
    // path so the returned id is stable.
    final autoSavePath = await _defaultUuidBackupPath(service, tag: 'auto');
    final result = await service.createBackup(customPath: autoSavePath);

    if (result.success) {
      return jsonOk({
        'status': 'created',
        'id': result.filePath != null
            ? _idForBackupFile(File(result.filePath!))
            : null,
        'filePath': result.filePath,
        'itemsBackedUp': result.itemsBackedUp,
        'timestamp': result.timestamp.millisecondsSinceEpoch,
      });
    }
    // Same rationale as handleCreateBackup — an auto-save failure is a
    // local/server problem, not a request validation problem, and
    // HandlerFailure keeps the wire body a structured code.
    _logError('[API] Auto save backup failed: ${result.errorMessage}');
    throw HandlerFailure(
      code: 'backup_autosave_failed',
      message: result.errorMessage ?? 'Auto-save backup failed',
    );
  }

  Future<Response> handleUploadRestoreBackup(Request request) async {
    _logInfo('[API] POST /api/backup/upload-restore');
    final blocked = _restoreBlockedResponse();
    if (blocked != null) return blocked;
    // Track the destination at method scope so the catch — the streamed-body
    // owner — can delete a partially written file if anything after the write
    // throws unexpectedly.
    File? destination;
    try {
      final contentLength = int.tryParse(
        request.headers['content-length'] ?? '',
      );
      if (contentLength != null && contentLength > _maxBackupUploadBytes) {
        return jsonTooLarge({
          'error': 'Backup upload is too large',
          'maxBytes': _maxBackupUploadBytes,
        });
      }

      final requestedFileName =
          request.url.queryParameters['fileName'] ?? 'uploaded.skbackup';
      final fileName = _sanitizeUploadedBackupFileName(requestedFileName);
      if (fileName == null) {
        return jsonBadRequest({
          'error':
              'Invalid backup filename. Use a .skbackup or .json filename.',
        });
      }
      final replaceExisting =
          request.url.queryParameters['replaceExisting'] == 'true';

      final service = container.read(backupServiceProvider);
      final backupDir = await service.getBackupDirectory();
      await backupDir.create(recursive: true);
      final file = await _resolveUploadDestination(backupDir, fileName);
      if (file == null) {
        return jsonBadRequest({'error': 'Invalid upload destination'});
      }
      destination = file;

      final uploaded = await _writeUploadBody(request, file);
      if (!uploaded) {
        // Cleanup must not silently swallow errors — a partial
        // upload left on disk after a size-cap breach becomes an orphan
        // file the user has no visibility into. Log at warning and add
        // an `orphanedFile` field to the response body so the caller
        // can decide whether to retry or alert the operator.
        final cleanupError = await _deleteIfExists(file);
        if (cleanupError != null) {
          _logWarning(
            'Failed to clean up oversized upload at ${file.path}: '
            '$cleanupError',
          );
          return jsonTooLarge({
            'error': 'Backup upload is too large',
            'maxBytes': _maxBackupUploadBytes,
            'orphanedFile': file.path,
            'orphanedFileError': cleanupError,
          });
        }
        return jsonTooLarge({
          'error': 'Backup upload is too large',
          'maxBytes': _maxBackupUploadBytes,
        });
      }

      final result = await service.restoreBackup(
        filePath: file.path,
        replaceExisting: replaceExisting,
      );

      if (result.success) {
        return jsonOk(await _restoredBody(result));
      }

      // A failed restore from an uploaded file means the file just written
      // can't be parsed or applied — a server-side failure from the caller's
      // perspective once the upload itself succeeded.
      //
      // The uploaded file is now an orphan: the client still holds its own
      // copy (it just uploaded it), and a file that cannot be restored has no
      // value sitting in the backup directory — worse, it would surface as a
      // phantom "backup" in the next list. Delete it before failing so it
      // takes explicit ownership of the file it created.
      final cleanupError = await _deleteIfExists(file);
      if (cleanupError != null) {
        _logWarning(
          'Failed to clean up uploaded backup after restore failure at '
          '${file.path}: $cleanupError',
        );
      }
      // HandlerFailure gives the wire body a stable machine code.
      _logError('[API] Upload restore failed: ${result.errorMessage}');
      throw HandlerFailure(
        code: 'backup_upload_restore_failed',
        message: result.errorMessage ?? 'Upload restore failed',
      );
    } on HandlerFailure {
      // Re-throw so errorTranslationMiddleware renders the structured body.
      // The orphaned upload was already cleaned up at the throw site above.
      rethrow;
    } catch (e) {
      // Keep the explicit try/catch here because this handler streams the
      // request body and owns a partial-file on disk on error. The
      // errorTranslationMiddleware would still log and 500, but we must not
      // leave a half-written file behind.
      if (destination != null) {
        final cleanupError = await _deleteIfExists(destination);
        if (cleanupError != null) {
          _logWarning(
            'Failed to clean up partial upload at ${destination.path}: '
            '$cleanupError',
          );
        }
      }
      _logError('[API] Upload restore backup error: $e');
      return jsonInternalServerError({'error': 'internal_error'});
    }
  }

  /// Build the success body for a completed restore, re-hydrating the cached
  /// state first.
  ///
  /// The restore writes straight to the database while this process still
  /// holds its pre-restore `AppSettings` snapshot in memory. `POST
  /// /api/settings` merges the posted keys onto that snapshot and persists the
  /// whole map, so the snapshot MUST be re-hydrated here or the next settings
  /// write erases every restored value. The body reports whether it worked.
  Future<Map<String, Object?>> _restoredBody(RestoreResult result) async {
    final reloaded = await _reloadRestoredState();
    return {
      'status': 'restored',
      'itemsRestored': result.itemsRestored,
      'categoryCounts': result.categoryCounts,
      'timestamp': result.timestamp.millisecondsSinceEpoch,
      'reloaded': reloaded,
      'message': reloaded
          ? 'Restored ${result.itemsRestored} items. This host is now running '
                'on the restored data.'
          : 'Restored ${result.itemsRestored} items, but this host could not '
                'reload its cached state. Restart Skotiq before the next '
                'run or the restore may be overwritten.',
    };
  }

  Future<bool> _reloadRestoredState() async {
    container.invalidate(appSettingsProvider);
    container.invalidate(equipmentProfilesProvider);
    container.invalidate(savedSequencesProvider);
    try {
      await container.read(appSettingsProvider.future);
      return true;
    } on Object catch (error) {
      _logError(
        'Restore succeeded but the settings cache could not be reloaded: '
        '$error. Restart before the next run — a settings write would '
        'otherwise persist the pre-restore snapshot.',
      );
      return false;
    }
  }

  String? _sanitizeUploadedBackupFileName(String requestedFileName) {
    var fileName = requestedFileName.split(RegExp(r'[\\/]')).last.trim();
    fileName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (fileName.isEmpty || fileName == '.' || fileName == '..') {
      return null;
    }
    if (!fileName.contains('.')) {
      fileName = '$fileName.skbackup';
    }
    final lower = fileName.toLowerCase();
    if (!lower.endsWith('.skbackup') &&
        !lower.endsWith('.nsbackup') &&
        !lower.endsWith('.json')) {
      return null;
    }
    if (fileName.length > 120) {
      final ext = lower.endsWith('.json')
          ? '.json'
          : lower.endsWith('.nsbackup')
          ? '.nsbackup'
          : '.skbackup';
      final stem = fileName.substring(0, fileName.length - ext.length);
      final maxStemLength = 120 - ext.length;
      final safeStem = stem.length <= maxStemLength
          ? stem
          : stem.substring(0, maxStemLength);
      fileName = '$safeStem$ext';
    }
    return fileName;
  }

  Future<File?> _resolveUploadDestination(
    Directory backupDir,
    String fileName,
  ) async {
    final resolvedBackupDir = await backupDir.resolveSymbolicLinks();
    final destination = File(p.join(resolvedBackupDir, fileName));
    final destinationParent = await destination.parent.resolveSymbolicLinks();
    final compareBackupDir = Platform.isWindows
        ? resolvedBackupDir.toLowerCase()
        : resolvedBackupDir;
    final compareParent = Platform.isWindows
        ? destinationParent.toLowerCase()
        : destinationParent;
    if (compareParent != compareBackupDir) {
      return null;
    }

    if (!await destination.exists()) {
      return destination;
    }

    final ext = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return File(p.join(resolvedBackupDir, '${stem}_upload_$timestamp$ext'));
  }

  /// Resolve [candidatePath] to a real file guaranteed to live directly inside
  /// this host's backup directory, or null when it escapes (path traversal),
  /// does not exist, or the backup directory is missing.
  ///
  /// Mirrors the symlink canonicalisation used by [_resolveUploadDestination]
  /// so a `..` segment or a symlink pointing out of the backup directory fails
  /// closed. Backs the legacy `filePath` restore path in [handleRestoreBackup]:
  /// older clients still send an absolute server path, and this containment
  /// check is what keeps that path from being an arbitrary-file-read primitive.
  Future<File?> _resolveContainedBackupFile(
    BackupService service,
    String candidatePath,
  ) async {
    final file = File(candidatePath);
    if (!await file.exists()) return null;

    final backupDir = await service.getBackupDirectory();
    if (!await backupDir.exists()) return null;

    final resolvedBackupDir = await backupDir.resolveSymbolicLinks();
    final resolvedFile = await file.resolveSymbolicLinks();
    final resolvedParent = p.dirname(resolvedFile);
    final compareBackupDir = Platform.isWindows
        ? resolvedBackupDir.toLowerCase()
        : resolvedBackupDir;
    final compareParent = Platform.isWindows
        ? resolvedParent.toLowerCase()
        : resolvedParent;
    if (compareParent != compareBackupDir) return null;
    return File(resolvedFile);
  }

  /// Return only real backup files whose canonical target is directly inside
  /// the backup directory. This applies the same containment rule to list,
  /// restore-by-id, delete, metadata, and download; an in-directory symlink to
  /// an outside file must not become a downloadable "backup".
  Future<List<File>> _listContainedBackups(BackupService service) async {
    final backupDir = await service.getBackupDirectory();
    if (!await backupDir.exists()) return const [];
    final resolvedBackupDir = await backupDir.resolveSymbolicLinks();
    final compareBackupDir = Platform.isWindows
        ? resolvedBackupDir.toLowerCase()
        : resolvedBackupDir;
    final contained = <File>[];
    for (final candidate in await service.listBackups()) {
      try {
        final resolvedFile = await candidate.resolveSymbolicLinks();
        final parent = p.dirname(resolvedFile);
        final compareParent = Platform.isWindows
            ? parent.toLowerCase()
            : parent;
        if (compareParent == compareBackupDir) {
          contained.add(File(resolvedFile));
        }
      } on FileSystemException catch (error) {
        _logWarning(
          'Skipping unreadable backup entry ${candidate.path}: '
          '${error.message}',
        );
      }
    }
    return contained;
  }

  Response? _restoreBlockedResponse() {
    final execution = container.read(sequenceExecutionStateProvider);
    final capturing = container.read(sessionStateProvider).isCapturing;
    if (!execution.isBusy && !capturing) return null;
    return jsonConflict({
      'error': 'Stop the active capture or sequence before restoring a backup.',
      'code': 'imaging_active',
    });
  }

  Future<bool> _writeUploadBody(Request request, File destination) async {
    final sink = destination.openWrite();
    var bytesWritten = 0;
    try {
      await for (final chunk in request.read()) {
        bytesWritten += chunk.length;
        if (bytesWritten > _maxBackupUploadBytes) {
          return false;
        }
        sink.add(chunk);
      }
      return true;
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  /// Delete the file at [file] if it exists.
  ///
  /// Returns null on success (including the no-op "did not exist" path),
  /// or a sanitized error message if deletion failed.: callers must
  /// surface a non-null result instead of swallowing it — a leftover
  /// upload file after a failed restore is an orphan that will
  /// accumulate across attempts and confuse the user.
  ///
  /// Returns the FileSystemException.message (or a generic `delete_failed`)
  /// rather than the raw exception string, which would leak the Dart runtime
  /// type name onto the wire via `orphanedFileError`.
  Future<String?> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
      return null;
    } on FileSystemException catch (e, stackTrace) {
      _logger.error(
        'Failed to delete orphaned upload ${file.path}: ${e.message}',
        source: 'BackupHandlers',
        fields: {
          'path': file.path,
          'osError': e.osError?.toString(),
          'stack': stackTrace.toString(),
        },
      );
      return e.message;
    } catch (e, stackTrace) {
      // Never return the raw exception string over the wire — it leaks the
      // Dart runtime type name. Log the full detail (via string interpolation,
      // not direct stringification, so the fail-closed regex stays green) and
      // surface a stable code to the caller.
      _logger.error(
        'Failed to delete orphaned upload ${file.path}: $e',
        source: 'BackupHandlers',
        fields: {'path': file.path, 'stack': stackTrace.toString()},
      );
      return 'delete_failed';
    }
  }

  /// Build a stable identifier for the backup [file].
  ///
  /// The id must be stable across process restarts and collision-free, or the
  /// delete endpoint targets the wrong file. Dart's per-isolate `hashCode`
  /// satisfies neither.
  ///
  /// 1. If the filename contains a UUID (the pattern every new backup gets),
  ///    extract and return it.
  /// 2. Otherwise derive the id from the filename, which is
  ///    process-independent and unique within the backup directory because
  ///    `_resolveUploadDestination` and `autoSaveBackup` both timestamp-suffix
  ///    on collision. Prefixed `legacy-` so callers can tell it apart from a
  ///    UUID-tagged one.
  String _idForBackupFile(File file) {
    final name = file.uri.pathSegments.last;
    final match = _uuidInFilenamePattern.firstMatch(name);
    if (match != null) {
      return match.group(1)!.toLowerCase();
    }
    // No UUID embedded. Use the filename, sanitized to be URL-safe, as the
    // stable id.
    final sanitized = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return 'legacy-$sanitized';
  }

  /// Compose a default backup path that embeds a UUID in the filename.
  ///
  /// Headless has no file chooser, so a route that passes no `customPath` gets
  /// its path from here rather than from `BackupService.createBackup`. The
  /// UUID lets [_idForBackupFile] recover a stable id later; [tag] (default
  /// `manual`) distinguishes manual from auto-save backups in the filename
  /// without breaking UUID extraction.
  Future<String> _defaultUuidBackupPath(
    BackupService service, {
    String tag = 'manual',
  }) async {
    final dir = await service.getBackupDirectory();
    await dir.create(recursive: true);
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final id = _uuid.v4();
    return p.join(dir.path, 'skotiq-backup-$tag-$timestamp-$id.skbackup');
  }
}
