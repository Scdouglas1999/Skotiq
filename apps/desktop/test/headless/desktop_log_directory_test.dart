// Logs must live under the data directory this instance is actually using.
//
// Live defect: a diagnostic dump generated from an instance started with
// SKOTIQ_DATA_DIR=/tmp/ns-audit/... carried 400+ lines naming three OTHER
// Skotiq instances' capture directories, target names and FITS filenames.
// Cause: the log directory was hard-coded to
// getApplicationSupportDirectory()/logs while only the Rust side honoured the
// env var, so every instance on the machine appended to one shared
// skotiq.log.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/desktop_logging_init.dart';

void main() {
  late Directory tempRoot;
  late Directory appSupport;

  Future<Directory> fakeAppSupport() async => appSupport;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('ns_logdir_test');
    appSupport = Directory('${tempRoot.path}/app_support')
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test(
    'log directory follows SKOTIQ_DATA_DIR when the operator sets it',
    () async {
      final instanceRoot = Directory('${tempRoot.path}/instance-a')
        ..createSync(recursive: true);

      final paths = await prepareDesktopLogDirectory(
        environment: {'SKOTIQ_DATA_DIR': instanceRoot.path},
        applicationSupportDirectory: fakeAppSupport,
      );

      expect(paths.dataRoot, instanceRoot.path);
      expect(paths.logDirectory, '${instanceRoot.path}/logs');
      expect(Directory(paths.logDirectory).existsSync(), isTrue);
      // The shared platform-support log directory must NOT be the target: that
      // is what made two instances write to one file.
      expect(paths.logDirectory, isNot(contains(appSupport.path)));
    },
  );

  test(
    'two instances with different data dirs get different log directories',
    () async {
      final a = Directory('${tempRoot.path}/a')..createSync(recursive: true);
      final b = Directory('${tempRoot.path}/b')..createSync(recursive: true);

      final first = await prepareDesktopLogDirectory(
        environment: {'SKOTIQ_DATA_DIR': a.path},
        applicationSupportDirectory: fakeAppSupport,
      );
      final second = await prepareDesktopLogDirectory(
        environment: {'SKOTIQ_DATA_DIR': b.path},
        applicationSupportDirectory: fakeAppSupport,
      );

      expect(first.logDirectory, isNot(second.logDirectory));
    },
  );

  test(
    'falls back to application support when the env var is absent',
    () async {
      // A blank value counts as unset, and exercises the same fallback without
      // touching the process environment.
      final paths = await prepareDesktopLogDirectory(
        environment: const {'SKOTIQ_DATA_DIR': '   '},
        applicationSupportDirectory: fakeAppSupport,
      );

      expect(paths.dataRoot, appSupport.path);
      expect(paths.logDirectory, '${appSupport.path}/logs');
      expect(Directory(paths.logDirectory).existsSync(), isTrue);
    },
  );
}
