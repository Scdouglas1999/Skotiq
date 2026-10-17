// Wave 2 / Pillar B — remote-slave First Light triage refresh.
//
// On the night tablet (NetworkBackend / slave), the First Light feed is a
// debounced REST snapshot of /api/firstlight/candidates that otherwise only
// re-fetches on an unrelated backend event. firstLightTriageProvider's remote
// branch must therefore await the host Confirm/Dismiss POST and THEN invalidate
// firstLightCandidatesProvider, forcing an immediate re-fetch so the card's
// reviewed/dismissed badge updates within one round-trip (no stale badge).
//
// These tests pin:
//   * a successful remote review re-fetches the candidates feed (badge updates),
//   * a successful remote dismiss does the same,
//   * a FAILED triage does NOT re-fetch (await-then-invalidate keeps state).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart'
    show TransientDetectionRow;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/transient_detections_provider.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

Map<String, dynamic> _candidate({required int id, required bool reviewed}) => {
  'id': id,
  'sessionId': null,
  'capturedImageId': 34,
  'tileId': 42,
  'detectedAt': DateTime.utc(2026, 6, 22, 22, 30).millisecondsSinceEpoch,
  'raDeg': 120.5,
  'decDeg': -25.25,
  'residualFlux': 1500.0,
  'deltaMag': null,
  'snr': 18.3,
  'fwhm': 2.1,
  'eccentricity': 0.12,
  'positionAngleDeg': 63.5,
  'kind': 'newSource',
  'catalogMatch': null,
  'confidence': 0.81,
  'reviewed': reviewed,
  'dismissed': false,
};

void main() {
  /// Wire a mock NetworkBackend whose /api/firstlight/candidates snapshot
  /// flips a flag once the host has applied a triage, and which records each
  /// fetch so a test can prove a re-fetch happened.
  ({
    _MockNetworkBackend backend,
    StreamController<SkotiqEvent> events,
    List<String> calls,
  })
  buildBackend({bool reviewFails = false}) {
    final controller = StreamController<SkotiqEvent>.broadcast();
    final backend = _MockNetworkBackend();
    final calls = <String>[];
    var hostReviewed = false;

    when(() => backend.eventStream).thenAnswer((_) => controller.stream);
    when(() => backend.getFirstLightCandidates()).thenAnswer((_) async {
      calls.add('fetch');
      return [_candidate(id: 7, reviewed: hostReviewed)];
    });
    when(() => backend.reviewFirstLightCandidate(any())).thenAnswer((_) async {
      calls.add('review');
      if (reviewFails) throw Exception('host rejected review');
      hostReviewed = true;
    });
    when(() => backend.dismissFirstLightCandidate(any())).thenAnswer((_) async {
      calls.add('dismiss');
    });
    return (backend: backend, events: controller, calls: calls);
  }

  ProviderContainer containerFor(_MockNetworkBackend backend) {
    return ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
  }

  /// Keep an active listener on the feed (as the discovery surface widget does),
  /// so an invalidate triggers an immediate rebuild + REST re-fetch, and resolve
  /// once a snapshot has loaded.
  Future<List<TransientDetectionRow>> readFeed(
    ProviderContainer container,
  ) async {
    container.listen(firstLightCandidatesProvider, (_, _) {});
    return container.read(firstLightCandidatesProvider.future);
  }

  test('remote Confirm re-fetches the feed so the badge updates', () async {
    final h = buildBackend();
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    // Initial snapshot: candidate not yet reviewed.
    final before = await readFeed(container);
    expect(before.single.reviewed, isFalse);
    expect(h.calls, ['fetch']);

    await container.read(firstLightTriageProvider).review(7);
    // Let the invalidated stream rebuild + its immediate refetch settle.
    await container.read(firstLightCandidatesProvider.future);

    // The await-then-invalidate path forced an immediate re-fetch...
    expect(h.calls, ['fetch', 'review', 'fetch']);
    // ...and the badge now reflects the host's just-applied flag.
    final after = container.read(firstLightCandidatesProvider).requireValue;
    expect(after.single.reviewed, isTrue);
  });

  test('remote Dismiss re-fetches the feed', () async {
    final h = buildBackend();
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await readFeed(container);
    expect(h.calls, ['fetch']);

    await container.read(firstLightTriageProvider).dismiss(7);
    await container.read(firstLightCandidatesProvider.future);

    expect(h.calls, ['fetch', 'dismiss', 'fetch']);
  });

  test('a FAILED remote triage does NOT re-fetch (state preserved)', () async {
    final h = buildBackend(reviewFails: true);
    addTearDown(h.events.close);
    final container = containerFor(h.backend);
    addTearDown(container.dispose);

    await readFeed(container);
    expect(h.calls, ['fetch']);

    await expectLater(
      container.read(firstLightTriageProvider).review(7),
      throwsA(isA<Exception>()),
    );

    // Await-before-invalidate: a failed POST must not trigger a re-fetch that
    // could wipe the current good snapshot.
    expect(h.calls, ['fetch', 'review']);
  });
}
