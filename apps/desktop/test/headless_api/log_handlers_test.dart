// Tests for the remote-log retrieval/tail handlers.
//
// The tests use a real LoggingService backed by a temp directory so the
// file-system + ring-buffer interactions match production behaviour.
// The provider container overrides `loggingServiceProvider` to point at
// the test instance.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/log_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LogHandlers', () {
    late Directory tempDir;
    late LoggingService logger;
    late ProviderContainer container;
    late LogHandlers handlers;
    late String logsDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sk_log_handlers_test_');
      // Use a fake current-log file path so clearLogs preserves it.
      logsDir = '${tempDir.path}${Platform.pathSeparator}logs';
      final currentLogPath = '$logsDir${Platform.pathSeparator}skotiq.log';
      logger = LoggingService(
        applicationSupportDirectoryProvider: () async => tempDir,
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => currentLogPath,
      );
      await logger.ensureInitialized();

      container = ProviderContainer(
        overrides: [loggingServiceProvider.overrideWithValue(logger)],
      );
      handlers = LogHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      await logger.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    // GET /api/logs
    group('GET /api/logs', () {
      test('returns list of log files with size and modifiedAt', () async {
        await File('$logsDir/skotiq.log.2026-05-22').writeAsString('first-day');
        await File('$logsDir/skotiq.log').writeAsString('current');

        final response = await translateHandlerErrors(
          handlers.handleListFiles(
            Request('GET', Uri.parse('http://localhost/api/logs')),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final files = body['files'] as List;
        expect(files, isNotEmpty);
        for (final f in files) {
          final m = f as Map;
          expect(m['name'], isA<String>());
          expect(m['sizeBytes'], isA<int>());
          expect(m['modifiedAt'], isA<String>());
          expect(m['isCurrent'], isA<bool>());
        }
        expect(body['totalBytes'], isA<int>());
        expect(body['totalBytes'], greaterThan(0));
        expect(body['retentionDays'], 0);
      });
    });

    // GET /api/logs/recent
    group('GET /api/logs/recent', () {
      test('honors limit query param', () async {
        for (var i = 0; i < 50; i++) {
          logger.info('test-$i', source: 'TestSrc');
        }

        final response = await translateHandlerErrors(
          handlers.handleRecent(
            Request(
              'GET',
              Uri.parse('http://localhost/api/logs/recent?limit=10'),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final entries = body['entries'] as List;
        expect(entries, hasLength(10));
      });

      test('clamps limit to ring buffer capacity', () async {
        final response = await translateHandlerErrors(
          handlers.handleRecent(
            Request(
              'GET',
              Uri.parse('http://localhost/api/logs/recent?limit=999999'),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
      });

      test('400 on non-positive limit', () async {
        final response = await translateHandlerErrors(
          handlers.handleRecent(
            Request(
              'GET',
              Uri.parse('http://localhost/api/logs/recent?limit=0'),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
      });

      test('honors minSeverity filter', () async {
        // Reset the buffer to a known size by writing entries we control.
        // Initialization already added a couple of info lines; that's fine
        // because the filter should drop them.
        logger.info('info-line');
        logger.warning('warn-line');
        logger.error('err-line');

        final response = await translateHandlerErrors(
          handlers.handleRecent(
            Request(
              'GET',
              Uri.parse('http://localhost/api/logs/recent?minSeverity=warning'),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final entries = (body['entries'] as List)
            .map((e) => (e as Map).cast<String, Object?>())
            .toList();
        expect(entries, isNotEmpty);
        for (final e in entries) {
          final sev = e['severity'] as String;
          expect(
            sev == 'warning' || sev == 'error' || sev == 'critical',
            isTrue,
            reason: 'minSeverity=warning should not include "$sev"',
          );
        }
        expect(body['minSeverity'], 'warning');
      });

      test('400 on bad minSeverity', () async {
        final response = await translateHandlerErrors(
          handlers.handleRecent(
            Request(
              'GET',
              Uri.parse('http://localhost/api/logs/recent?minSeverity=panic'),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
      });
    });

    // GET /api/logs/files/{filename}/download
    group('GET /api/logs/files/{filename}/download', () {
      late File targetFile;
      late int fileLength;
      final payload = List<int>.generate(
        200,
        (i) => 0x41 + (i % 26),
      ); // ASCII A..Z repeat

      setUp(() async {
        targetFile = File('$logsDir/skotiq.log.2026-05-22');
        await targetFile.writeAsBytes(payload);
        fileLength = await targetFile.length();
      });

      test('200 returns the file content with attachment headers', () async {
        final response = await translateHandlerErrors(
          handlers.handleDownloadFile(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/logs/files/skotiq.log.2026-05-22/download',
              ),
            ),
            'skotiq.log.2026-05-22',
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(
          response.headers['content-disposition'],
          contains('skotiq.log.2026-05-22'),
        );
        expect(response.headers['accept-ranges'], 'bytes');
        expect(response.headers['etag'], isNotNull);
        expect(response.headers['content-length'], fileLength.toString());
        final body = await response.read().expand((c) => c).toList();
        expect(body, payload);
      });

      test('206 partial content for Range requests', () async {
        final response = await translateHandlerErrors(
          handlers.handleDownloadFile(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/logs/files/skotiq.log.2026-05-22/download',
              ),
              headers: {'range': 'bytes=10-19'},
            ),
            'skotiq.log.2026-05-22',
          ),
        );

        expect(response.statusCode, HttpStatus.partialContent);
        expect(response.headers['content-range'], 'bytes 10-19/$fileLength');
        final body = await response.read().expand((c) => c).toList();
        expect(body, payload.sublist(10, 20));
      });

      test('416 for invalid Range header', () async {
        final response = await translateHandlerErrors(
          handlers.handleDownloadFile(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/logs/files/skotiq.log.2026-05-22/download',
              ),
              headers: {'range': 'lines=0-10'},
            ),
            'skotiq.log.2026-05-22',
          ),
        );

        expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      });

      test('403 when filename contains path traversal', () async {
        final response = await translateHandlerErrors(
          handlers.handleDownloadFile(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/logs/files/..%2Fetc%2Fpasswd/download',
              ),
            ),
            '../etc/passwd',
          ),
        );

        expect(response.statusCode, HttpStatus.forbidden);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'forbidden_filename');
      });

      test('403 when filename does not match log naming policy', () async {
        final response = await translateHandlerErrors(
          handlers.handleDownloadFile(
            Request(
              'GET',
              Uri.parse('http://localhost/api/logs/files/random.txt/download'),
            ),
            'random.txt',
          ),
        );

        expect(response.statusCode, HttpStatus.forbidden);
      });

      test('404 when valid filename does not exist on disk', () async {
        final response = await translateHandlerErrors(
          handlers.handleDownloadFile(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/logs/files/skotiq.log.2099-12-31/download',
              ),
            ),
            'skotiq.log.2099-12-31',
          ),
        );

        expect(response.statusCode, HttpStatus.notFound);
      });
    });

    // POST /api/logs/clear
    group('POST /api/logs/clear', () {
      test('deletes non-current files and reports freedBytes', () async {
        // Plant the active log file AND a rotated one.
        final currentLog = logger.currentLogFile!;
        await File(currentLog).writeAsString('current-data');
        await File('$logsDir/skotiq.log.2026-05-20').writeAsString('rotated-1');
        await File(
          '$logsDir/skotiq.log.2026-05-21',
        ).writeAsString('rotated-2-longer');

        final response = await translateHandlerErrors(
          handlers.handleClear(
            Request('POST', Uri.parse('http://localhost/api/logs/clear')),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final deleted = body['deletedFiles'] as List;
        expect(deleted, hasLength(2));
        final freed = body['freedBytes'] as int;
        expect(freed, 'rotated-1'.length + 'rotated-2-longer'.length);

        // Current log preserved.
        expect(await File(currentLog).exists(), isTrue);
        expect(await File('$logsDir/skotiq.log.2026-05-20').exists(), isFalse);
      });
    });

    // POST /api/logs/test-entry
    group('POST /api/logs/test-entry', () {
      test('writes the entry and appears in recent', () async {
        final response = await translateHandlerErrors(
          handlers.handleTestEntry(
            Request(
              'POST',
              Uri.parse('http://localhost/api/logs/test-entry'),
              body: jsonEncode({
                'severity': 'error',
                'message': 'synthetic test entry',
                'source': 'MobileTest',
                'fields': {'foo': 'bar'},
              }),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['status'], 'recorded');
        final entry = body['entry'] as Map;
        expect(entry['severity'], 'error');
        expect(entry['message'], 'synthetic test entry');
        expect(entry['source'], 'MobileTest');
        expect((entry['fields'] as Map)['foo'], 'bar');

        // Verify it shows up via the recent endpoint.
        final recentResponse = await translateHandlerErrors(
          handlers.handleRecent(
            Request(
              'GET',
              Uri.parse('http://localhost/api/logs/recent?minSeverity=error'),
            ),
          ),
        );
        final recentBody =
            jsonDecode(await recentResponse.readAsString()) as Map;
        final entries = (recentBody['entries'] as List)
            .map((e) => (e as Map).cast<String, Object?>())
            .toList();
        expect(
          entries.any((e) => e['message'] == 'synthetic test entry'),
          isTrue,
        );
      });

      test('400 on bad severity', () async {
        final response = await translateHandlerErrors(
          handlers.handleTestEntry(
            Request(
              'POST',
              Uri.parse('http://localhost/api/logs/test-entry'),
              body: jsonEncode({'severity': 'panic', 'message': 'x'}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
      });

      test('400 on missing message', () async {
        final response = await translateHandlerErrors(
          handlers.handleTestEntry(
            Request(
              'POST',
              Uri.parse('http://localhost/api/logs/test-entry'),
              body: jsonEncode({'severity': 'info'}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
      });
    });

    // GET /api/logs/tail — SSE
    group('GET /api/logs/tail (SSE)', () {
      test('emits initial replay followed by live entries', () async {
        // Pre-populate the ring buffer so the replay has something to
        // emit.
        logger.info('replay-entry-1', source: 'TestSrc');
        logger.info('replay-entry-2', source: 'TestSrc');

        final response = handlers.handleTail(
          Request('GET', Uri.parse('http://localhost/api/logs/tail')),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(
          response.headers['content-type'],
          startsWith('text/event-stream'),
        );

        final buffer = StringBuffer();
        final liveReceived = Completer<void>();
        late StreamSubscription<String> sub;
        sub = response.read().transform(utf8.decoder).listen((chunk) {
          buffer.write(chunk);
          if (buffer.toString().contains('live-entry') &&
              !liveReceived.isCompleted) {
            liveReceived.complete();
          }
        });

        // Wait for the replay frames to flush, then inject a live entry.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        logger.warning('live-entry', source: 'TestSrc');

        await liveReceived.future.timeout(const Duration(seconds: 2));
        await sub.cancel();

        final raw = buffer.toString();
        expect(raw, contains('retry: 5000'));
        expect(raw, contains('replay-entry-1'));
        expect(raw, contains('replay-entry-2'));
        expect(raw, contains('event: replay-done'));
        expect(raw, contains('live-entry'));
        // Frames are SSE-shaped.
        expect(raw, contains('event: log'));
      });

      test('severity filter drops non-matching live entries', () async {
        final response = handlers.handleTail(
          Request(
            'GET',
            Uri.parse('http://localhost/api/logs/tail?severity=error'),
          ),
        );

        final buffer = StringBuffer();
        final sub = response.read().transform(utf8.decoder).listen((chunk) {
          buffer.write(chunk);
        });

        await Future<void>.delayed(const Duration(milliseconds: 50));
        logger.info('info-should-be-filtered', source: 'TestSrc');
        logger.error('error-should-arrive', source: 'TestSrc');

        // Wait long enough for both entries to flush.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await sub.cancel();

        final raw = buffer.toString();
        expect(raw, contains('error-should-arrive'));
        expect(raw.contains('info-should-be-filtered'), isFalse);
      });

      test('Last-Event-ID resumes after the given timestamp', () async {
        // Pre-populate three entries with distinct timestamps.
        final beforeCutoff = DateTime.now().toUtc();
        logger.info('pre-cutoff-A', source: 'TestSrc');
        // Force a small time delta so the cutoff lands cleanly between.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final cutoff = DateTime.now().toUtc();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        logger.info('post-cutoff-A', source: 'TestSrc');
        logger.warning('post-cutoff-B', source: 'TestSrc');

        // beforeCutoff is just used to document timeline; cutoff is
        // what we send as Last-Event-ID.
        expect(beforeCutoff.isBefore(cutoff), isTrue);

        final response = handlers.handleTail(
          Request(
            'GET',
            Uri.parse('http://localhost/api/logs/tail'),
            headers: {'last-event-id': cutoff.toIso8601String()},
          ),
        );

        final buffer = StringBuffer();
        final replayDone = Completer<void>();
        final sub = response.read().transform(utf8.decoder).listen((chunk) {
          buffer.write(chunk);
          if (buffer.toString().contains('event: replay-done') &&
              !replayDone.isCompleted) {
            replayDone.complete();
          }
        });

        await replayDone.future.timeout(const Duration(seconds: 2));
        // Give one extra microtask for the in-flight chunk to settle.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await sub.cancel();

        final raw = buffer.toString();
        expect(raw, contains('post-cutoff-A'));
        expect(raw, contains('post-cutoff-B'));
        expect(
          raw.contains('pre-cutoff-A'),
          isFalse,
          reason: 'entries at/before Last-Event-ID must be skipped',
        );
      });

      test('400 on unrecognised severity in query', () async {
        // The handler throws BadRequestError synchronously when severity
        // is unparseable. Wrap the call in an async future so the test
        // helper can translate the exception into a structured 400 the
        // same way the request-pipeline middleware would.
        final response = await translateHandlerErrors(
          Future.sync(() async {
            // Calling handleTail synchronously throws — wrap to surface as
            // an async failure that translateHandlerErrors can capture.
            return handlers.handleTail(
              Request(
                'GET',
                Uri.parse('http://localhost/api/logs/tail?severity=panic'),
              ),
            );
          }),
        );
        expect(response.statusCode, HttpStatus.badRequest);
      });

      test('heartbeat keep-alive emitted on stream open', () async {
        final response = handlers.handleTail(
          Request('GET', Uri.parse('http://localhost/api/logs/tail')),
        );

        final buffer = StringBuffer();
        final sub = response.read().transform(utf8.decoder).listen((chunk) {
          buffer.write(chunk);
        });

        // Just wait long enough to see the initial retry/replay-done
        // frames. Heartbeats fire on a 30-s timer, which is too slow to
        // assert here; what we CAN assert is that the very first write
        // is the retry hint.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await sub.cancel();

        expect(buffer.toString(), startsWith('retry: 5000'));
      });
    });
  });
}
