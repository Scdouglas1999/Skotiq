import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/diagnostic_dump_service.dart';
import 'package:skotiq_core/src/services/logging_service.dart';

/// The diagnostic dump advertises "recent log files" but LoggingService.exportLogs
/// concatenated EVERY file in the log directory with no time bound, and the
/// native appender is a daily roller with no retention cap. A long-lived
/// install therefore attached months of capture paths, target names and host
/// names to a bug report.
void main() {
  late Directory appDir;
  late Directory logDir;

  setUp(() async {
    appDir = await Directory.systemTemp.createTemp('skotiq_log_export_');
    logDir = Directory('${appDir.path}${Platform.pathSeparator}logs');
    await logDir.create(recursive: true);
  });

  tearDown(() async {
    if (await appDir.exists()) {
      await appDir.delete(recursive: true);
    }
  });

  LoggingService buildService() => LoggingService(
    applicationSupportDirectoryProvider: () async => appDir,
    nativeInitWithLogging: ({logDirectory}) {},
    nativeInit: () {},
    currentLogFileProvider: () => 'skotiq.log',
  );

  Future<File> writeLogFile(String name, String body, Duration age) async {
    final file = File('${logDir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(body);
    await file.setLastModified(DateTime.now().subtract(age));
    return file;
  }

  test('an aged-out rotated log is excluded from a bounded export', () async {
    await writeLogFile(
      'skotiq.log.2024-01-01',
      'ANCIENT /home/op/Pictures/last-january/M31',
      const Duration(days: 400),
    );
    await writeLogFile(
      'skotiq.log',
      'TONIGHT slewing to NGC 7000',
      const Duration(minutes: 5),
    );

    final service = buildService();
    final out = '${appDir.path}${Platform.pathSeparator}export.txt';
    await service.exportLogs(out, maxAge: const Duration(hours: 48));
    final body = await File(out).readAsString();

    expect(body, contains('TONIGHT slewing to NGC 7000'));
    expect(body, isNot(contains('ANCIENT')));
    expect(body, contains('Span: log files modified in the last 2 days'));
  });

  test('getLogFiles without a bound still returns everything', () async {
    await writeLogFile(
      'skotiq.log.2024-01-01',
      'ANCIENT',
      const Duration(days: 400),
    );
    await writeLogFile('skotiq.log', 'TONIGHT', const Duration(minutes: 5));

    final service = buildService();
    // Named rather than counted, because the service writes a third file into
    // this directory the moment it initialises: its own daily-rolling
    // `skotiq-dart.log.<day>`, which is where every Dart entry now lands.
    // A count assertion would read that arrival as a regression.
    String leafOf(String path) => path.split(Platform.pathSeparator).last;

    final unbounded = (await service.getLogFiles()).map(leafOf).toList();
    expect(
      unbounded,
      containsAll(<String>['skotiq.log.2024-01-01', 'skotiq.log']),
    );
    expect(
      unbounded.where((name) => name.startsWith('skotiq-dart.log')),
      hasLength(1),
    );

    // The 400-day-old rotation is the only file the bound excludes; both
    // fresh files survive it.
    final bounded = (await service.getLogFiles(
      maxAge: const Duration(hours: 48),
    )).map(leafOf).toList();
    expect(bounded, isNot(contains('skotiq.log.2024-01-01')));
    expect(bounded, contains('skotiq.log'));
  });

  test('the dump ships only its retention window of logs', () async {
    await writeLogFile(
      'skotiq.log.2024-01-01',
      'ANCIENT /home/op/Pictures/last-january/M31',
      const Duration(days: 400),
    );
    await writeLogFile(
      'skotiq.log',
      'TONIGHT slewing to NGC 7000',
      const Duration(minutes: 5),
    );

    final logging = buildService();
    await logging.ensureInitialized();
    final service = DiagnosticDumpService(
      logging: logging,
      gatherProfile: () async => null,
      gatherSequence: () => null,
      gatherDevices: () => const [],
      gatherSystemInfo: () async => const {},
      tempDirProvider: () async => appDir,
    );
    final outPath = '${appDir.path}${Platform.pathSeparator}dump.zip';
    final file = await service.createDump(outputPath: outPath);
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());

    final logs = archive.files.firstWhere(
      (f) => f.name == 'logs/exported_logs.txt',
    );
    final body = utf8.decode(logs.content as List<int>);
    expect(body, contains('TONIGHT slewing to NGC 7000'));
    expect(
      body,
      isNot(contains('ANCIENT')),
      reason: 'a bug report must not carry a year of capture paths',
    );

    final manifestFile = archive.files.firstWhere(
      (f) => f.name == 'manifest.json',
    );
    final manifest =
        jsonDecode(utf8.decode(manifestFile.content as List<int>))
            as Map<String, Object?>;
    final logEntry = (manifest['entries'] as List)
        .cast<Map<String, Object?>>()
        .firstWhere((e) => e['name'] == 'logs');
    expect(logEntry['span_hours'], 48);
    expect(logEntry['span_start'], isA<String>());
  });
}
