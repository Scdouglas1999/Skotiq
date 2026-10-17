import 'dart:io';

import 'package:skotiq_core/skotiq_core.dart';

/// Resolve and create the directory this host uses for sequencer crash-recovery
/// checkpoints.
///
/// The layout belongs to the host, never to a connected client: a remote client
/// runs on a different filesystem, so a path it supplies is at best meaningless
/// and at worst unwritable, which turns a mid-night crash into an unrecoverable
/// night. Throws a [FileSystemException] when the resolved directory is not
/// absolute, cannot be created, or cannot be written to, so an unusable
/// checkpoint location fails loudly instead of being accepted silently.
///
/// Anchored on [resolveSkotiqDataDirectory], not on the platform
/// application-support folder: that folder is per-application, so two daemons
/// given their own data directories still resolved one shared
/// `skotiq_session.checkpoint` and each would offer the operator the
/// other's interrupted run.
Future<Directory> resolveHostCheckpointDirectory({
  Map<String, String>? environment,
  Future<Directory> Function()? applicationSupportDirectoryProvider,
}) async {
  final dataRoot = await resolveSkotiqDataDirectory(
    environment: environment,
    applicationSupportDirectoryProvider: applicationSupportDirectoryProvider,
  );
  final directory = Directory(
    '${dataRoot.path}${Platform.pathSeparator}checkpoints',
  );
  if (!directory.isAbsolute) {
    throw FileSystemException(
      'the host checkpoint directory must be an absolute path',
      directory.path,
    );
  }
  await directory.create(recursive: true);
  final probe = File(
    '${directory.path}${Platform.pathSeparator}'
    '.skotiq-write-probe-${DateTime.now().microsecondsSinceEpoch}',
  );
  await probe.writeAsString('');
  await probe.delete();
  return directory;
}
