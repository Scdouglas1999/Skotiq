// Tests for LoggingService's logEntryStream broadcast.
//
// The headless API `/api/logs/tail` SSE handler depends on every public
// log method emitting on the broadcast stream. These tests verify that
// contract holds: emission ordering, multi-subscriber fan-out, severity
// preservation, and clean shutdown via dispose().
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/logging_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loggingServiceProvider closes its stream with the container', () async {
    final container = ProviderContainer();
    final service = container.read(loggingServiceProvider);
    final done = Completer<void>();
    service.logEntryStream.listen(null, onDone: done.complete);

    container.dispose();

    await done.future.timeout(const Duration(seconds: 2));
  });

  group('LoggingService.logEntryStream', () {
    late Directory tempDir;
    late LoggingService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ns_log_stream_test_');
      service = LoggingService(
        applicationSupportDirectoryProvider: () async => tempDir,
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => null,
      );
      await service.ensureInitialized();
    });

    tearDown(() async {
      await service.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('emits every entry written via the public log methods', () async {
      final received = <LogEntry>[];
      final sub = service.logEntryStream.listen(received.add);

      service.debug('debug-msg', source: 'TestSrc');
      service.info('info-msg');
      service.warning('warn-msg', fields: {'k': 'v'});
      service.error('err-msg');
      service.critical('crit-msg');

      // Allow microtasks to flush so broadcast subscribers see all events.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      // Filter to the entries we wrote — initialization itself emits a
      // couple of "Logging service initialized" lines.
      final messages = received.map((e) => e.message).toList();
      expect(
        messages,
        containsAll(<String>[
          'debug-msg',
          'info-msg',
          'warn-msg',
          'err-msg',
          'crit-msg',
        ]),
      );
    });

    test(
      'preserves severity, source, message, and fields on emission',
      () async {
        final received = <LogEntry>[];
        final sub = service.logEntryStream.listen(received.add);

        service.warning(
          'guiding lost',
          source: 'GuidingService',
          fields: {'rms': 1.42, 'deviceId': 'phd2:default'},
        );

        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        final entry = received.firstWhere((e) => e.message == 'guiding lost');
        expect(entry.level, LogLevel.warning);
        expect(entry.source, 'GuidingService');
        expect(entry.fields['rms'], 1.42);
        expect(entry.fields['deviceId'], 'phd2:default');
      },
    );

    test('every subscriber on a broadcast stream sees each entry', () async {
      final aReceived = <LogEntry>[];
      final bReceived = <LogEntry>[];
      final cReceived = <LogEntry>[];

      final aSub = service.logEntryStream.listen(aReceived.add);
      final bSub = service.logEntryStream.listen(bReceived.add);
      final cSub = service.logEntryStream.listen(cReceived.add);

      service.info('m1');
      service.info('m2');

      await Future<void>.delayed(Duration.zero);
      await aSub.cancel();
      await bSub.cancel();
      await cSub.cancel();

      bool sawBoth(List<LogEntry> entries) =>
          entries.any((e) => e.message == 'm1') &&
          entries.any((e) => e.message == 'm2');

      expect(sawBoth(aReceived), isTrue, reason: 'subscriber A missed entries');
      expect(sawBoth(bReceived), isTrue, reason: 'subscriber B missed entries');
      expect(sawBoth(cReceived), isTrue, reason: 'subscriber C missed entries');
    });

    test(
      'dispose() closes the stream and emits onDone to subscribers',
      () async {
        final done = Completer<void>();
        final sub = service.logEntryStream.listen(
          (_) {},
          onDone: () => done.complete(),
        );

        await service.dispose();
        // dispose() awaits close() internally, but the subscription's
        // onDone fires on the next microtask.
        await done.future.timeout(const Duration(seconds: 2));
        await sub.cancel();
      },
    );

    test('dispose() is idempotent', () async {
      await service.dispose();
      await service.dispose(); // must not throw
    });

    test('log calls after dispose do not throw', () {
      service.dispose();
      // The service is best-effort; a late-arriving log() must not
      // bubble up to the caller (which would re-introduce the very
      // dangling-disposal bug we are guarding against).
      expect(() => service.info('post-dispose'), returnsNormally);
    });
  });

  group('LoggingService.parseLogLevel', () {
    test('matches case-insensitively', () {
      expect(LoggingService.parseLogLevel('INFO'), LogLevel.info);
      expect(LoggingService.parseLogLevel('warning'), LogLevel.warning);
      expect(LoggingService.parseLogLevel('  Critical  '), LogLevel.critical);
    });

    test('returns null for unknown names', () {
      expect(LoggingService.parseLogLevel('panic'), isNull);
      expect(LoggingService.parseLogLevel(''), isNull);
    });
  });

  group('LoggingService.isSkotiqLogFileName', () {
    test('accepts canonical and rotated names', () {
      expect(LoggingService.isSkotiqLogFileName('skotiq.log'), isTrue);
      expect(
        LoggingService.isSkotiqLogFileName('skotiq.log.2026-05-24'),
        isTrue,
      );
    });

    test('rejects path traversal and other extensions', () {
      expect(LoggingService.isSkotiqLogFileName('../etc/passwd'), isFalse);
      expect(LoggingService.isSkotiqLogFileName('skotiq.log.txt'), isFalse);
      expect(
        LoggingService.isSkotiqLogFileName('SKOTIQ.LOG'),
        isFalse,
        reason: 'regex is case-sensitive to match Rust appender output',
      );
      expect(
        LoggingService.isSkotiqLogFileName('skotiq.log.2026-5-24'),
        isFalse,
        reason: 'date suffix requires zero-padded ISO format',
      );
    });
  });

  group('LoggingService.getLogFileInfos', () {
    late Directory tempDir;
    late LoggingService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ns_log_infos_test_');
      service = LoggingService(
        applicationSupportDirectoryProvider: () async => tempDir,
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => null,
      );
      await service.ensureInitialized();
    });

    tearDown(() async {
      await service.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('returns metadata for skotiq log files only', () async {
      final logsDir = Directory('${service.logDirectory}');
      // Plant three rotated logs and one decoy.
      await File('${logsDir.path}/skotiq.log.2026-05-22').writeAsString('day1');
      await File('${logsDir.path}/skotiq.log.2026-05-23').writeAsString('day2');
      await File('${logsDir.path}/skotiq.log').writeAsString('current');
      await File('${logsDir.path}/decoy.txt').writeAsString('not-a-log');

      final infos = await service.getLogFileInfos();
      final names = infos.map((e) => e.name).toList();

      expect(
        names,
        containsAll(<String>[
          'skotiq.log',
          'skotiq.log.2026-05-22',
          'skotiq.log.2026-05-23',
        ]),
      );
      expect(names.contains('decoy.txt'), isFalse);
      for (final info in infos) {
        expect(info.sizeBytes, greaterThan(0));
      }
    });
  });

  group('LoggingService.clearLogs', () {
    late Directory tempDir;
    late LoggingService service;
    late String currentLogPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ns_log_clear_test_');
      // Use a fake current-log filename inside the log directory so the
      // service preserves it on clear.
      service = LoggingService(
        applicationSupportDirectoryProvider: () async => tempDir,
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        // The current-log file is named relative to the log directory
        // the service computes from tempDir.
        currentLogFileProvider: () =>
            '${tempDir.path}${Platform.pathSeparator}logs${Platform.pathSeparator}skotiq.log',
      );
      await service.ensureInitialized();
      currentLogPath = service.currentLogFile!;
      // Plant the files AFTER initialization so they aren't clobbered.
      await File(currentLogPath).writeAsString('current');
      await File(
        '${service.logDirectory}/skotiq.log.2026-05-22',
      ).writeAsString('day1-day1');
    });

    tearDown(() async {
      await service.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('deletes rotated logs and reports freedBytes', () async {
      final result = await service.clearLogs();
      expect(result.deletedFiles, hasLength(1));
      expect(result.deletedFiles.single, contains('2026-05-22'));
      expect(result.freedBytes, 'day1-day1'.length);
      expect(result.errors, isEmpty);

      // Current log is preserved.
      expect(await File(currentLogPath).exists(), isTrue);
    });
  });
}
