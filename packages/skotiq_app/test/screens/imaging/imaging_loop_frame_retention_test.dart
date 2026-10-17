// Loop is a LIVE-VIEW mode. Running Snapshot's save-and-index pipeline with no
// control in the capture banner to say so writes around 27 GB of full-size
// `Unknown_NoFilter_*` lights an hour at 5 s subs into the operator's
// light-frame folder, and counts every one in the session's frame and
// integration totals.
//
// These tests pin the screen half: the banner exposes the choice, it defaults
// to OFF, and whatever it says is what the imaging service is asked for.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_capture_bar.dart';
import 'package:skotiq_app/widgets/tutorial_keys/imaging_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _LoopSpyImagingService extends ImagingService {
  _LoopSpyImagingService(super.ref);

  final loopStarted = Completer<void>();
  final loopStopped = Completer<void>();
  bool? lastSaveFrames;

  @override
  Future<void> startLoopCapture({
    required ExposureSettings settings,
    String? targetName,
    int? maxFrames,
    int maxConsecutiveErrors = 10,
    bool saveFrames = false,
    void Function(CapturedImageData)? onImageCaptured,
    void Function(String)? onError,
  }) async {
    lastSaveFrames = saveFrames;
    onImageCaptured?.call(_frame);
    if (!loopStarted.isCompleted) loopStarted.complete();
    await loopStopped.future;
  }

  @override
  void cancelExposure() {
    if (!loopStopped.isCompleted) loopStopped.complete();
  }

  CapturedImageData get _frame => CapturedImageData(
        width: 4,
        height: 4,
        displayData: Uint8List(4 * 4 * 4),
        histogram: List<int>.filled(256, 0),
        stats: const ImageStats(mean: 100, stdDev: 5),
        capturedAt: DateTime.utc(2026, 8, 1, 22),
        settings: const ExposureSettings(
          exposureTime: 5,
          gain: 100,
          offset: 10,
        ),
        filePath: '/tmp/liveview_cam.fits',
      );
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<HarnessHandle> pumpImaging(WidgetTester tester) async {
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
      extraOverrides: [
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier
            ..setConnecting('test-cam-1', 'Test Camera')
            ..setConnected();
          return notifier;
        }),
        imagingServiceProvider.overrideWith(_LoopSpyImagingService.new),
      ],
    );
    await _drain(tester);
    return handle;
  }

  _LoopSpyImagingService spy(HarnessHandle handle) =>
      handle.container.read(imagingServiceProvider) as _LoopSpyImagingService;

  testWidgets('Loop discards frames by default and says so on the capture bar',
      (tester) async {
    final handle = await pumpImaging(tester);
    final service = spy(handle);

    expect(find.byType(ImagingCaptureBar), findsOneWidget);
    expect(handle.container.read(loopSavesFramesProvider), isFalse,
        reason: 'live view must not fill the light-frame folder by default');
    // Visible and reachable next to Loop, not buried in a popover.
    expect(find.byKey(loopSaveFramesToggleKey).hitTestable(), findsOneWidget);
    final toggleSemantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(loopSaveFramesToggleKey),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(toggleSemantics.properties.label, 'Save loop frames');
    expect(toggleSemantics.properties.toggled, isFalse);

    await tester.tap(find.byKey(ImagingTutorialKeys.loopBtn));
    await service.loopStarted.future;
    await tester.pump();

    expect(service.lastSaveFrames, isFalse);
    // A discarded frame is not integration the operator can stack later.
    expect(handle.container.read(sessionStateProvider).completedExposures, 0);

    service.cancelExposure();
    await tester.pump();
  });

  testWidgets('turning the capture-bar toggle on makes Loop keep its frames',
      (tester) async {
    final handle = await pumpImaging(tester);
    final service = spy(handle);

    await tester.tap(find.byKey(loopSaveFramesToggleKey));
    await tester.pump();
    expect(handle.container.read(loopSavesFramesProvider), isTrue);

    await tester.tap(find.byKey(ImagingTutorialKeys.loopBtn));
    await service.loopStarted.future;
    await tester.pump();

    expect(service.lastSaveFrames, isTrue);
    expect(handle.container.read(sessionStateProvider).completedExposures, 1);

    service.cancelExposure();
    await tester.pump();
  });
}
