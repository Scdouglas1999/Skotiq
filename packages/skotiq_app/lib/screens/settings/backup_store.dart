import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

import 'backup_list_entry.dart';

/// A database replace that waits for a restart, and the record of the last.
class BackupReplaceState {
  const BackupReplaceState({
    this.pendingBackup,
    this.pendingSafetyBackup,
    this.outcome,
    this.outcomeRestored = false,
  });

  /// The backup that takes the database's place at the next start.
  final String? pendingBackup;
  final String? pendingSafetyBackup;

  /// What the last start did with a replace, in words.
  final String? outcome;
  final bool outcomeRestored;
}

/// How a restore ended: [merged] holds the report when it changed the
/// database now, null when it waits for a restart (a replace).
typedef BackupRestoreOutcome = ({String? merged});

/// The backups of the imaging host: this machine's backup folder and
/// database, or the linked host's.
abstract interface class BackupStore {
  /// Whether the backups are the linked host's.
  bool get onHost;

  Future<List<BackupListEntry>> list();

  /// Writes a backup and returns its file. Throws when it failed.
  Future<String?> create({required void Function(RestoreProgress) onProgress});

  /// Restores [backup]. Throws when the restore failed.
  Future<BackupRestoreOutcome> restore(
    BackupListEntry backup, {
    required RestoreMode mode,
    required void Function(RestoreProgress) onProgress,
  });

  /// Restores the backup file [file] picked on this machine; [readBytes]
  /// reads it for a host. Throws when the restore failed.
  Future<BackupRestoreOutcome> restoreFile(
    String file, {
    required Future<List<int>> Function() readBytes,
    required RestoreMode mode,
    required void Function(RestoreProgress) onProgress,
  });

  Future<BackupReplaceState> replaceState();
  Future<void> cancelReplace();
  Future<void> acknowledgeReplace();
  Future<void> delete(BackupListEntry backup);

  /// The backup's bytes, for a host's backup saved on this machine; null
  /// where the backups are on this machine already.
  Future<Uint8List>? download(BackupListEntry backup);
}

final backupStoreProvider = hostRoleProvider<BackupStore>(
  here: (ref) => _LocalBackupStore(ref.watch(backupServiceProvider)),
  linked: (ref, host) => _HostBackupStore(host.backups),
);

class _LocalBackupStore implements BackupStore {
  _LocalBackupStore(this._service);

  final BackupService _service;

  @override
  bool get onHost => false;

  @override
  Future<List<BackupListEntry>> list() async => Future.wait(
        (await _service.listBackups()).map(BackupListEntry.fromLocalFile),
      );

  @override
  Future<String?> create({
    required void Function(RestoreProgress) onProgress,
  }) async {
    final result = await _service.createBackup(
      onProgress: (fraction) =>
          onProgress(RestoreProgress('Writing the backup', fraction)),
    );
    if (!result.success) {
      throw Exception(result.errorMessage ?? 'Backup failed');
    }
    return result.filePath;
  }

  @override
  Future<BackupRestoreOutcome> restore(
    BackupListEntry backup, {
    required RestoreMode mode,
    required void Function(RestoreProgress) onProgress,
  }) =>
      _restore(backup.filePath, mode, onProgress);

  @override
  Future<BackupRestoreOutcome> restoreFile(
    String file, {
    required Future<List<int>> Function() readBytes,
    required RestoreMode mode,
    required void Function(RestoreProgress) onProgress,
  }) =>
      _restore(file, mode, onProgress);

  Future<BackupRestoreOutcome> _restore(
    String filePath,
    RestoreMode mode,
    void Function(RestoreProgress) onProgress,
  ) async {
    final result = await _service.restoreBackup(
      filePath: filePath,
      mode: mode,
      onProgress: onProgress,
    );
    if (!result.success) {
      throw Exception(result.errorMessage ?? 'Restore failed');
    }
    return (merged: result.pendingRestart ? null : result.report);
  }

