// The native side starts its file log once. On a host `api_init_host` does
// it before the logging service exists; the service starts it only where no
// host init ran (the phone), as it always has there.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/utils.dart';

void main() {
  late Directory dataRoot;

  setUp(() => dataRoot = Directory.systemTemp.createTempSync('sk-log-once'));
  tearDown(() => dataRoot.deleteSync(recursive: true));

  Future<(List<String>, int)> start({
    required bool hostStarted,
    bool nativeThrows = false,
  }) async {
    var nativeStarts = 0;
    void native() {
      nativeStarts++;
      if (nativeThrows) throw StateError('native library not loaded');
    }

    final service = LoggingService(
      applicationSupportDirectoryProvider: () async => dataRoot,
      environment: const <String, String>{},
      nativeInitWithLogging: ({logDirectory}) => native(),
      nativeInit: native,
      nativeLoggingStarted: () => hostStarted,
      currentLogFileProvider: () => null,
    );
    addTearDown(service.dispose);
    await service.initialize();
    final logged = [
      for (final entry in service.getRecentLogs())
        if (entry.source == 'LoggingService') entry.message,
    ];
    return (logged, nativeStarts);
  }

  final logDir = () => '${dataRoot.path}${Platform.pathSeparator}logs';

  test('a host is not started a second time', () async {
    final (logged, starts) = await start(hostStarted: true);
    expect(starts, 0);
    expect(logged, [
      'Logging service initialized',
      'Log directory: ${logDir()}',
    ]);
  });

  test('without a host init the service starts the native log', () async {
    final (logged, starts) = await start(hostStarted: false);
    expect(starts, 1);
    expect(logged, [
      'Logging service initialized',
      'Log directory: ${logDir()}',
    ]);
  });

  test('the phone, with no native library, logs what it always did', () async {
    final (logged, starts) = await start(
      hostStarted: false,
      nativeThrows: true,
    );
    expect(starts, 2);
    expect(logged, [
      'File logging unavailable: Bad state: native library not loaded',
    ]);
  });
}
