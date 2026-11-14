import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/services.dart' show LoggingService;
import 'package:skotiq_core/utils.dart';

/// File names the native `CheckpointManager` writes in the checkpoint
/// directory (`CHECKPOINT_FILENAME` / `CHECKPOINT_BACKUP` in
/// `native/skotiq_native/sequencer/src/checkpoint.rs`).
const List<String> _checkpointFileNames = [
  'skotiq_session.checkpoint',
  'skotiq_session.checkpoint.bak',
];

/// Resolve, create and check the directory this host keeps its sequencer
/// crash-recovery checkpoints in: `checkpoints` beside the open database, so
/// a checkpoint is only ever found by the database whose run wrote it, for a
/// window and a daemon alike. A checkpoint an earlier build kept in the data
/// directory is moved in first (see [_adoptEarlierCheckpoints]).
///
/// The layout belongs to the host, never to a connected client: a path a
/// client supplies names a different filesystem. Throws a
/// [FileSystemException] when the directory is not absolute, cannot be made
/// or cannot be written, so an unusable checkpoint location fails loudly
/// instead of turning a mid-night crash into an unrecoverable night.
Future<Directory> resolveHostCheckpointDirectory({
  LoggingService? logger,
  Map<String, String>? environment,
  Future<Directory> Function()? applicationSupportDirectoryProvider,
  Future<Directory> Function()? documentsDirectoryProvider,
}) async {
  final env = environment ?? skotiqProcessEnvironment;
  final database = await resolveDefaultDatabaseFile(
    environment: env,
    documentsDirectoryProvider: documentsDirectoryProvider,
  );
  final directory = Directory(p.join(database.parent.path, 'checkpoints'));
  if (!directory.isAbsolute) {
    throw FileSystemException(
      'the host checkpoint directory must be an absolute path',
      directory.path,
    );
  }
  await directory.create(recursive: true);
  final probe = File(
    p.join(
      directory.path,
      '.skotiq-write-probe-${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  await probe.writeAsString('');
  await probe.delete();

  await _adoptEarlierCheckpoints(
    target: directory,
    logger: logger,
    environment: env,
    applicationSupportDirectoryProvider: applicationSupportDirectoryProvider,
  );
  return directory;
}

/// Moves a checkpoint left where an earlier build kept it into [target], so
/// an upgrade between a crash and the next start does not drop a resumable
/// night: the window kept it in the data directory itself, the daemon in its
/// `checkpoints` folder.
///
/// Only when that data directory is this instance's own: either no database
/// directory is configured (one database per data directory), or the data
/// directory is configured for this instance. A shared application-support
/// folder used by instances that each name their own database may hold any
/// of their checkpoints, and is left alone. A checkpoint already in [target]
/// is this database's own: nothing is moved over it. A file that cannot be moved
/// is logged and left where it is: the directory is still usable tonight.
Future<void> _adoptEarlierCheckpoints({
  required Directory target,
  required LoggingService? logger,
  required Map<String, String> environment,
  Future<Directory> Function()? applicationSupportDirectoryProvider,
}) async {
  bool configured(String name) => (environment[name]?.trim() ?? '').isNotEmpty;
  if (configured(skotiqDatabaseDirEnv) && !configured(skotiqDataDirEnv)) {
    return;
  }
  for (final name in _checkpointFileNames) {
    if (await File(p.join(target.path, name)).exists()) return;
  }
  final dataRoot = await resolveSkotiqDataDirectory(
    environment: environment,
    applicationSupportDirectoryProvider: applicationSupportDirectoryProvider,
  );
  for (final earlier in [dataRoot.path, p.join(dataRoot.path, 'checkpoints')]) {
    if (p.equals(earlier, target.path)) continue;
    for (final name in _checkpointFileNames) {
      final file = File(p.join(earlier, name));
      final destination = File(p.join(target.path, name));
      if (!await file.exists() || await destination.exists()) continue;
      try {
        await _move(file, destination);
      } on FileSystemException catch (error) {
        logger?.warning(
          'Could not move the checkpoint ${file.path} into ${target.path}: '
          '${error.message}',
          source: 'HostCheckpointDirectory',
        );
      }
    }
  }
}

/// A rename, or a copy and delete where the two folders are on different
/// file systems.
Future<void> _move(File file, File destination) async {
  try {
    await file.rename(destination.path);
  } on FileSystemException {
    await file.copy(destination.path);
    await file.delete();
  }
}
