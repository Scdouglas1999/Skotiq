// Crash-recovery checkpoints must be scoped to the INSTANCE.
//
// The platform application-support folder is per-application, so two headless
// daemons each given their own SKOTIQ_DATA_DIR still resolved one shared
// `skotiq_session.checkpoint`: on restart either would offer the operator
// the other rig's interrupted run, and whichever choice they made rewrote or
// deleted the other's recovery state.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless/host_checkpoint_directory.dart';

void main() {
  late Directory sharedSupportDir;
  late Directory ownDataRoot;

  setUp(() {
    sharedSupportDir = Directory.systemTemp.createTempSync('sk-shared-support');
    ownDataRoot = Directory.systemTemp.createTempSync('sk-own-data');
  });

  tearDown(() {
    for (final dir in [sharedSupportDir, ownDataRoot]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  String checkpointsUnder(Directory root) =>
      '${root.path}${Platform.pathSeparator}checkpoints';

  test('an instance data directory owns its own checkpoint folder', () async {
    final resolved = await resolveHostCheckpointDirectory(
      environment: {skotiqDataDirEnv: ownDataRoot.path},
      applicationSupportDirectoryProvider: () async => sharedSupportDir,
    );

    expect(resolved.path, checkpointsUnder(ownDataRoot));
    expect(resolved.existsSync(), isTrue);
    expect(Directory(checkpointsUnder(sharedSupportDir)).existsSync(), isFalse);
  });

  test('without an override it falls back to application support', () async {
    final resolved = await resolveHostCheckpointDirectory(
      environment: const <String, String>{},
      applicationSupportDirectoryProvider: () async => sharedSupportDir,
    );

    expect(resolved.path, checkpointsUnder(sharedSupportDir));
    expect(resolved.existsSync(), isTrue);
  });

  test('a relative override still fails loudly', () async {
    // An application-support directory is always absolute, but an operator's
    // environment variable need not be — and a checkpoint path resolved
    // against whatever the daemon's working directory happens to be is a
    // recovery file nobody can find again.
    await expectLater(
      resolveHostCheckpointDirectory(
        environment: const {skotiqDataDirEnv: 'relative/state'},
        applicationSupportDirectoryProvider: () async => sharedSupportDir,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
