// Tests for the remote Night Narrator feed transport on [NetworkBackend] and
// the wire-decode that reconstructs a [NarratorEvent] client-side.
//
// The narrator runs on the appliance; a remote client reads its feed over REST
// (`/api/narrator/feed`, `/api/narrator/recent`). All HTTP is served by the
// MockClient-backed FakeNetworkClient — no real server needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/providers/narrator_provider.dart';
import 'package:skotiq_core/src/services/science/narrator/narrator_event.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

void main() {
  group('NetworkBackend narrator feed', () {
    test('getNarratorFeed scopes to sessionId and returns events', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/narrator/feed',
          method: 'GET',
          body: '{"events":[{"id":1,"headline":"First light"}]}',
        );
      final backend = _backend(fake);

      final events = await backend.getNarratorFeed(7);

      expect(events, hasLength(1));
      expect(events.first['headline'], 'First light');
      final req = fake.requestsFor('/api/narrator/feed').single;
      expect(req.url.queryParameters['sessionId'], '7');
    });

    test('getRecentNarratorFeed passes the limit', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/narrator/recent', body: '{"events":[]}');
      final backend = _backend(fake);

      final events = await backend.getRecentNarratorFeed(limit: 25);

      expect(events, isEmpty);
      final req = fake.requestsFor('/api/narrator/recent').single;
      expect(req.url.queryParameters['limit'], '25');
    });

    test('a missing/!list events field fails the wire contract', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/narrator/recent', body: '{}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.getRecentNarratorFeed(), throwsFormatException);
    });
  });

  group('narratorEventFromWireJson', () {
    test('reconstructs a full event from the wire shape', () {
      final event = narratorEventFromWireJson({
        'id': 42,
        'sessionId': 7,
        'capturedImageId': 100,
        'timestamp': 1750000000000,
        'eventType': 'integration_milestone',
        'category': 'milestone',
        'severity': 'success',
        'headline': '2h on NGC 7000',
        'body': 'Accepted 120 frames',
        'evidenceJson': null,
        'dedupeKey': 'milestone:ngc7000:2h',
        'pinned': true,
      });

      expect(event.id, 42);
      expect(event.sessionId, 7);
      expect(event.capturedImageId, 100);
      expect(event.timestamp.millisecondsSinceEpoch, 1750000000000);
      expect(event.eventType, 'integration_milestone');
      expect(event.category, NarratorCategory.milestone);
      expect(event.severity, NarratorSeverity.success);
      expect(event.headline, '2h on NGC 7000');
      expect(event.body, 'Accepted 120 frames');
      expect(event.dedupeKey, 'milestone:ngc7000:2h');
      expect(event.pinned, isTrue);
    });

    test('defaults pinned to false and tolerates null body', () {
      final event = narratorEventFromWireJson({
        'id': 1,
        'timestamp': 0,
        'eventType': 'cloud_in',
        'category': 'conditions',
        'severity': 'warning',
        'headline': 'Clouds rolling in',
        'dedupeKey': 'cloud:1',
      });
      expect(event.pinned, isFalse);
      expect(event.body, isNull);
      expect(event.category, NarratorCategory.conditions);
    });
  });
}