  @override
  Future<BackupReplaceState> replaceState() async {
    final pending = await _service.pendingReplace();
    final last = await _service.replaceOutcome();
    return BackupReplaceState(
      pendingBackup: pending?.backupName,
      pendingSafetyBackup: pending?.safetyBackupName,
      outcome: last?.report,
      outcomeRestored: last != null && last.restored,
    );
  }

  @override
  Future<void> cancelReplace() => _service.cancelPendingReplace();

  @override
  Future<void> acknowledgeReplace() => _service.dismissReplaceOutcome();

  @override
  Future<void> delete(BackupListEntry backup) => File(backup.filePath).delete();

  @override
  Future<Uint8List>? download(BackupListEntry backup) => null;
}

class _HostBackupStore implements BackupStore {
  _HostBackupStore(this._host);

  final HostBackups _host;

  @override
  bool get onHost => true;

  @override
  Future<List<BackupListEntry>> list() async =>
      parseRemoteBackupList(await _host.listBackups());

  @override
  Future<String?> create({
    required void Function(RestoreProgress) onProgress,
  }) async {
    final poll = _followProgress(onProgress);
    try {
      final result = await _host.createBackup();
      if ((result['status'] as String?) != 'created') {
        throw Exception(result['error'] ?? 'Backup failed');
      }
      return result['filePath'] as String?;
    } finally {
      poll.cancel();
    }
  }

  /// By its id: the host resolves it to a file in its own backup folder, so
  /// no server path crosses the wire.
  @override
  Future<BackupRestoreOutcome> restore(
    BackupListEntry backup, {
    required RestoreMode mode,
    required void Function(RestoreProgress) onProgress,
  }) =>
      _restore(
        () => _host.restoreBackupById(backup.id, mode: mode),
        onProgress,
      );

  @override
  Future<BackupRestoreOutcome> restoreFile(
    String file, {
    required Future<List<int>> Function() readBytes,
    required RestoreMode mode,
    required void Function(RestoreProgress) onProgress,
  }) =>
      _restore(() async {
        final bytes = await readBytes();
        return _host.uploadBackupAndRestore(
          Uint8List.fromList(bytes),
          path.basename(file),
          mode: mode,
        );
      }, onProgress);

  Future<BackupRestoreOutcome> _restore(
    Future<Map<String, dynamic>> Function() run,
    void Function(RestoreProgress) onProgress,
  ) async {
    final poll = _followProgress(onProgress);
    try {
      final result = await run();
      final status = result['status'] as String?;
      if (status != 'restored' && status != 'staged') {
        throw Exception(result['error'] ?? 'Restore failed');
      }
      return (
        merged: status == 'restored'
            ? result['message'] as String? ?? restoreReportFromWire(result)
            : null,
      );
    } finally {
      poll.cancel();
    }
  }

  /// Shows how far the host is with the backup or restore it is running,
  /// until the returned timer is canceled.
  Timer _followProgress(void Function(RestoreProgress) onProgress) =>
      Timer.periodic(const Duration(seconds: 1), (_) async {
        try {
          final state = await _host.restoreState();
          final progress = state['progress'];
          if (progress is Map) onProgress(RestoreProgress.fromJson(progress));
        } on Exception catch (error) {
          // The operation's own answer says how it went.
          Log.debug(
            'Could not read the host\'s backup progress: $error',
            source: 'BackupScreen',
          );
        }
      });

  @override
  Future<BackupReplaceState> replaceState() async {
    final body = await _host.restoreState();
    final pending = body['pendingReplace'];
    final last = body['lastReplace'];
    return BackupReplaceState(
      pendingBackup: pending is Map ? pending['backupName'] as String? : null,
      pendingSafetyBackup:
          pending is Map ? pending['safetyBackup'] as String? : null,
      outcome: last is Map ? last['report'] as String? : null,
      outcomeRestored: last is Map && last['restored'] == true,
    );
  }

  @override
  Future<void> cancelReplace() => _host.cancelReplace();

  @override
  Future<void> acknowledgeReplace() => _host.acknowledgeReplace();

  @override
  Future<void> delete(BackupListEntry backup) => _host.deleteBackup(backup.id);

  @override
  Future<Uint8List>? download(BackupListEntry backup) =>
      _host.downloadBackup(backup.id);
}
