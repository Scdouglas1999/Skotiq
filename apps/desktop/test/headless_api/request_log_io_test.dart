import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  test(
    'a request is handled and answered while its log lines are still being written',
    () async {
      final root = await Directory.systemTemp.createTemp('sk-request-http-');
      final startEntered = Completer<void>();
      final completionEntered = Completer<void>();
      final allowStart = Completer<void>();
      final allowCompletion = Completer<void>();
      final logger = LoggingService(
        environment: {skotiqDataDirEnv: root.path},
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => null,
        appendRequestLine: (file, line) async {
          if (line.contains('"phase":"started"')) {
            startEntered.complete();
            await allowStart.future;
          } else if (line.contains('"phase":"completed"')) {
            completionEntered.complete();
            await allowCompletion.future;
          }
          await file.writeAsString(line, mode: FileMode.writeOnlyAppend);
        },
      );
      await logger.initialize();
      final container = createHeadlessTestContainer(
        overrides: [
          loggingServiceProvider.overrideWithValue(logger),
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '9.0.0', buildNumber: 37),
          ),
        ],
      );
      final server = HeadlessApiServer(
        port: 0,
        container: container,
        bindLocalOnly: true,
        authToken: 'admin-token',
      );
      final client = HttpClient();
      addTearDown(() async {
        if (!allowStart.isCompleted) allowStart.complete();
        if (!allowCompletion.isCompleted) allowCompletion.complete();
        client.close(force: true);
        await server.stop();
        container.dispose();
        await logger.dispose();
        await root.delete(recursive: true);
      });
      await server.start();
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.actualPort}/api/logs/test-entry'),
      );
      request.headers.set('x-skotiq-version', '9.0.0');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer admin-token',
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({'message': 'handler reached', 'severity': 'info'}),
      );
      // The handler runs and answers while the request log is still held.
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      await startEntered.future.timeout(const Duration(seconds: 5));
      expect(
        logger.getRecentLogs().where((e) => e.message == 'handler reached'),
        hasLength(1),
      );
      expect(
        completionEntered.isCompleted,
        isFalse,
        reason: 'request lines are written in order, one at a time',
      );
      allowStart.complete();
      await completionEntered.future.timeout(const Duration(seconds: 5));
      allowCompletion.complete();
      final file = File(logger.currentRequestLogFile!);
      var lines = <String>[];
      for (var i = 0; i < 100 && lines.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        lines = await file.readAsLines();
      }
      expect(lines, hasLength(2));
      expect(lines.first, contains('"phase":"started"'));
      expect(lines.last, contains('"phase":"completed"'));

      final name = logger.currentRequestLogFile!
          .split(Platform.pathSeparator)
          .last;
      final download = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:${server.actualPort}/api/logs/files/$name/download',
        ),
      );
      download.headers.set('x-skotiq-version', '9.0.0');
      download.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer admin-token',
      );
      final downloaded = await download.close();
      expect(downloaded.statusCode, HttpStatus.ok);
      expect(
        await downloaded.transform(utf8.decoder).join(),
        contains('"phase":"completed"'),
      );
    },
  );
}
