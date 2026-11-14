import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

void main() {
  late Directory root;
  late LoggingService service;

  Future<void> initialize({Future<void> Function(File, String)? append}) async {
    root = await Directory.systemTemp.createTemp('sk-request-log-');
    service = LoggingService(
      environment: {skotiqDataDirEnv: root.path},
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
      appendRequestLine: append,
    );
    addTearDown(() async {
      await service.dispose();
      await root.delete(recursive: true);
    });
    await service.initialize();
  }

  test(
    'slow request writes yield, stay ordered, and do not buffer sync logs',
    () async {
      final blocked = Completer<void>();
      final entered = Completer<void>();
      final writes = <String>[];
      await initialize(
        append: (file, line) async {
          writes.add(line);
          if (!entered.isCompleted) entered.complete();
          await blocked.future;
          await file.writeAsString(line, mode: FileMode.writeOnlyAppend);
        },
      );
      addTearDown(() {
        if (!blocked.isCompleted) blocked.complete();
      });
      final received = <LogEntry>[];
      final subscription = service.logEntryStream.listen(received.add);
      addTearDown(subscription.cancel);

      var completed = false;
      final first = service
          .logRequest(LogLevel.info, 'first request', fields: {'id': 1})
          .then((_) => completed = true);
      final second = service.logRequest(LogLevel.error, 'second request');
      await entered.future;
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(writes, hasLength(1));
      expect(
        received.map((e) => e.message),
        ['first request', 'second request'],
        reason: 'SSE timestamp order must not depend on disk latency',
      );

      service.error('synchronous capture error');
      expect(
        File(service.currentDartLogFile!).readAsStringSync(),
        contains('synchronous capture error'),
      );
      expect(
        File(service.currentDartLogFile!).readAsStringSync(),
        isNot(contains('first request')),
      );

      blocked.complete();
      await Future.wait([first, second]);
      await Future<void>.delayed(Duration.zero);
      final lines = await File(service.currentRequestLogFile!).readAsLines();
      expect(lines, hasLength(2));
      expect(lines.first, contains('first request'));
      expect(lines.first, contains('"id":1'));
      expect(lines.last, contains('ERROR'));
      expect(lines.last, contains('second request'));
      expect(received.map((e) => e.message), [
        'first request',
        'second request',
        'synchronous capture error',
      ]);
    },
  );

  test(
    'the default writer persists before returning and participates in retention',
    () async {
      await initialize();
      await service.logRequest(LogLevel.info, 'capture completed');
      final path = service.currentRequestLogFile!;
      expect(File(path).readAsStringSync(), contains('capture completed'));
      expect(await service.getLogFiles(), contains(path));
      final infos = await service.getLogFileInfos();
      expect(infos.singleWhere((f) => f.path == path).isCurrent, isTrue);
      final total = infos.fold<int>(0, (sum, file) => sum + file.sizeBytes);
      expect(await service.getLogSizeBytes(), total);
      final old = File(
        '${service.logDirectory}/skotiq-requests.log.2000-01-01',
      );
      await old.writeAsString('old request');
      final unrelated = File('${service.logDirectory}/skotiq-requests.log');
      await unrelated.writeAsString('unrelated');
      final exported = await service.exportLogs('${root.path}/export.txt');
      expect(
        await File(exported).readAsString(),
        contains('capture completed'),
      );
      final cleared = await service.clearLogs();
      expect(cleared.deletedFiles, contains(old.path));
      expect(await File(path).exists(), isTrue);
      expect(await unrelated.exists(), isTrue);
      expect(await service.readLogFile(path), contains('capture completed'));
    },
  );

  test(
    'dispose and exports drain accepted writes, and late writes cannot reopen files',
    () async {
      final blocked = Completer<void>();
      final entered = Completer<void>();
      await initialize(
        append: (file, line) async {
          if (!entered.isCompleted) entered.complete();
          await blocked.future;
          await file.writeAsString(line, mode: FileMode.writeOnlyAppend);
        },
      );
      addTearDown(() {
        if (!blocked.isCompleted) blocked.complete();
      });
      final writing = service.logRequest(
        LogLevel.info,
        'accepted before shutdown',
      );
      await entered.future;
      var exported = false;
      var disposed = false;
      final exporting = service
          .exportLogs('${root.path}/export.txt')
          .then((_) => exported = true);
      final disposing = service.dispose().then((_) => disposed = true);
      final disposingAgain = service.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(exported, isFalse);
      expect(disposed, isFalse);
      blocked.complete();
      await Future.wait([writing, exporting, disposing, disposingAgain]);
      expect(
        await File('${root.path}/export.txt').readAsString(),
        contains('accepted before shutdown'),
      );
      final file = File(service.currentRequestLogFile!);
      final content = await file.readAsString();
      await service.logRequest(LogLevel.info, 'late request');
      expect(await file.readAsString(), content);
      expect(service.getRecentLogs().last.message, 'late request');
    },
  );

  test(
    'write refusal is visible once while failing and retries recover',
    () async {
      var refuse = true;
      var attempts = 0;
      await initialize(
        append: (file, line) async {
          attempts++;
          if (refuse) throw const FileSystemException('disk unavailable');
          await file.writeAsString(line, mode: FileMode.writeOnlyAppend);
        },
      );
      await service.logRequest(LogLevel.info, 'first failed write');
      await service.logRequest(LogLevel.info, 'second failed write');
      expect(attempts, 2);
      expect(
        service.getRecentLogs().where(
          (e) =>
              e.level == LogLevel.error &&
              e.message.contains('request log file'),
        ),
        hasLength(1),
      );
      expect(
        File(service.currentDartLogFile!).readAsStringSync(),
        isNot(contains('request log file')),
        reason: 'failure reporting must not fall back to synchronous disk I/O',
      );
      refuse = false;
      await service.logRequest(LogLevel.info, 'recovered write');
      expect(attempts, 3);
      expect(
        await File(service.currentRequestLogFile!).readAsString(),
        contains('recovered write'),
      );
    },
  );

  test('only dated request filenames are allowed for download', () {
    expect(
      LoggingService.isSkotiqLogFileName('skotiq-requests.log.2026-11-14'),
      isTrue,
    );
    for (final name in [
      'skotiq-requests.log',
      '../skotiq-requests.log.2026-11-14',
      r'..\skotiq-requests.log.2026-11-14',
      'skotiq-requests.log.2026-11-14.bak',
    ]) {
      expect(LoggingService.isSkotiqLogFileName(name), isFalse, reason: name);
    }
  });
}
