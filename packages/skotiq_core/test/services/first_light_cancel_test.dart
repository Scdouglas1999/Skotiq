// The first-light flow is stoppable.
//
// A progress modal with no cancel leaves the exposure running on the sensor
// when it is closed — Imaging goes on reading "Exposing... 999858.8s remaining"
// and the camera stays unusable until the process restarts. `reset()` is not a
// cancel: it clears the UI state and leaves the device exposing.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/auto_stretch_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/first_light_provider.dart';
import 'package:skotiq_core/src/services/first_light/first_light_orchestrator.dart';
import 'package:skotiq_core/src/services/imaging_service.dart';

/// An imaging service whose exposure never finishes on its own — the state the
/// cancel exists for. `cancelExposure` records the device-level abort and
/// resolves the capture the way the real service does when it aborts a frame.
class _StalledImagingService extends ImagingService {
  _StalledImagingService(super.ref);

  final Completer<CapturedImageData?> _pending =
      Completer<CapturedImageData?>();

  int cancelCalls = 0;

  @override
  Future<CapturedImageData?> captureImage({
    required ExposureSettings settings,
    String? targetName,
    int? frameNumber,
    String? producingNodeId,
    String? producingRunId,
  }) {
    return _pending.future;
  }

  @override
  void cancelExposure() {
    cancelCalls++;
    if (!_pending.isCompleted) _pending.complete(null);
  }

  void finish() {
    if (!_pending.isCompleted) _pending.complete(null);
  }
}

ProviderContainer _container(_StalledImagingService Function(Ref) imaging) {
  final container = ProviderContainer(
    overrides: [
      imagingServiceProvider.overrideWith(imaging),
      stretchedImageProvider.overrideWith((ref) async => Uint8List(0)),
    ],
  );
  addTearDown(container.dispose);
  final cam = container.read(cameraStateProvider.notifier);
  cam.setConnecting('cam-1', 'Test Camera');
  cam.setConnected();
  return container;
}

Future<FirstLightState> _waitFor(
  ProviderContainer container,
  bool Function(FirstLightState) predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final completer = Completer<FirstLightState>();
  void check(FirstLightState state) {
    if (!completer.isCompleted && predicate(state)) completer.complete(state);
  }

  final sub = container.listen<FirstLightState>(
    firstLightControllerProvider,
    (_, next) => check(next),
    fireImmediately: true,
  );
  try {
    return await completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'first-light state never satisfied predicate; last state was '
        '${container.read(firstLightControllerProvider)}',
        timeout,
      ),
    );
  } finally {
    sub.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cancel aborts the exposure at the camera and unwinds to idle',
    () async {
      final container = _container(_StalledImagingService.new);
      final service =
          container.read(imagingServiceProvider) as _StalledImagingService;
      addTearDown(service.finish);

      final controller = container.read(firstLightControllerProvider.notifier);
      final run = controller.run(exposureSeconds: 999999);
      await _waitFor(container, (s) => s.phase == FirstLightPhase.exposing);

      controller.cancel();

      expect(
        service.cancelCalls,
        1,
        reason: 'the cancel must reach the camera, not just clear the UI state',
      );

      final ended = await _waitFor(container, (s) => !s.isRunning);
      await run;

      expect(
        ended.phase,
        FirstLightPhase.idle,
        reason: 'an operator-requested stop is not a pipeline failure',
      );
      expect(ended.errorMessage, isNull);
      expect(controller.isRunning, isFalse);
    },
  );

  test('cancel before a run does not abort anything', () async {
    final container = _container(_StalledImagingService.new);
    final service =
        container.read(imagingServiceProvider) as _StalledImagingService;
    addTearDown(service.finish);

    container.read(firstLightControllerProvider.notifier).cancel();

    expect(service.cancelCalls, 0);
  });

  test('a cancel does not leak into the next run', () async {
    final container = _container(_StalledImagingService.new);
    final service =
        container.read(imagingServiceProvider) as _StalledImagingService;
    addTearDown(service.finish);

    final controller = container.read(firstLightControllerProvider.notifier);
    final first = controller.run(exposureSeconds: 999999);
    await _waitFor(container, (s) => s.phase == FirstLightPhase.exposing);
    controller.cancel();
    await _waitFor(container, (s) => !s.isRunning);
    await first;

    // The stalled service has already resolved its single completer, so the
    // second run reaches the "camera returned no image" branch — which is a
    // FAILURE, not the silent idle unwind a leaked cancel latch would produce.
    await controller.run(exposureSeconds: 5);
    final after = container.read(firstLightControllerProvider);

    expect(
      after.phase,
      FirstLightPhase.failed,
      reason: 'a stale cancel latch would swallow the next run',
    );
    expect(service.cancelCalls, 1);
  });
}
