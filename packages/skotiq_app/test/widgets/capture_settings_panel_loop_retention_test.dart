// The shared CaptureSettingsPanel's Loop button is a live view, not
// acquisition.
//
// It looped [ImagingService.captureImage] — the keeper-only entry point — so
// every framing frame was written full-size into the operator's light-frame
// folder and indexed in `captured_images`: the same ~27 GB an hour already
// fixed on the Dashboard capture card, from a button that only offers a live
// view and has no retention control anywhere on the panel.
//
// The spy separates the two service entry points rather than stubbing only
// `captureImage` — stubbing one is what let the defect survive on the card.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/capture_settings_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/harness.dart';

class _ConnectedCameraNotifier extends CameraStateNotifier {
  _ConnectedCameraNotifier(super.ref) {
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'camera-1',
      deviceName: 'Test Camera',
    );
  }
}

class _LoopSpyImagingService extends ImagingService {
  _LoopSpyImagingService(super.ref);

  /// Frames requested through the keeper path.
  int keeperCaptures = 0;

  /// One entry per live-view run, holding the retention it asked for.
  final loopSaveFrames = <bool>[];

  int get loopRuns => loopSaveFrames.length;

  @override
  Future<CapturedImageData?> captureImage({
    required ExposureSettings settings,
    String? targetName,
    int? frameNumber,
    String? producingNodeId,
    String? producingRunId,
  }) async {
    keeperCaptures++;
    return _frame;
  }

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
    loopSaveFrames.add(saveFrames);
    for (var i = 0; i < (maxFrames ?? 1); i++) {
      onImageCaptured?.call(_frame);
    }
  }

  CapturedImageData get _frame => CapturedImageData(
        width: 4,
        height: 4,
        displayData: Uint8List(4 * 4 * 4),
        histogram: List<int>.filled(256, 0),
        stats: const ImageStats(mean: 100, stdDev: 5),
        capturedAt: DateTime.utc(2026, 8, 2, 22),
        settings:
            const ExposureSettings(exposureTime: 5, gain: 100, offset: 10),
        filePath: '/tmp/skotiq_captures/liveview_camera-1.fits',
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(HarnessHandle, _LoopSpyImagingService)> pumpPanel(
    WidgetTester tester,
  ) async {
    late _LoopSpyImagingService service;
    final handle = await pumpAppScreen(
      tester,
      const CaptureSettingsPanel(showHeader: false),
      extraOverrides: [
        cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
        imagingServiceProvider.overrideWith(
          (ref) => service = _LoopSpyImagingService(ref),
        ),
      ],
      settle: false,
    );
    await tester.pump();
    return (handle, service);
  }

  testWidgets('Loop runs the live-view path and keeps nothing', (tester) async {
    final (handle, service) = await pumpPanel(tester);

    await tester.tap(find.text('Loop'));
    await tester.pump();
    expect(find.text('Looping...'), findsOneWidget);

    // Several frames, not just the first: a loop that starts on the live-view
    // path and then falls back to the keeper path is the same 27 GB.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }

    expect(
      service.loopRuns,
      greaterThanOrEqualTo(3),
      reason: 'Loop must keep exposing through the live-view entry point',
    );
    expect(
      service.loopSaveFrames,
      everyElement(isFalse),
      reason: 'a panel with no save-frames control must not retain frames',
    );
    expect(
      service.keeperCaptures,
      0,
      reason: 'captureImage writes into the light-frame folder and indexes the '
          'row; Loop must never reach it',
    );
    // A discarded framing frame is not integration the operator can stack.
    expect(handle.container.read(sessionStateProvider).completedExposures, 0);

    // Stop the loop so the widget's inter-frame delay does not outlive the
    // test.
    await tester.tap(find.text('Looping...'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Loop'), findsOneWidget);
  });

  testWidgets('the Capture button still keeps its frame', (tester) async {
    final (_, service) = await pumpPanel(tester);

    await tester.tap(find.text('Capture'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      service.keeperCaptures,
      1,
      reason: 'a deliberate single capture is acquisition and must persist',
    );
    expect(service.loopRuns, 0);
  });
}
