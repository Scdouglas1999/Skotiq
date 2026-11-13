import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

/// Services that hold no provider `Ref` log through [Log]; their lines must
/// reach the same file as every other Dart entry.
void main() {
  late Directory dataRoot;
  late LoggingService service;

  setUp(() async {
    dataRoot = Directory.systemTemp.createTempSync('sk-process-log');
    service = LoggingService(
      applicationSupportDirectoryProvider: () async => dataRoot,
      environment: {skotiqDataDirEnv: dataRoot.path},
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    await service.initialize();
    Log.attach(service);
  });

  tearDown(() async {
    Log.detach(service);
    await service.dispose();
    dataRoot.deleteSync(recursive: true);
  });

  String fileText() => Directory('${dataRoot.path}/logs')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains(dartLogFileBaseName))
      .map((f) => f.readAsStringSync())
      .join();

  test('an entry reaches the log file with its level and source', () {
    Log.info('Auto-saving 2 sequences', source: 'AutoSaveService');

    final line = fileText()
        .split('\n')
        .firstWhere((l) => l.contains('Auto-saving 2 sequences'));
    expect(line, contains('INFO'));
    expect(line, contains('[AutoSaveService]'));
  });

  test('the error is stated once and the stack head is kept', () {
    final stack = StackTrace.current;
    Log.error(
      'Flat capture failed',
      source: 'FlatWizardService',
      error: StateError('shutter stuck'),
      stackTrace: stack,
    );
    Log.warning(
      'Backup failed: Bad state: disk full',
      source: 'AutoSaveService',
      error: StateError('disk full'),
    );

    final entries = service.getRecentLogs();
    final flat = entries.firstWhere((e) => e.source == 'FlatWizardService');
    expect(flat.level, LogLevel.error);
    expect(flat.message, 'Flat capture failed: Bad state: shutter stuck');
    expect(flat.fields['stackTrace'], contains('process_log_test.dart'));
    final backup = entries.firstWhere((e) => e.source == 'AutoSaveService');
    expect(backup.message, 'Backup failed: Bad state: disk full');
  });

  test(
    'a call with no service attached, or after dispose, does not throw',
    () async {
      Log.detach(service);
      Log.warning('before the container exists', source: 'Startup');

      Log.attach(service);
      await service.dispose();
      Log.warning('after shutdown', source: 'Shutdown');

      expect(fileText(), isNot(contains('before the container exists')));
      expect(fileText(), isNot(contains('after shutdown')));
    },
  );

  test('a message that opens with its own source tag is not tagged twice', () {
    Log.warning(
      '[SecretsStore] read(webhook.url) failed',
      source: 'SecretsStore',
    );
    expect(
      service.getRecentLogs().last.toString(),
      endsWith('[SecretsStore] read(webhook.url) failed'),
    );
  });

  test('developer levels map onto log levels', () {
    expect(LogLevel.fromDeveloperLevel(500), LogLevel.debug);
    expect(LogLevel.fromDeveloperLevel(800), LogLevel.info);
    expect(LogLevel.fromDeveloperLevel(900), LogLevel.warning);
    expect(LogLevel.fromDeveloperLevel(1000), LogLevel.error);
    expect(LogLevel.fromDeveloperLevel(1200), LogLevel.critical);
  });
}
