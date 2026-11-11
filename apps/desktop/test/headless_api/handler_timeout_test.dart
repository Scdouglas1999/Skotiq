// A handler that never finishes must not hold its client's connection: the
// server answers 503 within the request's budget and closes the connection,
// while streams and WebSocket upgrades keep their connections open.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:skotiq_desktop/headless_api/handler_timeout.dart';

import '../support/route_policy.dart';

void main() {
  group('HandlerTimeoutPolicy', () {
    const policy = HandlerTimeoutPolicy();

    test('reads, file-building reads and commands get their budgets', () {
      expect(
        policy.budgetFor(
          routeFor('GET', '/api/atlas/region/2/timeline').timeout,
        ),
        const Duration(seconds: 60),
      );
      expect(
        policy.budgetFor(routeFor('GET', '/api/backup/list').timeout),
        const Duration(minutes: 10),
      );
      expect(
        policy.budgetFor(routeFor('GET', '/api/sessions/4/export/csv').timeout),
        const Duration(minutes: 10),
      );
      expect(
        policy.budgetFor(routeFor('POST', '/api/camera/expose').timeout),
        const Duration(minutes: 65),
      );
    });

    test('streams, WebSocket upgrades and long polls have no budget', () {
      for (final path in [
        '/api/ws',
        '/events',
        '/ws/live-view',
        '/api/run-watch/events',
        '/api/logs/tail',
        '/api/broadcast/sse',
        '/api/webrtc/live-view/ice/abc/events',
      ]) {
        expect(
          policy.budgetFor(routeFor('GET', path).timeout),
          isNull,
          reason: path,
        );
      }
    });
  });

  group('handlerTimeoutMiddleware on a live server', () {
    late HttpServer server;
    late Uri base;
    final timedOut = <String>[];

    setUp(() async {
      timedOut.clear();
      final handler = const Pipeline()
          .addMiddleware(unroutedContext)
          .addMiddleware(
            handlerTimeoutMiddleware(
              policy: const HandlerTimeoutPolicy(
                read: Duration(milliseconds: 300),
                command: Duration(milliseconds: 300),
              ),
              onTimeout: (request, _) => timedOut.add('/${request.url.path}'),
            ),
          )
          .addHandler((request) async {
            if (request.url.path == 'api/fast') return Response.ok('fine');
            // Never finishes, like a handler stuck behind a starved worker pool.
            await Completer<void>().future;
            return Response.ok('never');
          });
      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
    });

    tearDown(() => server.close(force: true));

    test('a stuck read is answered 503 and its connection closed', () async {
      final client = HttpClient();
      addTearDown(client.close);
      final watch = Stopwatch()..start();
      final request = await client.getUrl(base.resolve('/api/stuck'));
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      watch.stop();

      expect(response.statusCode, 503);
      expect(response.headers.value('connection'), 'close');
      expect(response.persistentConnection, isFalse);
      expect(jsonDecode(body)['code'], 'handler_timeout');
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(timedOut, ['/api/stuck']);
    });

    test(
      'a stuck command is answered too, and a fast read is untouched',
      () async {
        final client = HttpClient();
        addTearDown(client.close);
        final post = await (await client.postUrl(
          base.resolve('/api/stuck'),
        )).close();
        expect(post.statusCode, 503);
        await post.drain<void>();

        final fast = await (await client.getUrl(
          base.resolve('/api/fast'),
        )).close();
        expect(fast.statusCode, 200);
        expect(await utf8.decodeStream(fast), 'fine');
      },
    );
  });
}
