// Regression test: once the operator aborts a capture, the preview must stop
// counting down the exposure it just gave up on.
//
// Observed on the running release build: a 30 s light was aborted 24 s in, the
// native log recorded "Exposure cancelled" — and the on-image ring carried on
// to 97% / "1.0s remaining" for another four seconds, then the exposure ran to
// its full duration. `ExposureProgress` keeps ticking after a cancel because
// the native waiter publishes progress until the driver reports not-exposing
// or the duration deadline passes, so the countdown described a frame that was
// never going to arrive.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/widgets/tutorial_keys/imaging_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// An imaging service whose exposure never finishes on its own, so the screen
/// stays in its "single capture in flight" state for the whole test — exactly
/// the state the abort button exists for.
class _StalledImagingService extends ImagingService {
  _StalledImagingService(super.ref);

  final Completer<CapturedImageData?> _pending =
      Completer<CapturedImageData?>();
  bool cancelRequested = false;

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
    cancelRequested = true;
  }

  void finish() {
    if (!_pending.isCompleted) _pending.complete(null);
  }
}

List<Override> _connectedCamera() => [
      cameraStateProvider.overrideWith((ref) {
        final notifier = CameraStateNotifier(ref);
        notifier
          ..setConnecting('sim_camera_1', 'Simulated Camera')
          ..setConnected();
        return notifier;
      }),
    ];

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = defaultOnError);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('aborting a capture stops the countdown and the abort control',
      (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
      extraOverrides: [
        ..._connectedCamera(),
        imagingServiceProvider.overrideWith(_StalledImagingService.new),
      ],
    );
    await _drain(tester);
    final service =
        handle.container.read(imagingServiceProvider) as _StalledImagingService;
    addTearDown(service.finish);

    // Start a 30 s exposure and let it run to 20%.
    await tester.tap(find.byKey(ImagingTutorialKeys.snapshotBtn));
    await _drain(tester);
    final progress = handle.container.read(exposureProgressProvider.notifier)
      ..startExposure(30, 1, null);
    progress.updateProgress(6, 24, 20);
    await _drain(tester);

    expect(find.text('Exposing...'), findsOneWidget);
    expect(find.text('24.0s remaining'), findsOneWidget);
    expect(find.byKey(ImagingTutorialKeys.abortBtn), findsOneWidget);

    // Abort. The device keeps publishing progress for the exposure it was told
    // to drop — the same three ticks the release build showed after "Exposure
    // cancelled" was logged.
    await tester.tap(find.byKey(ImagingTutorialKeys.abortBtn));
    await _drain(tester);
    expect(service.cancelRequested, isTrue,
        reason: 'the abort must reach the imaging service, not just the UI');
    progress.updateProgress(28, 2, 93);
    progress.updateProgress(29, 1, 97);
    await _drain(tester);

    expect(
      find.text('Stopping exposure...'),
      findsOneWidget,
      reason: 'the operator asked for this frame to stop; the canvas must say '
          'so instead of narrating the exposure it abandoned',
    );
    expect(find.text('Exposing...'), findsNothing);
    expect(
      find.textContaining('s remaining'),
      findsNothing,
      reason: 'counting down to a frame that will never arrive is the defect',
    );
    expect(
      find.byKey(ImagingTutorialKeys.abortBtn),
      findsNothing,
      reason: 'a second abort has nothing left to cancel',
    );
  });
}
