// Aborting a capture is not a capture failure.
//
// A camera driver that is told to stop mid-exposure reports the acquisition as
// failed — the native path returns `Exposure cancelled` from the very
// `cameraStartExposure` call the service is still awaiting. Surfaced as an
// error that put "Capture failed: Exposure cancelled" on screen every time the
// operator pressed the abort X, which reads as "your frame broke" when what
// actually happened is the thing they asked for.
//
// The narrow part matters as much as the swallow: only a cancel THIS service
// requested is absorbed. A driver that fails on its own must still raise.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/services/imaging_service.dart';

import '../mocks/mock_backend.dart';

void main() {
  late MockBackend backend;
  late StreamController<SkotiqEvent> events;
  late Completer<void> exposureLanded;

  setUpAll(registerMocktailFallbackValues);

  setUp(() {
    backend = MockBackend();
    events = StreamController<SkotiqEvent>.broadcast();
    exposureLanded = Completer<void>();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.getCameraCapabilities(any()),
    ).thenAnswer((_) async => null);
    when(() => backend.cameraAbortExposure(any())).thenAnswer((_) async {});
  });

  tearDown(() => events.close());

  /// A driver whose blocking exposure call fails the way an aborted one does.
  void stubExposureFailingWith(Object error) {
    when(
      () => backend.cameraStartExposure(
        deviceId: any(named: 'deviceId'),
        exposureTime: any(named: 'exposureTime'),
        frameType: any(named: 'frameType'),
        gain: any(named: 'gain'),
        offset: any(named: 'offset'),
        binX: any(named: 'binX'),
        binY: any(named: 'binY'),
      ),
    ).thenAnswer((_) async {
      if (!exposureLanded.isCompleted) exposureLanded.complete();
      // Let the caller get a cancel in before the driver reports the failure.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      throw error;
    });
  }

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith((ref) => _FixedBackend(ref, backend)),
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier.setConnecting('cam-1', 'Test Camera');
          notifier.setConnected();
          return notifier;
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  const settings = ExposureSettings(exposureTime: 30, gain: 100, offset: 10);

  test('an operator abort does not surface as a capture failure', () async {
    stubExposureFailingWith(Exception('Exposure cancelled'));
    final container = buildContainer();
    final service = container.read(imagingServiceProvider);

    final capture = service.captureImage(settings: settings);
    await exposureLanded.future;
    service.cancelExposure();

    await expectLater(
      capture,
      completion(isNull),
      reason: 'the operator asked for this; it is not a failed frame',
    );
    expect(
      container.read(exposureProgressProvider),
      ExposureProgress.idle(),
      reason: 'the aborted exposure must stop being narrated',
    );
  });

  test('a driver failure nobody asked for still raises', () async {
    stubExposureFailingWith(Exception('USB transfer error'));
    final container = buildContainer();
    final service = container.read(imagingServiceProvider);

    await expectLater(
      service.captureImage(settings: settings),
      throwsA(isA<Exception>()),
      reason: 'swallowing this would hide every real capture fault',
    );
  });
}

/// Keeps [imagingServiceProvider] bound to one backend for the test's life.
class _FixedBackend extends BackendNotifier {
  _FixedBackend(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
