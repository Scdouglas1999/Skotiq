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
      tempRoot = await Directory.systemTemp.createTemp(
        'skotiq_ctrl_rollback_',
      );
      final service = UpdateService(
        currentVersion: '2.1.0',
        currentBuildNumber: 42,
        applicationSupportDirectoryProvider: () async => tempRoot,
      );
      controller = UpdateController(
        service: service,
        currentVersion: '2.1.0',
        currentBuildNumber: 42,
        stateDirectory: tempRoot,
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
  });
}
