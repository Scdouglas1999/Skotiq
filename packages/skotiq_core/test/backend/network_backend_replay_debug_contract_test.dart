import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

const _decision = '''{
  "id": 5,
  "sequence_run_id": 42,
  "timestamp_unix_ms": 1783987200000,
  "category": "scheduler_pick",
  "summary": "Selected M42 after altitude scoring",
  "details": {"score": 0.91},
  "node_id": "target-m42"
}''';

void main() {
  group('NetworkBackend Replay Debug contract', () {
    test('reads complete host decisions, count, and settings', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sequencer/replay-debug/decisions',
          body: '{"items":[$_decision],"total":1}',
        )
        ..setResponse(
          '/api/sequencer/replay-debug/decisions/count',
          body: '{"count":1}',
        )
        ..setResponse(
          '/api/sequencer/replay-debug/settings',
          body: '{"enabled":false,"retentionDays":30}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final decisions = await backend.replayListDecisions(42);
      expect(decisions.single.id, 5);
      expect(decisions.single.sequenceRunId, 42);
      expect(decisions.single.summary, contains('M42'));
      expect(await backend.replayCountDecisions(42), 1);
      final settings = await backend.replayGetSettings();
      expect(settings.enabled, isFalse);
      expect(settings.retentionDays, 30);
    });

    test('malformed or cross-run decision payloads fail loudly', () async {
      Future<void> expectRejected(String body) async {
        final fake = FakeNetworkClient()
          ..setResponse('/api/sequencer/replay-debug/decisions', body: body);
        final backend = _backend(fake);
        addTearDown(backend.dispose);
        await expectLater(
          backend.replayListDecisions(42),
          throwsFormatException,
        );
      }

      await expectRejected('{"items":[$_decision]}');
      await expectRejected('{"items":[$_decision],"total":2}');
      await expectRejected(
        '{"items":[${_decision.replaceFirst('"sequence_run_id": 42', '"sequence_run_id": 99')}],"total":1}',
      );
      await expectRejected('{"items":[$_decision,$_decision],"total":2}');
      await expectRejected(
        '{"items":[${_decision.replaceFirst('"summary": "Selected M42 after altitude scoring"', '"summary": ""')}],"total":1}',
      );
    });

    test('mutations require a complete host acknowledgement', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sequencer/replay-debug/settings/enabled',
          method: 'POST',
          body: '{"status":"ok","enabled":true}',
        )
        ..setResponse(
          '/api/sequencer/replay-debug/settings/retention',
          method: 'POST',
          body: '{"status":"ok","retentionDays":45}',
        )
        ..setResponse(
          '/api/sequencer/replay-debug/clear',
          method: 'POST',
          body: '{"removed":7}',
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await backend.replaySetEnabled(true);
      await backend.replaySetRetentionDays(45);
      expect(await backend.replayClearHistory(), 7);

      final malformed = FakeNetworkClient()
        ..setResponse(
          '/api/sequencer/replay-debug/settings/enabled',
          method: 'POST',
          body: '{"status":"ok"}',
        )
        ..setResponse(
          '/api/sequencer/replay-debug/clear',
          method: 'POST',
          body: '{"removed":-1}',
        );
      final malformedBackend = _backend(malformed);
      addTearDown(malformedBackend.dispose);

      await expectLater(
        malformedBackend.replaySetEnabled(true),
        throwsFormatException,
      );
      await expectLater(
        malformedBackend.replayClearHistory(),
        throwsFormatException,
      );
    });
  });
}
