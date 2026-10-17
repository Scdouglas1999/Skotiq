import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the checkpoint request');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  test('concurrent starts share one durable session creation', () async {
    final createGate = Completer<void>();
    var createCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/sessions') {
        createCalls++;
        await createGate.future;
        return http.Response('{"id":1}', 200);
      }
      fail('Unexpected request: ${request.method} ${request.url.path}');
    });
    final backend = NetworkBackend(
      serverHost: 'example.invalid',
      httpClient: client,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);
    final service = SessionService(
      records: ImagingRecordsRepository.remote(backend),
      logger: LoggingService(),
    );
    addTearDown(service.dispose);

    final first = service.startSession(name: 'Double tap');
    final second = service.startSession(name: 'Double tap');
    await _waitUntil(() => createCalls == 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(createCalls, 1);
    createGate.complete();
    expect(await Future.wait([first, second]), [1, 1]);
    expect(service.currentSessionId, 1);
  });

  test(
    'end requested during a slow start finalizes the created session',
    () async {
      final createGate = Completer<void>();
      var createCalls = 0;
      var endCalls = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/api/sessions') {
          createCalls++;
          await createGate.future;
          return http.Response('{"id":1}', 200);
        }
        if (request.method == 'PUT' && request.url.path == '/api/sessions/1') {
          return http.Response('{"status":"updated"}', 200);
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/sessions/1/end') {
          endCalls++;
          return http.Response('{"status":"ended"}', 200);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      });
      final backend = NetworkBackend(
        serverHost: 'example.invalid',
        httpClient: client,
        autoConnectWebSocket: false,
      );
      addTearDown(backend.dispose);
      final service = SessionService(
        records: ImagingRecordsRepository.remote(backend),
        logger: LoggingService(),
      );
      addTearDown(service.dispose);

      final start = service.startSession(name: 'Start-stop race');
      await _waitUntil(() => createCalls == 1);
      final end = service.endSession();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(endCalls, 0);

      createGate.complete();
      expect(await start, 1);
      await end;

      expect(endCalls, 1);
      expect(service.hasActiveSession, isFalse);
    },
  );

  test('concurrent ends share one durable finalization', () async {
    final endGate = Completer<void>();
    var endCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/sessions') {
        return http.Response('{"id":1}', 200);
      }
      if (request.method == 'PUT' && request.url.path == '/api/sessions/1') {
        return http.Response('{"status":"updated"}', 200);
      }
      if (request.method == 'POST' &&
          request.url.path == '/api/sessions/1/end') {
        endCalls++;
        await endGate.future;
        return http.Response('{"status":"ended"}', 200);
      }
      fail('Unexpected request: ${request.method} ${request.url.path}');
    });
    final backend = NetworkBackend(
      serverHost: 'example.invalid',
      httpClient: client,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);
    final service = SessionService(
      records: ImagingRecordsRepository.remote(backend),
      logger: LoggingService(),
    );
    addTearDown(service.dispose);

    await service.startSession(name: 'Double stop');
    final first = service.endSession();
    await _waitUntil(() => endCalls == 1);
    final second = service.endSession();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(endCalls, 1);
    endGate.complete();
    await Future.wait([first, second]);
    expect(service.hasActiveSession, isFalse);
  });

  test(
    'slow checkpoint writes are serialized with one fresh follow-up',
    () async {
      final firstPut = Completer<void>();
      var putCalls = 0;
      var inFlight = 0;
      var maxInFlight = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/api/sessions') {
          return http.Response('{"id":1}', 200);
        }
        if (request.method == 'PUT' && request.url.path == '/api/sessions/1') {
          putCalls++;
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          if (putCalls == 1) await firstPut.future;
          inFlight--;
          return http.Response('{"status":"updated"}', 200);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      });
      final backend = NetworkBackend(
        serverHost: 'example.invalid',
        httpClient: client,
        autoConnectWebSocket: false,
      );
      addTearDown(backend.dispose);
      final service = SessionService(
        records: ImagingRecordsRepository.remote(backend),
        logger: LoggingService(),
      );
      addTearDown(service.dispose);

      await service.startSession(name: 'Concurrency');
      await service.updateSessionProgress(
        SessionStats(completedExposures: 1, lastUpdated: DateTime.now()),
      );

      final first = service.checkpoint();
      await _waitUntil(() => putCalls == 1);
      final second = service.checkpoint();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(putCalls, 1);
      expect(maxInFlight, 1);

      firstPut.complete();
      await Future.wait([first, second]);

      expect(putCalls, 2);
      expect(maxInFlight, 1);
    },
  );

  test('endSession waits for a fresh serialized checkpoint', () async {
    final firstPut = Completer<void>();
    var putCalls = 0;
    var inFlight = 0;
    var maxInFlight = 0;
    var endCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/sessions') {
        return http.Response('{"id":1}', 200);
      }
      if (request.method == 'PUT' && request.url.path == '/api/sessions/1') {
        putCalls++;
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        if (putCalls == 1) await firstPut.future;
        inFlight--;
        return http.Response('{"status":"updated"}', 200);
      }
      if (request.method == 'POST' &&
          request.url.path == '/api/sessions/1/end') {
        endCalls++;
        return http.Response('{"status":"ended"}', 200);
      }
      fail('Unexpected request: ${request.method} ${request.url.path}');
    });
    final backend = NetworkBackend(
      serverHost: 'example.invalid',
      httpClient: client,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);
    final service = SessionService(
      records: ImagingRecordsRepository.remote(backend),
      logger: LoggingService(),
    );
    addTearDown(service.dispose);

    await service.startSession(name: 'End race');
    await service.updateSessionProgress(
      SessionStats(completedExposures: 2, lastUpdated: DateTime.now()),
    );

    final checkpoint = service.checkpoint();
    await _waitUntil(() => putCalls == 1);
    final end = service.endSession();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(endCalls, 0);
    expect(maxInFlight, 1);

    firstPut.complete();
    await Future.wait([checkpoint, end]);

    expect(endCalls, 1);
    expect(putCalls, 3);
    expect(maxInFlight, 1);
    expect(service.hasActiveSession, isFalse);
  });

  test('late checkpoint completion is silent after dispose', () async {
    final firstPut = Completer<void>();
    var putCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/sessions') {
        return http.Response('{"id":1}', 200);
      }
      if (request.method == 'PUT' && request.url.path == '/api/sessions/1') {
        putCalls++;
        await firstPut.future;
        return http.Response('{"status":"updated"}', 200);
      }
      fail('Unexpected request: ${request.method} ${request.url.path}');
    });
    final backend = NetworkBackend(
      serverHost: 'example.invalid',
      httpClient: client,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);
    final service = SessionService(
      records: ImagingRecordsRepository.remote(backend),
      logger: LoggingService(),
    );
    final statuses = <String>[];
    final subscription = service.statusStream.listen(statuses.add);
    addTearDown(subscription.cancel);

    await service.startSession(name: 'Dispose race');
    final checkpoint = service.checkpoint();
    await _waitUntil(() => putCalls == 1);
    service.dispose();
    firstPut.complete();
    await checkpoint;

    expect(statuses.where((status) => status == 'Checkpoint saved'), isEmpty);
  });
}
