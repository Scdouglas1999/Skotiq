import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/utils.dart';

/// Attaches a [LoggingService] to [Log] for the rest of the current test and
/// returns it, so the test can read what reached the app log with
/// [LoggingService.getRecentLogs]. The native logger is stubbed out.
Future<LoggingService> captureAppLog() async {
  final dataRoot = Directory.systemTemp.createTempSync('sk-captured-log');
  final service = LoggingService(
    applicationSupportDirectoryProvider: () async => dataRoot,
    environment: {skotiqDataDirEnv: dataRoot.path},
    nativeInitWithLogging: ({logDirectory}) {},
    nativeInit: () {},
    currentLogFileProvider: () => null,
  );
  await service.initialize();
  Log.attach(service);
  addTearDown(() async {
    Log.detach(service);
    await service.dispose();
    dataRoot.deleteSync(recursive: true);
  });
  return service;
}

/// The entries from [source] that reached [service].
List<LogEntry> logFrom(LoggingService service, String source) =>
    service.getRecentLogs().where((e) => e.source == source).toList();
