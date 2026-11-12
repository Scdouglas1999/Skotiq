// A command that changes host state (POST, DELETE) must never be sent again
// after it may have reached the host: a retried disconnect or slew can land
// long after the user issued it, on a rig that has moved on. Only a request
// that provably never left (connection refused) is retried, and only briefly.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

NetworkBackend _backend(http.Client client) => NetworkBackend(
  serverHost: '127.0.0.1',
  serverPort: 9999,
  webSocketPort: 9999,
  httpClient: client,
  autoConnectWebSocket: false,
);

void main() {
  test('a POST answered with 503 is not sent again', () async {
    var posts = 0;
    final backend = _backend(
      MockClient((request) async {
        if (request.url.path == '/api/phd2/disconnect') posts++;
        return http.Response('{"error":"busy"}', 503);
      }),
    );
    addTearDown(backend.dispose);

    await expectLater(backend.phd2Disconnect(), throwsA(anything));
    expect(posts, 1);
  });

  test('a POST that times out is not sent again', () {
    fakeAsync((async) {
      var posts = 0;
      final backend = _backend(
        MockClient((request) {
          if (request.url.path == '/api/phd2/disconnect') posts++;
          return Completer<http.Response>().future;
        }),
      );
      Object? failure;
      backend.phd2Disconnect().catchError((Object e) => failure = e);
      async.elapse(const Duration(minutes: 5));

      expect(failure, isA<TimeoutException>());
      expect(posts, 1);
      backend.dispose();
    });
  });

  test('a refused POST is retried, but only within a few seconds', () {
    fakeAsync((async) {
      var posts = 0;
      final backend = _backend(
        MockClient((request) async {
          if (request.url.path == '/api/mount/slew') posts++;
          throw const SocketException(
            'Connection refused',
            osError: OSError('Connection refused', 111),
          );
        }),
      );
      Object? failure;
      backend
          .mountSlewToCoordinates('sim_mount_1', 1.0, 2.0)
          .catchError((Object e) => failure = e);
      async.elapse(const Duration(minutes: 1));

      expect(failure, isNotNull);
      expect(posts, inInclusiveRange(2, 3));
      backend.dispose();
    });
  });

  test('a GET answered with 503 is still retried', () async {
    var gets = 0;
    final backend = _backend(
      MockClient((request) async {
        if (request.url.path == '/api/guider/status') gets++;
        return http.Response('{"error":"busy"}', 503);
      }),
    );
    addTearDown(backend.dispose);

    await expectLater(backend.guiderGetStatus(), throwsA(anything));
    expect(gets, 3);
  });
}
