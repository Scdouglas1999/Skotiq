import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/services/framing_survey_fetcher.dart';

void main() {
  final primary = Uri.parse('https://primary.test/image');
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
      fallback: fallback,
    );
    expect(response.bodyBytes, [1, 2, 3]);
    expect(calls, [primary]);
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
