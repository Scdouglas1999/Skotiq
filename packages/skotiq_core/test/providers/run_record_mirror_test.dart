// SY-01 / SY-03 (sync night 2026-11-03): a client that joins after a run, or
// restarts during one, must show the host's finished run and the host's
// session frame list, not only what it saw arrive since it started.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

ProviderContainer _host() {
  final backend = _MockFfiBackend();
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  container.read(hostMutationEventHubProvider).wsBroadcast = (_) {};
  container.read(hostRuntimeMirrorProvider);
  return container;
}

_MockNetworkBackend _clientBackend(ProviderContainer host) {
  final backend = _MockNetworkBackend();
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);
  when(() => backend.isAuthTokenRejected).thenReturn(false);
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  // What `GET /api/runtime/state` serves: the host store's latest values.
  when(() => backend.getHostRuntimeState()).thenAnswer(
    (_) async => host.read(hostRuntimeStateStoreProvider).snapshot(),
  );
  return backend;
}

db.CapturedImage _row(
  int id, {
  required int sessionId,
  String type = 'light',
}) => db.CapturedImage(
  id: id,
  filePath: 'C:/data/frame_$id.fits',
  fileName: 'frame_$id.fits',
  fileFormat: 'fits',
  binX: 1,
  binY: 1,
  sessionId: sessionId,
  frameType: type,
  exposureDuration: 60,
  capturedAt: DateTime(2026, 11, 3, 18, 20).add(Duration(minutes: id)),
  isAccepted: true,
  isPlateSolved: false,
  createdAt: DateTime(2026, 11, 3, 18, 20),
);

ProviderContainer _client(
  _MockNetworkBackend backend, {
  List<db.CapturedImage> hostRows = const [],
}) => ProviderContainer(
  overrides: [
    backendProvider.overrideWith((ref) => _FixedBackendNotifier(ref, backend)),
    allDbImagesProvider.overrideWith((ref) => Stream.value(hostRows)),
    allSessionsProvider.overrideWith(
      (ref) => Stream.value(const <db.ImagingSession>[]),
    ),
  ],
);

/// The host after the NGC 7331 run (session 113, 8 frames) and the cancelled
/// end-of-night calibration that followed it (session 114).
void _finishNight(ProviderContainer host) {
  final stats = SequenceRunStats();
  for (var i = 0; i < 8; i++) {
    stats.recordFrame(
      target: 'NGC 7331',
      filter: 'L',
      exposureSecs: 60,
      accepted: i != 2,
    );
  }
  stats.autofocusRuns = 1;
  stats.ditherCount = 3;
  stats.endTime = stats.startTime.add(const Duration(minutes: 15));
  const imaging = SequenceTerminalRunResult(
    generation: 4,
    outcome: SequenceExecutionState.completed,
    runStatus: 'completed',
    runId: 41,
    dbSessionId: 113,
  );
  host.read(completedImagingRunProvider.notifier).state = CompletedImagingRun(
    imaging,
    stats,
  );
  host
      .read(sequenceTerminalRunResultProvider.notifier)
      .state = const SequenceTerminalRunResult(
    generation: 5,
    outcome: SequenceExecutionState.idle,
    runStatus: 'stopped',
    runId: 42,
    dbSessionId: 114,
    isCalibration: true,
  );
  host
      .read(lastEndedRunProvider.notifier)
      .mirrorHost(
        LastEndedRun(
          sequenceId: 'plan-ngc7331',
          endedAt: DateTime(2026, 11, 3, 18, 36),
        ),
      );
  host.read(runStartedAtProvider.notifier).state = DateTime(
    2026,
    11,
    3,
    18,
    33,
  );
}

/// Let the host's publisher see the change (derived providers notify on the
/// next frame; throttled channels after their interval).
Future<void> _published([Duration wait = Duration.zero]) =>
    Future<void>.delayed(wait);

void main() {
  test(
    'a client that connects after the run gets the host run record',
    () async {
      final host = _host();
      addTearDown(host.dispose);
      _finishNight(host);
      await _published();

      final backend = _clientBackend(host);
      final client = _client(backend);
      addTearDown(client.dispose);
      // Built before the record arrives, as the shell keeps it alive.
      client.read(lastEndedRunProvider);

      await hydrateHostRuntimeState(client, backend);

      final terminal = client.read(shownTerminalRunResultProvider)!;
      expect(terminal.isCalibration, isTrue);
      expect(terminal.dbSessionId, 114);
      final imaging = client.read(completedImagingRunProvider)!;
      expect(imaging.result.dbSessionId, 113);
      expect(imaging.stats!.framesCaptured, 8);
      expect(imaging.stats!.framesRejected, 1);
      expect(imaging.stats!.autofocusRuns, 1);
      expect(imaging.stats!.ditherCount, 3);
      expect(client.read(lastEndedRunProvider)!.sequenceId, 'plan-ngc7331');
      expect(client.read(runStartedAtProvider), DateTime(2026, 11, 3, 18, 33));
      // The client's own terminal result stays empty: a change there opens the
      // Session Report and starts end-of-night work.
      expect(client.read(sequenceTerminalRunResultProvider), isNull);
    },
  );

  test('a client that joins a live run keeps the host start time', () async {
    final host = _host();
    addTearDown(host.dispose);
    host.read(runStartedAtProvider.notifier).state = DateTime(
      2026,
      11,
      3,
      20,
      20,
    );
    await _published();

    final backend = _clientBackend(host);
    final client = _client(backend);
    addTearDown(client.dispose);
    client.read(lastEndedRunProvider);

    await hydrateHostRuntimeState(client, backend);
    // The run's state reaches the client after the record (a status poll or
    // event): this client sees it go live now, the host saw it at 20:20.
    client.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.paused;

    expect(client.read(runStartedAtProvider), DateTime(2026, 11, 3, 20, 20));
  });

  test('the client lists the host session frames in the host order', () async {
    final host = _host();
    addTearDown(host.dispose);
    final frames = host.read(sessionImagesProvider.notifier);
    for (final id in [501, 502, 503]) {
      frames.addImage(capturedImageFromDbRow(_row(id, sessionId: 113)));
    }
    // A frame that never got a row carries a clock-time id.
    frames.addImage(
      CapturedImage(
        id: '1762212000000',
        filePath: 'C:/data/unsaved.fits',
        capturedAt: DateTime(2026, 11, 3, 19),
        settings: const ExposureSettings(
          exposureTime: 60,
          gain: 139,
          offset: 21,
        ),
      ),
    );
    // The frame list publishes at most once a second.
    await _published(const Duration(milliseconds: 1100));

    final backend = _clientBackend(host);
    final client = _client(
      backend,
      hostRows: [
        _row(503, sessionId: 113),
        _row(501, sessionId: 113),
        _row(502, sessionId: 113),
        _row(504, sessionId: 114, type: 'dark'),
      ],
    );
    addTearDown(client.dispose);
    final sub = client.listen(recentSessionFramesProvider, (_, __) {});
    addTearDown(sub.close);

    expect(client.read(recentSessionFramesProvider), isEmpty);
    await hydrateHostRuntimeState(client, backend);
    await client.read(allDbImagesProvider.future);

    expect(client.read(recentSessionFramesProvider).map((f) => f.id), [
      '501',
      '502',
      '503',
    ]);
  });
}
