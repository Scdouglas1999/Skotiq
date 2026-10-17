// Where the desktop GUI keeps its sequence-recovery checkpoint.
//
// Anchoring the checkpoint to the platform application-support folder shares it
// with every Skotiq on the machine, so a second instance pointed at its own
// database finds the first one's file: a Skotiq started against an empty
// database is shown "Recover Sequence? A previous sequence was interrupted…
// Sequence: AUDIT SEQ" for a run with no row in the database it has open. The
// modal's only dismissal is Discard, which deletes the checkpoint AND its .bak,
// so getting past it destroys the other instance's recovery state.
//
// The shell must therefore ask the backend to write checkpoints beside the
// OPEN DATABASE. These tests drive the real `AppShell` (not the helper) so
// that cutting the production call site fails them.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Records the checkpoint directory the shell hands to the backend and reports
/// "no checkpoint" so startup stops before the recovery modal.
class _RecordingBackend extends DisconnectedBackend {
  String? checkpointDir;

  @override
  Future<void> sequencerSetCheckpointDir(String path) async {
    checkpointDir = path;
  }

  @override
  Future<bool> hasCheckpoint() async => false;
}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// path_provider has no platform implementation under `flutter test`, so the
/// documents/support folders are answered here. Keeping them apart is the
/// whole point: the assertion is that the checkpoint lands under the first.
void _mockPathProvider({
  required String documents,
  required String support,
}) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'getApplicationDocumentsDirectory':
        return documents;
      case 'getApplicationSupportDirectory':
        return support;
      case 'getTemporaryDirectory':
        return Directory.systemTemp.path;
      default:
        return null;
    }
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}

void main() {
  testWidgets(
    'the shell anchors crash recovery to the open database, not the shared '
    'application-support folder',
    (tester) async {
      // Synchronous on purpose: `testWidgets` runs inside a fake-async zone,
      // and an awaited dart:io future never completes there.
      final root = Directory.systemTemp.createTempSync('ns-checkpoint-');
      addTearDown(() => root.deleteSync(recursive: true));
      final documents = Directory('${root.path}/documents')
        ..createSync(recursive: true);
      final support = Directory('${root.path}/support')
        ..createSync(recursive: true);
      _mockPathProvider(documents: documents.path, support: support.path);

      final backend = _RecordingBackend();
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            backendProvider
                .overrideWith((ref) => _StubBackendNotifier(ref, backend)),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const AppShell(child: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Unmount inside the test body so the drift stream-close timers the
      // ProviderScope schedules on dispose can drain; otherwise the binding
      // fails the test on "a Timer is still pending" before any expectation
      // is reported.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 10));

      // `resolveDefaultDatabaseFile` puts the database at
      // <documents>/Skotiq/skotiq.db; the checkpoint belongs beside it.
      final separator = Platform.pathSeparator;
      final override = Platform.environment[skotiqDatabaseDirEnv]?.trim();
      final databaseRoot = override != null && override.isNotEmpty
          ? override
          : '${documents.path}${separator}Skotiq';
      expect(
        backend.checkpointDir,
        '$databaseRoot${separator}checkpoints',
        reason: 'checkpoints belong beside the database whose run wrote them',
      );
      expect(
        backend.checkpointDir,
        isNot(support.path),
        reason: 'the support folder is shared by every instance on the machine',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  group('legacy checkpoint adoption', () {
    late Directory root;
    late Directory legacy;
    late Directory target;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('ns-checkpoint-adopt-');
      legacy = Directory('${root.path}/support')..createSync(recursive: true);
      target = Directory('${root.path}/db/checkpoints');
    });

    tearDown(() => root.delete(recursive: true));

    File legacyCheckpoint() => File('${legacy.path}/skotiq_session.checkpoint');

    test('a checkpoint written by an older build is carried forward', () async {
      legacyCheckpoint().writeAsStringSync('{"sequence":"last night"}');
      File('${legacy.path}/skotiq_session.checkpoint.bak')
          .writeAsStringSync('{"sequence":"older"}');

      await adoptLegacyGuiCheckpoint(
        targetDir: target,
        legacyDirectoryResolver: () async => legacy,
        environment: const {},
      );

      expect(
        File('${target.path}/skotiq_session.checkpoint').readAsStringSync(),
        '{"sequence":"last night"}',
      );
      expect(
        File('${target.path}/skotiq_session.checkpoint.bak').existsSync(),
        isTrue,
      );
      expect(legacyCheckpoint().existsSync(), isFalse);
    });

    test('a database-directory override leaves the shared file alone',
        () async {
      legacyCheckpoint().writeAsStringSync('{"sequence":"someone else"}');

      await adoptLegacyGuiCheckpoint(
        targetDir: target,
        legacyDirectoryResolver: () async => legacy,
        environment: const {skotiqDatabaseDirEnv: '/tmp/other-db'},
      );

      expect(
        File('${target.path}/skotiq_session.checkpoint').existsSync(),
        isFalse,
        reason: 'with several databases in play the legacy file may belong to '
            'any of them — adopting it recreates the cross-instance defect',
      );
      expect(legacyCheckpoint().existsSync(), isTrue);
    });

    test('this database\'s own checkpoint is never overwritten', () async {
      legacyCheckpoint().writeAsStringSync('{"sequence":"stale"}');
      target.createSync(recursive: true);
      File('${target.path}/skotiq_session.checkpoint')
          .writeAsStringSync('{"sequence":"tonight"}');

      await adoptLegacyGuiCheckpoint(
        targetDir: target,
        legacyDirectoryResolver: () async => legacy,
        environment: const {},
      );

      expect(
        File('${target.path}/skotiq_session.checkpoint').readAsStringSync(),
        '{"sequence":"tonight"}',
      );
    });
  });
}
