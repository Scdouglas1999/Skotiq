// A request's log lines are written beside its handler. A log disk that never
// answers must not hold up any command, Stop above all.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import '../headless_api/handler_test_helpers.dart';

/// The real network stack: the test binding answers every request with 400.
class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = _RealHttp());

  late Directory root;
  late LoggingService logger;
  late HeadlessApiServer server;
  late ProviderContainer container;
  late Completer<void> disk;
  late int writesAttempted;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sk-hung-log-disk-');
    disk = Completer<void>();
    writesAttempted = 0;
    logger = LoggingService(
      environment: {skotiqDataDirEnv: root.path},
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
      appendRequestLine: (file, line) {
        writesAttempted++;
        return disk.future;
      },
    );
    await logger.initialize();
    container = createHeadlessTestContainer(
      overrides: [loggingServiceProvider.overrideWithValue(logger)],
    );
    server = HeadlessApiServer(
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: 'admin-token',
      corsAllowedOrigins: const ['http://dash.example'],
    );
    await server.start();
  });

  tearDown(() async {
    disk.complete();
    await server.stop();
    container.dispose();
    // The log file is open until the service closes it, and Windows will not
    // delete a folder holding an open file.
    await logger.dispose();
    await root.delete(recursive: true);
  });

  Uri at(String path) =>
      Uri.parse('http://127.0.0.1:${server.actualPort}$path');

  test('Stop is answered while the request log disk hangs', () async {
    final response = await http
        .post(
          at('/api/sequencer/stop'),
          headers: {'Authorization': 'Bearer admin-token'},
        )
        .timeout(const Duration(seconds: 5));

    expect(response.statusCode, isNot(HttpStatus.requestTimeout));
    expect(writesAttempted, greaterThan(0), reason: 'the line was still sent');
  });

  test('a cross-origin dashboard may send the headers it sends', () async {
    final request = http.Request('OPTIONS', at('/api/sequencer/stop'))
      ..headers.addAll({
        'Origin': 'http://dash.example',
        'Access-Control-Request-Method': 'POST',
      });
    final response = await http.Response.fromStream(await request.send());

    final allowed = response.headers['access-control-allow-headers']!
        .toLowerCase()
        .split(RegExp(r',\s*'));
    expect(allowed, containsAll(['x-skotiq-version', 'x-skotiq-device-id']));
    expect(allowed, isNot(contains('x-skotiq-api-version')));
  });
}
