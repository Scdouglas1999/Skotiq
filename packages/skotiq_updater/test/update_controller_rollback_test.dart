import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_updater/src/services/update_controller.dart';
import 'package:skotiq_updater/src/services/update_service.dart';

/// Verifies the controller -> service wiring for the manual-rollback win:
/// `rollbackSupported()` must reflect whether the Rust updater left a
/// restore point (backup/rollback_log.json) on disk, and `rollback()` must
/// refuse loudly when none exists. Neither path spawns the external updater
/// (that only happens once a restore point is present and the process is
/// handed off), so these stay hermetic.
void main() {
  group('UpdateController manual rollback wiring', () {
    late Directory tempRoot;
    late UpdateController controller;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('skotiq_ctrl_rollback_');
      final service = UpdateService(
        currentVersion: '2.1.0',
        currentBuildNumber: 42,
        applicationSupportDirectoryProvider: () async => tempRoot,
      );
      controller = UpdateController(
        service: service,
        currentVersion: '2.1.0',
        currentBuildNumber: 42,
        stateDirectory: () async => tempRoot,
      );
    });

    tearDown(() async {
      await controller.dispose();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    File rollbackLog() => File(
      '${tempRoot.path}${Platform.pathSeparator}updates'
      '${Platform.pathSeparator}backup'
      '${Platform.pathSeparator}rollback_log.json',
    );

    test('rollbackSupported is false with no restore point on disk', () async {
      expect(await controller.rollbackSupported(), isFalse);
    });

    test(
      'rollbackSupported flips to true once a restore point exists',
      () async {
        final log = rollbackLog();
        await log.parent.create(recursive: true);
        await log.writeAsString(
          jsonEncode({
            'moved': <Map<String, String>>[],
            'created': <String>[],
            'created_dirs': <String>[],
          }),
        );

        expect(await controller.rollbackSupported(), isTrue);
      },
    );

    test(
      'rollback throws UnsupportedError when no restore point exists',
      () async {
        expect(
          () => controller.rollback(jobId: 'job-1'),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );

    test(
      'rollback refuses when restore point exists but applySafetyCheck is unwired',
      () async {
        // A restore point is enough for UpdateService.rollbackToPrevious to
        // launch the external updater. The probe overrides that launch so a
        // controller that skips the safety check fails this test instead of
        // starting the real updater binary.
        final probe = _RollbackProbe(
          currentVersion: '2.1.0',
          currentBuildNumber: 42,
          applicationSupportDirectoryProvider: () async => tempRoot,
        );
        final unwired = UpdateController(
          service: probe,
          currentVersion: '2.1.0',
          currentBuildNumber: 42,
          stateDirectory: () async => tempRoot,
        );
        addTearDown(unwired.dispose);
        final log = rollbackLog();
        await log.parent.create(recursive: true);
        await log.writeAsString(
          jsonEncode({
            'moved': <Map<String, String>>[],
            'created': <String>[],
            'created_dirs': <String>[],
          }),
        );
        expect(
          () => unwired.rollback(jobId: 'job-2'),
          throwsA(
            isA<StateError>().having(
              (error) => error.toString(),
              'message',
              contains('no host safety check'),
            ),
          ),
        );
        expect(probe.launcherInvocations, 0);
      },
    );
  });
}

/// Stands in for the external updater so a missing safety check cannot spawn it.
class _RollbackProbe extends UpdateService {
  int launcherInvocations = 0;

  _RollbackProbe({
    required super.currentVersion,
    required super.currentBuildNumber,
    required super.applicationSupportDirectoryProvider,
  });

  @override
  Future<void> rollbackToPrevious() async {
    launcherInvocations++;
    throw StateError('updater launch blocked by test');
  }
}
