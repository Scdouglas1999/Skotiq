// The log directory must belong to the INSTANCE, not to the application.
//
// The platform application-support folder is shared by every Skotiq on the
// machine. A headless daemon started beside the GUI — the side-by-side layout
// `main_headless` documents, selected with SKOTIQ_DATA_DIR — resolved that
// same folder and both processes appended to one rolling `skotiq.log`,
// while the app reported that shared path as "Log directory" for a profile
// whose data lived elsewhere.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

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

  String logsUnder(Directory root) =>
      '${root.path}${Platform.pathSeparator}logs';

  test('SKOTIQ_DATA_DIR moves logging off the shared application-support '
      'folder', () async {
    String? nativeLogDirectory;
    final service = LoggingService(
      applicationSupportDirectoryProvider: () async => sharedSupportDir,
      environment: {skotiqDataDirEnv: ownDataRoot.path},
      nativeInitWithLogging: ({logDirectory}) {
        nativeLogDirectory = logDirectory;
      },
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    addTearDown(service.dispose);

    await service.initialize();

    expect(service.logDirectory, logsUnder(ownDataRoot));
    // The native appender must be pointed at the same tree; if only the Dart
    // side moved, the rolling file would still be written into the shared
    // folder.
    expect(nativeLogDirectory, logsUnder(ownDataRoot));
    expect(Directory(logsUnder(ownDataRoot)).existsSync(), isTrue);
    expect(Directory(logsUnder(sharedSupportDir)).existsSync(), isFalse);
  });

  test(
    'without the override logging stays under application support',
    () async {
      final service = LoggingService(
        applicationSupportDirectoryProvider: () async => sharedSupportDir,
        environment: const <String, String>{},
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => null,
      );
      addTearDown(service.dispose);

      await service.initialize();

      expect(service.logDirectory, logsUnder(sharedSupportDir));
    },
  );

  test(
    'a blank override is ignored rather than resolving to the CWD',
    () async {
      final service = LoggingService(
        applicationSupportDirectoryProvider: () async => sharedSupportDir,
        environment: const {skotiqDataDirEnv: '   '},
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => null,
      );
      addTearDown(service.dispose);

      await service.initialize();

      expect(service.logDirectory, logsUnder(sharedSupportDir));
    },
  );
}
