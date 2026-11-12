// SY-24 (sync night 2026-11-03): a client linked to the host never showed
// why guiding was stopped. The host's /api/sequencer/status carried
// guidingStopReason "tracking_limit_hold" and /api/phd2/status its
// stopReason, but the client set its stop reason only from live StopReason
// events, so a client that joined later read "Guider needs a look, not
// looping" with no reason. The run's warnings were mirrored into the live
// stats already; this pins that too.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

const _warnings = <String>[
  'Mount tracking stopped 33 min before the meridian on the west side of '
      'the pier, read as the mount\'s own tracking limit.',
  'The mount did not flip early.',
];

SequencerStatus _pausedStatus({
  String? guidingStopReason = 'tracking_limit_hold',
  bool reportsGuidingStopReason = true,
}) => SequencerStatus(
  state: 'paused',
  progress: 0.275,
  message: 'Meridian flip failed.',
  guidingStopReason: guidingStopReason,
  reportsGuidingStopReason: reportsGuidingStopReason,
  runVitals: SequencerRunVitals(
    startTime: DateTime(2026, 11, 3, 20, 21),
    framesCaptured: 11,
    framesRejected: 1,
    integrationSecs: 600,
    triggerFires: 2,
    autofocusRuns: 1,
    meridianFlips: 0,
    ditherCount: 3,
    warningMessages: _warnings,
  ),
);

Future<ProviderContainer> _hydrate(
  SequencerStatus status, {
  String? guiderStopReason,
}) async {
  final events = StreamController<SkotiqEvent>.broadcast();
  final backend = _MockNetworkBackend();
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);
  when(() => backend.isAuthTokenRejected).thenReturn(false);
  when(() => backend.eventStream).thenAnswer((_) => events.stream);
  when(() => backend.sequencerGetStatus()).thenAnswer((_) async => status);
  when(() => backend.getHostRuntimeState()).thenAnswer(
    (_) async => [
      HostRuntimeUpdate(
        channel: 'guiderStatus',
        revision: 1,
        value: {
          'deviceId': 'phd2_guider',
          'state': 'stopped',
          'stopReason': guiderStopReason,
        },
      ),
    ],
  );

  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      loggingServiceProvider.overrideWithValue(LoggingService()),
    ],
  );
  addTearDown(() async {
    await events.close();
    container.dispose();
  });
  container.read(remoteSessionSyncProvider);
  await pumpEventQueue();
  return container;
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
  });

  test('the host run status sets why guiding is stopped', () async {
    final container = await _hydrate(_pausedStatus());

    expect(container.read(guidingStopReasonProvider), 'tracking_limit_hold');
  });

  test(
    'the host run status clears the reason once guiding runs again',
    () async {
      final container = await _hydrate(_pausedStatus(guidingStopReason: null));
      container.read(guidingStopReasonProvider.notifier).state = 'autofocus';

      await hydrateRemoteSessionState(
        container,
        container.read(backendProvider) as NetworkBackend,
      );

      expect(container.read(guidingStopReasonProvider), isNull);
    },
  );

  test('a host that does not report the reason leaves it alone', () async {
    final container = await _hydrate(
      _pausedStatus(guidingStopReason: null, reportsGuidingStopReason: false),
    );
    container.read(guidingStopReasonProvider.notifier).state = 'autofocus';

    await hydrateRemoteSessionState(
      container,
      container.read(backendProvider) as NetworkBackend,
    );

    expect(container.read(guidingStopReasonProvider), 'autofocus');
  });

  test("the guider's own status gives the reason too", () async {
    final container = await _hydrate(
      _pausedStatus(guidingStopReason: null, reportsGuidingStopReason: false),
      guiderStopReason: 'meridian_flip',
    );

    expect(container.read(guidingStopReasonProvider), 'meridian_flip');
  });

  test("the host run's warnings reach the client's live run stats", () async {
    final container = await _hydrate(_pausedStatus());

    expect(
      container.read(liveSequenceStatsProvider)?.warningMessages,
      _warnings,
    );
  });

  test('the wire reading of the status keeps the reason and its presence', () {
    final withReason = SequencerStatus.fromJson(<String, dynamic>{
      'state': 'paused',
      'progress': 0.2,
      'guidingStopReason': 'tracking_limit_hold',
    });
    expect(withReason.guidingStopReason, 'tracking_limit_hold');
    expect(withReason.reportsGuidingStopReason, isTrue);

    final guiding = SequencerStatus.fromJson(<String, dynamic>{
      'state': 'running',
      'progress': 0.2,
      'guidingStopReason': null,
    });
    expect(guiding.guidingStopReason, isNull);
    expect(guiding.reportsGuidingStopReason, isTrue);

    final older = SequencerStatus.fromJson(<String, dynamic>{
      'state': 'running',
      'progress': 0.2,
    });
    expect(older.reportsGuidingStopReason, isFalse);
  });
}
