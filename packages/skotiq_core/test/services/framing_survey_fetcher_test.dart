import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/services/framing_survey_fetcher.dart';

void main() {
  final primary = Uri.parse('https://primary.test/image');
  final mirror = Uri.parse('https://mirror.test/image');
  final fallback = Uri.parse('https://fallback.test/image');

  test('a fast primary needs no fallback request', () async {
    final calls = <Uri>[];
    final client = MockClient((r) async {
      calls.add(r.url);
      return http.Response.bytes([1, 2, 3], 200);
    });
    addTearDown(client.close);
    final response = await fetchFramingSurvey(
      client: client,
      primary: primary,
      primaryMirror: mirror,
      fallback: fallback,
    );
    expect(response.bodyBytes, [1, 2, 3]);
    expect(calls, [primary]);
  });

  test('a fast mirror wins before NASA is contacted', () {
    fakeAsync((async) {
      final calls = <Uri>[];
      final pending = Completer<http.Response>();
      final client = MockClient((r) async {
        calls.add(r.url);
        if (r.url == primary) return pending.future;
        return http.Response.bytes([7, 8, 9], 200);
      });
      http.Response? result;
      fetchFramingSurvey(
        client: client,
        primary: primary,
        primaryMirror: mirror,
        fallback: fallback,
      ).then((r) => result = r);
      async.flushMicrotasks();
      expect(calls, [primary]);
      async.elapse(const Duration(milliseconds: 600));
      expect(calls, [primary, mirror]);
      expect(result!.bodyBytes, [7, 8, 9]);
      async.elapse(const Duration(seconds: 3));
      expect(calls, [primary, mirror]);
      pending.completeError(http.ClientException('closed'));
      async.flushMicrotasks();
      client.close();
    });
  });

  test('two stalled CDS routes never postpone the two-second fallback', () {
    fakeAsync((async) {
      final calls = <Uri>[];
      final primaryPending = Completer<http.Response>();
      final mirrorPending = Completer<http.Response>();
      final client = MockClient((r) async {
        calls.add(r.url);
        if (r.url == primary) return primaryPending.future;
        if (r.url == mirror) return mirrorPending.future;
        return http.Response.bytes([4, 5, 6], 200);
      });
      http.Response? result;
      var completions = 0;
      fetchFramingSurvey(
        client: client,
        primary: primary,
        primaryMirror: mirror,
        fallback: fallback,
      ).then((r) {
        result = r;
        completions++;
      });
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 599));
      expect(calls, [primary]);
      async.elapse(const Duration(milliseconds: 1));
      expect(calls, [primary, mirror]);
      async.elapse(const Duration(milliseconds: 1399));
      expect(result, isNull);
      expect(calls, [primary, mirror]);
      async.elapse(const Duration(milliseconds: 1));
      expect(calls, [primary, mirror, fallback]);
      expect(result!.bodyBytes, [4, 5, 6]);
      primaryPending.completeError(http.ClientException('closed'));
      mirrorPending.completeError(http.ClientException('closed'));
      async.flushMicrotasks();
      expect(completions, 1);
      client.close();
    });
  });

  test('immediate CDS failures advance without waiting for timers', () {
    fakeAsync((async) {
      final calls = <Uri>[];
      final client = MockClient((r) async {
        calls.add(r.url);
        return r.url == fallback
            ? http.Response.bytes([1], 200)
            : http.Response('Unavailable', 503);
      });
      http.Response? result;
      fetchFramingSurvey(
        client: client,
        primary: primary,
        primaryMirror: mirror,
        fallback: fallback,
      ).then((r) => result = r);
      async.flushMicrotasks();
      expect(calls, [primary, mirror, fallback]);
      expect(result!.bodyBytes, [1]);
      async.elapse(const Duration(seconds: 3));
      expect(calls.length, 3);
      client.close();
    });
  });

  test('all three timeouts finish loading with an error', () {
    fakeAsync((async) {
      final client = MockClient((r) => Completer<http.Response>().future);
      Object? failure;
      fetchFramingSurvey(
        client: client,
        primary: primary,
        primaryMirror: mirror,
        fallback: fallback,
      ).then<void>(
        (_) => fail('No route returned an image'),
        onError: (Object e) {
          failure = e;
        },
      );
      async.elapse(const Duration(seconds: 31));
      expect(failure, isNull);
      async.elapse(const Duration(seconds: 1));
      expect(failure, isA<TimeoutException>());
      client.close();
    });
  });

  test(
    'fallback failure does not discard a slower successful primary',
    () async {
      final pending = Completer<http.Response>();
      final fallbackCalled = Completer<void>();
      final client = MockClient((r) async {
        if (r.url == primary) return pending.future;
        fallbackCalled.complete();
        return http.Response('Unavailable', 503);
      });
      addTearDown(client.close);
      final result = fetchFramingSurvey(
        client: client,
        primary: primary,
        fallback: fallback,
        fallbackDelay: Duration.zero,
      );
      await fallbackCalled.future;
      pending.complete(http.Response.bytes([4, 5, 6], 200));
      expect((await result).bodyBytes, [4, 5, 6]);
    },
  );

  test('both failures surface instead of leaving loading stuck', () async {
    final calls = <Uri>[];
    final client = MockClient((r) async {
      calls.add(r.url);
      return http.Response('Unavailable', 503);
    });
    addTearDown(client.close);
    await expectLater(
      fetchFramingSurvey(client: client, primary: primary, fallback: fallback),
      throwsA(isA<http.ClientException>()),
    );
    expect(calls, [primary, fallback]);
  });
}
