// A Dart log line has to reach the disk.
//
// Before this, `LoggingService.log` fed three places: `dart:developer`, a
// 1000-entry in-memory ring, and the SSE broadcast the headless tail serves.
// None of them survives the process. Measured against the release bundle: a
// GUI whose watched folder was absent recorded a typed `destinationUnreachable`
// against the destination, and the only log file in the data directory — 28 KB
// of it — carried `skotiq_bridge` and `skotiq_native` tracing and zero
// lines from DeliveryService, DeliveryRetrySweeper or any other Dart source. An
// operator diagnosing a failed night in the morning had nothing to read, and
// the ring had long since evicted the entry (one 78-second sim night put 299
// SequenceExecutor entries into it).
//
// The choice these tests pin: the Dart entries get their OWN daily-rolling file
// beside the Rust one rather than sharing it, because
// `tracing_appender::rolling::daily` holds a buffered handle on
// `skotiq.log.YYYY-MM-DD` for the life of the process and two buffered
// writers on one file interleave partial lines. Both names are readable,
// listable, sizable, exportable and downloadable as one log set.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late Directory dataRoot;

  setUp(() {
    dataRoot = Directory.systemTemp.createTempSync('ns-dart-log');
  });

  tearDown(() {
    if (dataRoot.existsSync()) dataRoot.deleteSync(recursive: true);
  });

  String logsDir() => '${dataRoot.path}${Platform.pathSeparator}logs';

  String todayStamp() {
    final now = DateTime.now().toUtc();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }

  /// A service anchored on [dataRoot] with the Rust bridge stubbed out, since
  /// no FFI symbol is bound in a unit test.
  LoggingService buildService({String? nativeCurrentLogFile}) {
    final service = LoggingService(
      applicationSupportDirectoryProvider: () async => dataRoot,
      environment: {skotiqDataDirEnv: dataRoot.path},
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => nativeCurrentLogFile,
    );
    addTearDown(service.dispose);
    return service;
  }

  File dartLogFile() => File(
    '${logsDir()}${Platform.pathSeparator}skotiq-dart.log'
    '.${todayStamp()}',
  );

  test('a typed delivery failure is on disk, not only in memory', () async {
    final service = buildService();
    await service.initialize();

    // The shape DeliveryService._log emits for a retryable failure.
    service.warning(
      'Delivery to observatory-nas (watched_folder): destinationUnreachable: '
      '/mnt/nas/drop is not on the filesystem right now',
      source: 'DeliveryService',
    );
    await service.dispose();

    final file = dartLogFile();
    expect(
      file.existsSync(),
      isTrue,
      reason: 'the rolling file the service set up must be the one it writes',
    );
    final contents = file.readAsStringSync();
    expect(contents, contains('DeliveryService'));
    expect(contents, contains('destinationUnreachable'));
    expect(contents, contains('WARNING'));
  });

  test('entries land line by line, in order, unbuffered', () async {
    final service = buildService();
    await service.initialize();

    service.info('first', source: 'DeliveryRetrySweeper');
    service.error('second', source: 'DeliveryService');

    // Read WITHOUT disposing: a process killed at 04:00 never gets to close
    // its handles, and the line that says why must already be on disk.
    final lines = dartLogFile()
        .readAsLinesSync()
        .where(
          (line) =>
              line.contains('DeliveryRetrySweeper') ||
              line.contains('DeliveryService'),
        )
        .toList();
    expect(lines, hasLength(2));
    expect(lines.first, contains('first'));
    expect(lines.last, contains('second'));
  });

  test('structured fields survive the round trip to disk', () async {
    final service = buildService();
    await service.initialize();

    service.info(
      'Delivery retry sweep: observatory-nas: 2 delivered',
      source: 'DeliveryRetrySweeper',
      fields: {'delivered': 2, 'retrying': 0},
    );

    final contents = dartLogFile().readAsStringSync();
    expect(contents, contains('"delivered":2'));
    expect(contents, contains('"retrying":0'));
  });

  test(
    'the Dart file is listed, sized and exported with the Rust one',
    () async {
      final rustToday = File(
        '${logsDir()}${Platform.pathSeparator}skotiq.log.${todayStamp()}',
      );
      final service = buildService(nativeCurrentLogFile: rustToday.path);
      await service.initialize();
      rustToday.writeAsStringSync('INFO skotiq_bridge: native line\n');

      service.error(
        'Delivery to observatory-nas (sftp): transportToolMissing',
        source: 'DeliveryService',
      );

      final files = await service.getLogFiles();
      expect(files, contains(dartLogFile().path));
      expect(files, contains(rustToday.path));

      expect(await service.getLogSizeBytes(), greaterThan(0));

      final infos = await service.getLogFileInfos();
      expect(
        infos.map((info) => info.name),
        containsAll(<String>[
          'skotiq-dart.log.${todayStamp()}',
          'skotiq.log.${todayStamp()}',
        ]),
      );

      final exportPath = '${dataRoot.path}${Platform.pathSeparator}export.txt';
      await service.exportLogs(exportPath, maxAge: const Duration(days: 2));
      final exported = File(exportPath).readAsStringSync();
      expect(exported, contains('transportToolMissing'));
      expect(exported, contains('native line'));
    },
  );

  test('the download filter accepts both rolling names and nothing else', () {
    expect(
      LoggingService.isSkotiqLogFileName('skotiq-dart.log.2026-08-18'),
      isTrue,
    );
    expect(
      LoggingService.isSkotiqLogFileName('skotiq.log.2026-08-18'),
      isTrue,
    );
    expect(LoggingService.isSkotiqLogFileName('skotiq.log'), isTrue);
    // The endpoint's whole job is refusing anything else in that directory.
    expect(
      LoggingService.isSkotiqLogFileName('skotiq-dart.log'),
      isFalse,
      reason: 'the Dart writer always stamps the day it rotates on',
    );
    expect(
      LoggingService.isSkotiqLogFileName('skotiq-dart.log.2026-8-1'),
      isFalse,
    );
    expect(
      LoggingService.isSkotiqLogFileName('../skotiq.log.2026-08-18'),
      isFalse,
    );
    expect(LoggingService.isSkotiqLogFileName('secrets.env'), isFalse);
  });

  test('clearLogs keeps the file the writer is holding open', () async {
    final service = buildService();
    await service.initialize();
    service.info('today', source: 'DeliveryService');

    final yesterday = File(
      '${logsDir()}${Platform.pathSeparator}skotiq-dart.log.2026-01-01',
    )..writeAsStringSync('an older day\n');

    final result = await service.clearLogs();

    expect(result.deletedFiles, contains(yesterday.path));
    expect(
      result.deletedFiles,
      isNot(contains(dartLogFile().path)),
      reason:
          'unlinking the open file would leave the writer appending into an '
          'inode nobody can read',
    );
    expect(dartLogFile().readAsStringSync(), contains('today'));
  });

  test(
    'a log directory that refuses writes says so once and keeps trying',
    () async {
      // Stand a directory where the day's file belongs, before anything opens
      // it: every open of that path then refuses, the way a read-only mount or a
      // full disk would.
      Directory(logsDir()).createSync(recursive: true);
      final blocked = dartLogFile();
      Directory(blocked.path).createSync();

      final service = buildService();
      await service.initialize();

      service.error('during the refusal', source: 'DeliveryService');
      service.error('and again', source: 'DeliveryService');

      final refusals = service
          .getRecentLogs()
          .where((entry) => entry.message.contains('could not be written'))
          .toList();
      expect(
        refusals,
        hasLength(1),
        reason: 'a disk that stays full states itself once per rotation',
      );
      expect(refusals.single.level, LogLevel.error);
      expect(refusals.single.message, contains('skotiq-dart.log'));

      // The entries themselves are still readable where the Log Viewer and the
      // export read them, so nothing was swallowed.
      expect(
        service.getRecentLogs().map((entry) => entry.message),
        containsAll(<String>['during the refusal', 'and again']),
      );

      // And the disk is asked again the moment it can answer.
      Directory(blocked.path).deleteSync();
      service.info('after the refusal cleared', source: 'DeliveryService');
      expect(blocked.readAsStringSync(), contains('after the refusal cleared'));
    },
  );
}
