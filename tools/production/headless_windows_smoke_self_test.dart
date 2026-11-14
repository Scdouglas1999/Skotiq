import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'headless_windows_smoke.dart' as smoke;

Future<void> main() async {
  await _webSocketCase('pong', (socket) {
    socket.listen((_) => socket.add(jsonEncode({'type': 'pong'})));
  });
  await _webSocketCase('closed without pong', (socket) {
    unawaited(socket.close());
  }, fails: true);
  await _webSocketCase(
    'silent peer',
    (socket) {
      socket.listen((_) {});
    },
    fails: true,
    timesOut: true,
  );

  for (final partialBody in [false, true]) {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient();
    final accepted = Completer<void>();
    server.listen((request) async {
      accepted.complete();
      if (partialBody) {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"unfinished":');
        await request.response.flush();
      }
      // Intentionally leave either the headers or the body incomplete.
    });
    final timer = Stopwatch()..start();
    try {
      await _expectFailure(
        smoke.requestSmokeJson(
          client,
          _uri(server),
          '/stalled',
          timeout: const Duration(milliseconds: 150),
        ),
        timeout: true,
      );
      _expect(accepted.isCompleted, 'HTTP fixture was not reached');
      _expect(
        timer.elapsed < const Duration(seconds: 3),
        'HTTP deadline did not bound a stalled response',
      );
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  }

  final good = _fits();
  smoke.validateSmokeFits(good);
  for (final bad in [
    _fits(width: 64),
    _fits(object: 'Unrelated capture'),
    _fits(exposure: '10'),
    good.sublist(0, 3000),
  ]) {
    await _expectFailure(Future.sync(() => smoke.validateSmokeFits(bad)));
  }
  stdout.writeln(
    'Windows smoke protocol self-tests passed: '
    'pong, premature close, silent peer, stalled headers/body, '
    'FITS dimensions/metadata/payload. No native Windows runtime was tested.',
  );
}

Future<void> _webSocketCase(
  String label,
  void Function(WebSocket) serve, {
  bool fails = false,
  bool timesOut = false,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  WebSocket? socket;
  server.listen((request) async {
    socket = await WebSocketTransformer.upgrade(request);
    serve(socket!);
  });
  final timer = Stopwatch()..start();
  try {
    final result = smoke.expectSmokeWebSocketPong(
      _uri(server),
      'test-token',
      timeout: const Duration(milliseconds: 150),
    );
    if (fails) {
      await _expectFailure(result, timeout: timesOut);
    } else {
      await result;
    }
    _expect(socket != null, '$label fixture was not reached');
    _expect(
      timer.elapsed < const Duration(seconds: 3),
      '$label exceeded its bounded wait',
    );
  } finally {
    await socket?.close().timeout(const Duration(seconds: 1));
    await server.close(force: true);
  }
}

Uri _uri(HttpServer server) => Uri.parse('http://127.0.0.1:${server.port}');

Future<void> _expectFailure(
  Future<Object?> action, {
  bool timeout = false,
}) async {
  Object? failure;
  try {
    await action;
  } catch (error) {
    failure = error;
  }
  _expect(failure != null, 'Expected failure, but the smoke check passed');
  if (timeout) {
    _expect(failure is TimeoutException, 'Expected timeout: $failure');
  }
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

List<int> _fits({
  int width = 128,
  String object = 'Windows smoke simulator',
  String exposure = '0.01',
}) {
  final cards = {
    'SIMPLE': 'T',
    'BITPIX': '16',
    'NAXIS': '2',
    'NAXIS1': '$width',
    'NAXIS2': '96',
    'OBJECT': "'$object'",
    'EXPTIME': exposure,
    'DATE-OBS': "'2026-11-14T12:00:00.000Z'",
  };
  final header = StringBuffer();
  for (final card in cards.entries) {
    header.write('${card.key.padRight(8)}= ${card.value}'.padRight(80));
  }
  header.write('END'.padRight(80));
  return [
    ...ascii.encode(header.toString().padRight(2880)),
    ...List<int>.filled(128 * 96 * 2, 0),
  ];
}
