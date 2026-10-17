import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

Map<String, Object?> _run() => {
  'id': 4,
  'sequenceId': 9,
  'sequenceName': 'Orion',
  'startedAt': '2026-07-14T01:02:03.000Z',
  'endedAt': '2026-07-14T02:02:03.000Z',
  'status': 'completed',
  'statsJson': '{}',
  'frameCount': 12,
};

Map<String, Object?> _context({
  Object? runId = 4,
  Object? sequenceId = 9,
  Object? current = '{"version":2}',
  Object? previous = '{"version":1}',
}) => {
  'runId': runId,
  'sequenceId': sequenceId,
  'currentSnapshotJson': current,
  'previousSnapshotJson': previous,
};

void main() {
  test(
    'fetches opt-in run diff context and repository preserves both sides',
    () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sequence-runs/4',
          body: jsonEncode({'run': _run(), 'diffContext': _context()}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final repository = SequenceRepository.remote(
        backend,
        SequenceFileService(),
      );
      final context = await repository.loadRunDiffContext(4);

      expect(context.sequenceId, 9);
      expect(context.currentSnapshotJson, '{"version":2}');
      expect(context.previousSnapshotJson, '{"version":1}');
      expect(
        fake.requests.single.url.queryParameters['includeDiffContext'],
        'true',
      );
    },
  );

  test(
    'loadPreviousRunSnapshot works remotely and validates sequence identity',
    () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sequence-runs/4',
          body: jsonEncode({'run': _run(), 'diffContext': _context()}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      final repository = SequenceRepository.remote(
        backend,
        SequenceFileService(),
      );

      expect(
        await repository.loadPreviousRunSnapshot(9, beforeRunId: 4),
        '{"version":1}',
      );
      await expectLater(
        repository.loadPreviousRunSnapshot(8, beforeRunId: 4),
        throwsStateError,
      );
    },
  );

  test('rejects a diff context for a different run', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/sequence-runs/4',
        body: jsonEncode({'run': _run(), 'diffContext': _context(runId: 5)}),
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    await expectLater(
      backend.fetchSequenceRunDiffContext(4),
      throwsFormatException,
    );
  });

  test(
    'rejects empty snapshot strings instead of treating them as documents',
    () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sequence-runs/4',
          body: jsonEncode({
            'run': _run(),
            'diffContext': _context(current: '   '),
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(
        backend.fetchSequenceRunDiffContext(4),
        throwsFormatException,
      );
    },
  );
}
