// The Dashboard Capture card's Loop button is a live view, not acquisition.
//
// It must NOT run [ImagingService.captureImage], the keeper-only entry point
// (`persistFrame: true`): that writes every frame full-size into the operator's
// light-frame folder, indexes it in `captured_images` and counts it as session
// integration — around 27 GB an hour at 5 s subs, from a button that only
// offers a live view.
//
// These tests drive the real widget's real buttons, so restoring the
// `_captureImage` wiring fails them. The spy separates the two service entry
// points rather than stubbing only `captureImage`.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/capture_settings_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

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
        settings: const ExposureSettings(
          exposureTime: 5,
          gain: 100,
          offset: 10,
        ),
        filePath: '/tmp/skotiq_captures/liveview_camera-1.fits',
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(HarnessHandle, _LoopSpyImagingService)> pumpCard(
    WidgetTester tester,
  ) async {
    late _LoopSpyImagingService service;
    final handle = await pumpAppScreen(
      tester,
      const CaptureSettingsCard(colors: SkotiqColors.dark),
      extraOverrides: [
        cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
        imagingServiceProvider.overrideWith(
          (ref) => service = _LoopSpyImagingService(ref),
        ),
      ],
    );
    return (handle, service);
  }

  testWidgets('Loop runs the live-view path and keeps nothing', (tester) async {
    final (handle, service) = await pumpCard(tester);

    await tester.tap(find.text('Loop'));
    await tester.pump();
    expect(find.text('Stop Loop'), findsOneWidget);

    // Several frames, not just the first: a loop that starts on the live-view
    // path and then falls back to the keeper path is the same 27 GB.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }

    expect(service.loopRuns, greaterThanOrEqualTo(3),
        reason: 'Loop must keep exposing through the live-view entry point');
    expect(service.loopSaveFrames, everyElement(isFalse),
        reason: 'a card with no save-frames control must not retain frames');
    expect(service.keeperCaptures, 0,
        reason: 'captureImage writes into the light-frame folder and indexes '
            'the row; Loop must never reach it');
    // A discarded framing frame is not integration the operator can stack.
    expect(handle.container.read(sessionStateProvider).completedExposures, 0);

    await tester.tap(find.text('Stop Loop'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Loop'), findsOneWidget);
  });

  testWidgets('Capture still writes a keeper frame', (tester) async {
    final (_, service) = await pumpCard(tester);

    // The card header is also called "Capture"; target the button.
    await tester.tap(find.widgetWithText(SkotiqButton, 'Capture'));
    await tester.pump();

    expect(service.keeperCaptures, 1);
    expect(service.loopRuns, 0,
        reason: 'a deliberate single capture is the one frame that is kept');
  });
}
