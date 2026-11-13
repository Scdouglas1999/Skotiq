// SY-01 addendum (sync night 2026-11-03): a client that joined after the
// host's run showed "No guide data yet", "No autofocus run yet this session"
// and "No solve yet this session" beside a host that had all three. The host
// serves what its Tonight gathered; the client adds the part from before it
// connected.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/night_history_sync.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_events_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_app/screens/night_control/panel/solve/recent_solves_provider.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/bridge_events.dart' as sk_events;

import '../../../../harness/harness.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

final DateTime _run = DateTime(2026, 11, 3, 18, 17);

/// What the host's Tonight holds after the NGC 7331 run, over the wire.
Map<String, dynamic> _hostNight() => encodeNightHistory(
      guideSamples: [
        for (var i = 0; i < 4; i++)
          NightGuideSample(
            _run.add(Duration(minutes: 5, seconds: 2 * i)),
            0.3 * i,
            -0.2,
          ),
      ],
      events: NightSessionEvents(
        autofocusRuns: [
          NightAutofocusRun(
            at: _run.add(const Duration(minutes: 4)),
            position: 45362,
            hfr: 1.62,
            duration: const Duration(minutes: 3),
          ),
        ],
        dithers: [
          NightDither(at: _run.add(const Duration(minutes: 6)), pixels: 5),
        ],
      ),
      solves: [
        NightSolveRecord(
          at: _run.add(const Duration(minutes: 1)).toUtc(),
          kind: NightSolveKind.center,
          success: true,
          offsetArcsec: 9.5,
          iterations: 2,
        ),
      ],
      cooler: [
        for (var i = 0; i < 3; i++)
          TemperaturePoint(
            temperature: -9.8 - 0.1 * i,
            targetTemp: -10,
            coolerPower: 42,
            time: _run.add(Duration(minutes: i)),
          ),
      ],
    );

ProviderContainer _client(NetworkBackend backend) {
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith((ref) => TestBackendNotifier(ref, backend)),
      inMemoryDatabaseOverride(),
      skotiqEventsProvider.overrideWith(
        (ref) => const Stream<sk_events.SkotiqEvent>.empty(),
      ),
      nightSessionIdProvider.overrideWithValue(113),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

_MockNetworkBackend _link(Map<String, dynamic>? night) {
  final backend = _MockNetworkBackend();
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);
  when(() => backend.isAuthTokenRejected).thenReturn(false);
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  when(() => backend.getHostNightHistory()).thenAnswer((_) async => night);
  return backend;
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('a client that connects after the run shows the host night', () async {
    final client = _client(_link(_hostNight()));
    // As Tonight builds them, before the host answers.
    client.read(nightGuideSamplesProvider);
    client.read(nightSessionEventsProvider);
    client.read(nightRecentSolvesProvider);
    await _settle();

    final samples = client.read(nightGuideSamplesProvider);
    expect(samples, hasLength(4));
    expect(samples.last.raPx, closeTo(0.9, 1e-9));

    final events = client.read(nightSessionEventsProvider);
    expect(events.autofocusRuns.single.position, 45362);
    expect(events.autofocusRuns.single.hfr, 1.62);
    expect(events.dithers.single.pixels, 5);

    final solves = client.read(nightRecentSolvesProvider);
    expect(solves.single.kind, NightSolveKind.center);
    expect(solves.single.offsetArcsec, 9.5);

    // The Cooler tab's history reaches back to the host's first reading,
    // not to when this client started.
    final cooler = client.read(temperatureLongHistoryProvider);
    expect(cooler, hasLength(3));
    expect(cooler.first.time, _run);
    expect(cooler.last.temperature, closeTo(-10.0, 1e-9));
  });

  test('live steps that arrived first are kept, the host ones go in front',
      () async {
    final backend = _link(_hostNight());
    final client = _client(backend);
    final live = client.read(nightGuideSamplesProvider.notifier);
    // A step that arrived over the live stream before the host answered,
    // and the host also holds.
    live.add(NightGuideSample(
      _run.add(const Duration(minutes: 5, seconds: 6)),
      0.9,
      -0.2,
    ));
    await _settle();

    final samples = client.read(nightGuideSamplesProvider);
    expect(samples, hasLength(4), reason: 'the shared step is not doubled');
    expect(samples.first.t, _run.add(const Duration(minutes: 5)));
  });

  test('a host without the endpoint leaves the charts to live events',
      () async {
    final client = _client(_link(null));
    client.read(nightGuideSamplesProvider);
    await _settle();
    expect(client.read(nightGuideSamplesProvider), isEmpty);
    expect(await client.read(hostNightHistoryProvider.future), isNull);
  });
}
