import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/logging_service.dart';

void main() {
  test('initializes lazily once and auto-starts on log', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_logging_test_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    var initWithLoggingCalls = 0;
    var initCalls = 0;

    final service = LoggingService(
      applicationSupportDirectoryProvider: () async => tempDir,
      nativeInitWithLogging: ({logDirectory}) {
        initWithLoggingCalls++;
      },
      nativeInit: () {
        initCalls++;
      },
      currentLogFileProvider: () => 'skotiq.log',
    );

    expect(service.currentLogFile, isNull);

    service.info('boot');
    await service.ensureInitialized();
    await service.getLogFiles();

    expect(initWithLoggingCalls, 1);
    expect(initCalls, 0);
    expect(service.currentLogFile, 'skotiq.log');
  });

  test('records structured fields on log entries', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_logging_test_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final service = LoggingService(
      applicationSupportDirectoryProvider: () async => tempDir,
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => 'skotiq.log',
    );
    await service.ensureInitialized();

    service.info(
      'request completed',
      source: 'HeadlessApiServer',
      fields: {
        'requestId': 'req-1',
        'statusCode': 200,
        'nested': {'phase': 'completed'},
      },
    );

    final entry = service.getRecentLogs().last;
    expect(entry.fields['requestId'], 'req-1');
    expect(entry.fields['statusCode'], 200);
    expect(entry.toString(), contains('"requestId":"req-1"'));
    expect(entry.toString(), contains('"phase":"completed"'));
  });
}
