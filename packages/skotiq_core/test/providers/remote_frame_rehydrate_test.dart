// The periodic re-hydrate does not download the host's last frame; first
// connect and a reconnect do, and a frame already on screen is not published
// again.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import 'package:skotiq_core/src/database/database.dart' show DbCapturedImage;
import 'package:skotiq_core/src/services/local_imaging_records.dart'
    show imagingRecordsProvider;
import 'package:skotiq_core/src/backend/roles/host_data/imaging_records.dart';

import '../harness/in_memory_database.dart';
import 'package:skotiq_core/utils.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockImagingRecords extends Mock implements ImagingRecords {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

const _cameraId = 'native:zwo:1';

final _frame = CapturedImageResult(
  width: 2,
  height: 1,
  displayData: List<int>.filled(8, 255),
  histogram: List<int>.filled(256, 0),
  stats: const ImageStatsResult(
    min: 0,
    max: 1,
    mean: 0.5,
    median: 0.5,
    stdDev: 0.1,
    starCount: 0,
  ),
  exposureTime: 2,
  timestamp: '2026-10-21T08:43:29Z',
);

({_MockNetworkBackend backend, ProviderContainer container}) _setUp() {
  final backend = _MockNetworkBackend();
  when(
    () => backend.sequencerGetStatus(),
  ).thenAnswer((_) async => const SequencerStatus(state: 'Idle', progress: 0));
  when(() => backend.getHostRuntimeState()).thenAnswer(
    (_) async => const [
      HostRuntimeUpdate(
        channel: 'device.camera',
        revision: 1,
        value: {
          'state': 'connected',
          'deviceId': _cameraId,
          'deviceName': 'ZWO ASI1600MM-Cool',
        },
      ),
    ],
  );
  when(
    () =>
        backend.cameraGetLastImage(_cameraId, maxWidth: any(named: 'maxWidth')),
  ).thenAnswer((_) async => _frame);
  when(
    () => backend.getLastRawImageData(_cameraId),
  ).thenAnswer((_) async => Uint16List(2));
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);

  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      loggingServiceProvider.overrideWithValue(LoggingService()),
    ],
  );
  addTearDown(container.dispose);
  return (backend: backend, container: container);
}

Future<void> _hydrate(
  ProviderContainer container,
  NetworkBackend backend, {
  required bool refreshCurrentFrame,
}) async {
  try {
    await hydrateRemoteSessionState(
      container,
      backend,
      refreshCurrentFrame: refreshCurrentFrame,
    );
  } catch (_) {
    // The planner/profile fan-out after the frame step is not stubbed here;
    // only the frame fetch matters to these tests.
  }
  await pumpEventQueue();
}

void main() {
  test('the periodic re-hydrate does not fetch the last frame', () async {
    final (:backend, :container) = _setUp();

    await _hydrate(container, backend, refreshCurrentFrame: false);

    verifyNever(
      () => backend.cameraGetLastImage(any(), maxWidth: any(named: 'maxWidth')),
    );
    verifyNever(() => backend.getLastRawImageData(any()));
  });

  test(
    'first connect fetches it once, and the same frame is not republished',
    () async {
      final (:backend, :container) = _setUp();

      await _hydrate(container, backend, refreshCurrentFrame: true);
      final shown = container.read(currentImageProvider);
      expect(shown, isNotNull);
      verify(
        () => backend.cameraGetLastImage(
          _cameraId,
          maxWidth: any(named: 'maxWidth'),
        ),
      ).called(1);
      verify(() => backend.getLastRawImageData(_cameraId)).called(1);

      // A reconnect asks again; the host still has the same frame.
      await _hydrate(container, backend, refreshCurrentFrame: true);

      verify(
        () => backend.cameraGetLastImage(
          _cameraId,
          maxWidth: any(named: 'maxWidth'),
        ),
      ).called(1);
      verifyNever(() => backend.getLastRawImageData(any()));
      expect(
        container.read(currentImageProvider)?.capturedAt,
        shown!.capturedAt,
      );
    },
  );

  test('a frame with no capture event takes what the host recorded', () async {
    final (:backend, :container) = _setUp();
    final records = _MockImagingRecords();
    // The shown frame (08:43:29, as `_frame` carries) is a dark; four newer
    // lights were saved after it, as when the app reopens mid-run.
    DbCapturedImage row(int id, String type, DateTime at) => DbCapturedImage(
      id: id,
      sessionId: 7,
      filePath: '/host/f$id.fits',
      fileName: 'f$id.fits',
      fileFormat: 'fits',
      frameType: type,
      exposureDuration: 2,
      gain: 100,
      offset: 50,
      binX: 1,
      binY: 1,
      filter: 'L',
      capturedAt: at,
      createdAt: at,
      isAccepted: true,
      isPlateSolved: false,
    );
    final shownAt = DateTime.utc(2026, 10, 21, 8, 43, 29);
    final rows = [
      row(185, 'light', shownAt.subtract(const Duration(seconds: 3))),
      row(186, 'dark', shownAt),
      for (var i = 1; i <= 4; i++)
        row(186 + i, 'light', shownAt.add(Duration(seconds: 3 * i + 3))),
    ];
    when(
      () => records.getRecentImagesForSession(
        7,
        limit: any(named: 'limit'),
        atOrBefore: any(named: 'atOrBefore'),
      ),
    ).thenAnswer((call) async {
      final limit = call.namedArguments[#limit] as int;
      final atOrBefore = call.namedArguments[#atOrBefore] as DateTime?;
      final kept =
          rows
              .where(
                (r) => atOrBefore == null || !r.capturedAt.isAfter(atOrBefore),
              )
              .toList()
            ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      return kept.take(limit).toList();
    });
    final scoped = ProviderContainer(
      parent: container,
      overrides: [imagingRecordsProvider.overrideWithValue(records)],
    );
    addTearDown(scoped.dispose);
    scoped
        .read(sessionStateProvider.notifier)
        .mirrorHostSession(const SessionState(isActive: true, dbSessionId: 7));

    await _hydrate(scoped, backend, refreshCurrentFrame: true);

    final shown = scoped.read(currentImageProvider);
    expect(shown, isNotNull);
    expect(shown!.settings.frameType, FrameType.dark);
    expect(shown.settings.gain, 100);
  });
}
