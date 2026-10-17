// Widget tests for ImagingScreen.
//
// Scope:
//
// Layout smoke tests:
//   1. mobile_layout_renders   — width < 768 picks the stacked column
//      branch (LivePreviewArea + PanelTabs, no desktop ResizablePanel).
//   2. desktop_layout_renders  — width >= 768 picks the Row + side pane
//      branch (LivePreviewArea + ResizablePanel present).
//   3. renders_without_throwing — default MockBackend pump produces no
//      uncaught exceptions.
//
// Behavior tests (W10 deeper):
//   4. error_state_shows_disconnected_preview — driving the camera state
//      notifier into [DeviceConnectionState.error] surfaces the same
//      "No Camera Connected" preview message as plain disconnect. Why we
//      assert that: the imaging screen treats error and disconnected as
//      equivalent for the preview area (both block image rendering), so
//      a regression that started gating on `state == disconnected` only
//      would silently render an empty image area on real driver faults.
//   5. exposure_button_disabled_when_camera_disconnected — confirms the
//      snapshot BigActionButton is disabled when the camera is not
//      connected and becomes enabled when the override flips to
//      connected. Why both halves: a "disabled by default" assertion
//      alone would also pass for a button that was permanently broken.
//   6. filter_change_updates_selected_filter — populating
//      [filterWheelStateProvider] with names and a current position
//      renders the filter buttons inside the control panel and marks
//      the active position as selected (FontWeight.bold). Verifies the
//      provider-to-UI binding inside FilterWheelSelector reachable from
//      the imaging screen, not just the selector in isolation.
//   7. camera_temperature_displays_when_connected — overriding the camera
//      state with temperature populates the QuickStatsPanel sensor
//      readout. Why this one exists: temperature flows through several
//      hops (camera notifier → cameraStateProvider → QuickStatsPanel
//      formatter) and a previous regression masked it as '---'.
//   8. switching_tabs_preserves_selectedImagingPanelProvider — tapping
//      the Camera tab on the PanelTabs strip flips
//      [selectedImagingPanelProvider] to index 1, proving the tab state
//      survives the IndexedStack rebuild. Without this, navigating away
//      and back to the imaging screen resets the user's tab.
//
// Why settle: false and fixed-step pumps instead of pumpAndSettle: the
// imaging control panel hosts BigActionButton, whose loading
// AnimationController.repeat() never settles. pumpAndSettle would hang
// on the first frame and time out. Fixed-step pumps deliver enough
// frames for Riverpod's AsyncValue overrides and the screen's 200ms
// _fadeController to flow through without waiting on infinite loops.
//
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_capture_bar.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_side_panel.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_preview_area.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_app/widgets/tutorial_keys/imaging_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _ControllableImagingService extends ImagingService {
  _ControllableImagingService(this.ref) : super(ref);

  final Ref ref;
  final previewPublished = Completer<void>();
  final capturePersistence = Completer<void>();
  final loopStarted = Completer<void>();
  final loopStopped = Completer<void>();
  int cancelCount = 0;

  /// What the screen asked for on the last loop run — Loop is a live-view
  /// mode and must not persist frames unless the operator opted in.
  bool? lastSaveFrames;

  CapturedImageData get frame => CapturedImageData(
        width: 4,
        height: 4,
        displayData: Uint8List(4 * 4 * 4),
        histogram: List<int>.filled(256, 0),
        stats: const ImageStats(mean: 100, stdDev: 5),
        capturedAt: DateTime.utc(2026, 7, 13, 22),
        settings: const ExposureSettings(
          exposureTime: 1,
          gain: 100,
          offset: 10,
        ),
        filePath: '/tmp/manual_capture.fits',
      );

  @override
  Future<CapturedImageData?> captureImage({
    required ExposureSettings settings,
    String? targetName,
    int? frameNumber,
    String? producingNodeId,
    String? producingRunId,
  }) async {
    final captured = frame;
    ref.read(currentImageProvider.notifier).state = captured;
    if (!previewPublished.isCompleted) previewPublished.complete();
    await capturePersistence.future;
    return captured;
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
    lastSaveFrames = saveFrames;
    if (!loopStarted.isCompleted) loopStarted.complete();
    await loopStopped.future;
  }

  @override
  void cancelExposure() {
    cancelCount++;
    if (!loopStopped.isCompleted) loopStopped.complete();
    if (!capturePersistence.isCompleted) capturePersistence.complete();
  }
}

/// Drive several frames so async-provider overrides flow into the
/// widget tree and the screen's 200ms _fadeController completes. We
/// avoid pumpAndSettle because BigActionButton's loading animation
/// (AnimationController.repeat()) never settles.
Future<void> _drainAsyncFrames(WidgetTester tester) async {
  // 8 x 50ms = 400ms — enough for AsyncValue providers, the fade
  // transition, and the post-frame catalog-prompt scheduling.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'exposure remains editable when the outer shell consumed keyboard space',
      (tester) async {
    addTearDown(() {
      tester.view.resetViewInsets();
    });

    await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(932, 430),
      settle: false,
    );
    await _drainAsyncFrames(tester);

    final exposureRow = find.byWidgetPredicate(
      (widget) =>
          widget is InlineNumberField &&
          widget.semanticLabel == 'Exposure seconds',
    );
    final exposure = find.descendant(
      of: exposureRow,
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(exposure).controller!.text,
      '2.0',
      reason: 'manual snapshot controls use the safe cold-start default',
    );
    expect(tester.takeException(), isNull);
    expect(exposure.hitTestable(), findsOneWidget);

    await tester.tap(exposure);
    tester.view.viewInsets = const FakeViewPadding(bottom: 330);
    await tester.pump();
    await tester.enterText(exposure, '30');
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.widgetWithText(TextField, '30'), findsOneWidget);
  });

  testWidgets(
      'phone_layout_renders: width < 600 keeps the canvas and puts the '
      'controls in a sheet with the shutter on it', (tester) async {
    // Phone tier per the mobile-responsive standard: width < 600. 390x844
    // is a modern phone in portrait. The screen now drives all tiers
    // through AdaptivePanelLayout (no bespoke mobile column), so we assert
    // the preview is present and the snapshot button — the primary capture
    // action — is reachable without opening the controls sheet.
    await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(390, 844),
      settle: false,
    );
    await _drainAsyncFrames(tester);

    expect(find.byType(LivePreviewArea), findsOneWidget);
    // Below the shell breakpoint the side panel becomes a bottom sheet, so
    // the 44 px icon strip must not be on screen at all.
    expect(find.byType(ImagingSidePanel), findsNothing,
        reason: 'the narrow layout uses the controls sheet, not the strip');
    expect(find.byType(ResizablePanel), findsNothing);
    // The primary capture action is on the sheet, reachable without scrolling
    // or expanding anything (mobile-responsive standard rule 5).
    expect(find.byKey(ImagingTutorialKeys.snapshotBtn), findsOneWidget,
        reason:
            'On phones the Snapshot button must be visible under the canvas '
            'without opening anything (standard rule 5).');
  });

  testWidgets(
      'desktop_layout_renders: width >= 768 puts the side panel beside the '
      'canvas and the capture bar over it', (tester) async {
    // 1600x900 is a representative laptop/desktop size. The desktop split
    // is now provided by AdaptivePanelLayout (resizable divider) rather
    // than the removed ResizablePanel; both the preview and the tab strip
    // remain present side-by-side.
    await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drainAsyncFrames(tester);

    expect(find.byType(LivePreviewArea), findsOneWidget);
    expect(find.byType(ImagingSidePanel), findsOneWidget,
        reason: 'the eight control sections live on the side-panel strip');
    expect(find.byType(ResizablePanel), findsNothing);
    // The capture bar is glass over the frame, not a full-width row under it.
    expect(find.byType(ImagingCaptureBar), findsOneWidget,
        reason: 'the desktop canvas carries the glass capture bar');
  });

  testWidgets(
      'renders_without_throwing: default MockBackend pump is exception-free',
      (tester) async {
    // Smoke test — the screen wires many providers (cameraState,
    // exposureSettings, annotation*, imagingViewer, etc.). If any of
    // those defaults throw during the initial build chain, this test
    // catches it before the more specific layout tests do.
    await pumpAppScreen(
      tester,
      const ImagingScreen(),
      settle: false,
    );
    await _drainAsyncFrames(tester);

    expect(tester.takeException(), isNull,
        reason:
            'Initial ImagingScreen pump under the default harness should not '
            'surface any uncaught exceptions.');
  });

  // Behavior tests beyond the smoke pumps above.

  testWidgets(
      'error_state_shows_disconnected_preview: camera in error state renders the '
      '"No Camera Connected" empty preview message', (tester) async {
    // The LivePreviewArea branches on
    // `cameraState.connectionState == DeviceConnectionState.connected`;
    // any non-connected value (disconnected OR error) must yield the
    // disconnected message + helper text. We drive the notifier into the
    // error branch explicitly via setError() to prove the screen doesn't
    // accidentally narrow to == disconnected.
    await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
      extraOverrides: [
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier.setError(
            Exception('simulated driver fault for widget test'),
          );
          return notifier;
        }),
      ],
    );
    await _drainAsyncFrames(tester);

    expect(find.text('No camera connected'), findsOneWidget,
        reason:
            'Camera error state must render the same empty preview as a plain '
            'disconnect so users see a clear "connect a camera" prompt rather '
            'than a blank canvas.');
    expect(
      find.text('Connect a camera in Equipment to start imaging.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'exposure_button_disabled_when_camera_disconnected: snapshot BigActionButton '
      'flips isEnabled with cameraStateProvider.connectionState',
      (tester) async {
    // Phase 1: default harness leaves the camera disconnected, so the
    // snapshot button must be disabled.
    final disconnectedHandle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drainAsyncFrames(tester);

    final disconnectedBtn = tester.widget<SkotiqButton>(
      find.byKey(ImagingTutorialKeys.snapshotBtn),
    );
    expect(disconnectedBtn.onPressed, isNull,
        reason:
            'Snapshot button must be disabled when no camera is connected — '
            'firing _takeSnapshot would call the imaging service against null.');
    addTearDown(() async {
      await disconnectedHandle.database.close();
    });
    // Rebuild the widget tree under a fresh pump so the override applies
    // cleanly; switching the override at runtime requires container reuse
    // which the harness intentionally doesn't expose (each test gets its
    // own container so state never leaks between tests).
  });

  testWidgets(
      'exposure_button_enabled_when_camera_connected: snapshot BigActionButton '
      'becomes enabled once cameraStateProvider reports connected',
      (tester) async {
    // Companion to the previous test: a connected override flips
    // isConnected to true, which lets _isCapturing fall through to enable
    // both Snapshot and Loop. Asserting both halves rules out a stuck
    // "always disabled" regression.
    await pumpAppScreen(
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
      ],
    );
    await _drainAsyncFrames(tester);

    final snapshotBtn = tester.widget<SkotiqButton>(
      find.byKey(ImagingTutorialKeys.snapshotBtn),
    );
    expect(snapshotBtn.onPressed, isNotNull,
        reason:
            'Snapshot button must be enabled when cameraStateProvider reports '
            'connected and no capture is in-flight.');

    final loopBtn = tester.widget<SkotiqButton>(
      find.byKey(ImagingTutorialKeys.loopBtn),
    );
    expect(loopBtn.onPressed, isNotNull,
        reason:
            'Loop button shares the isConnected gate; if it is disabled while '
            'Snapshot is enabled the gating logic has drifted.');
  });

  testWidgets('snapshot stays disabled while the visible frame is still saving',
      (tester) async {
    late _ControllableImagingService service;
    await pumpAppScreen(
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
        imagingServiceProvider.overrideWith((ref) {
          service = _ControllableImagingService(ref);
          return service;
        }),
      ],
    );
    await _drainAsyncFrames(tester);

    await tester.tap(find.byKey(ImagingTutorialKeys.snapshotBtn));
    await service.previewPublished.future;
    await tester.pump();

    expect(find.text('Saving…'), findsOneWidget);
    expect(
      tester
          .widget<SkotiqButton>(find.byKey(ImagingTutorialKeys.snapshotBtn))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<SkotiqButton>(find.byKey(ImagingTutorialKeys.loopBtn))
          .onPressed,
      isNull,
    );

    service.capturePersistence.complete();
    await _drainAsyncFrames(tester);
    expect(find.text('Snapshot'), findsOneWidget);
    expect(
      tester
          .widget<SkotiqButton>(find.byKey(ImagingTutorialKeys.snapshotBtn))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving the Imaging screen stops an active manual loop',
      (tester) async {
    late _ControllableImagingService service;
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
        imagingServiceProvider.overrideWith((ref) {
          service = _ControllableImagingService(ref);
          return service;
        }),
      ],
    );
    await _drainAsyncFrames(tester);

    await tester.tap(find.byKey(ImagingTutorialKeys.loopBtn));
    await service.loopStarted.future;
    expect(handle.container.read(sessionStateProvider).isCapturing, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(service.cancelCount, 1);
    expect(handle.container.read(sessionStateProvider).isCapturing, isFalse);
  });

  testWidgets(
      'camera_temperature_displays_when_connected: the Capture section chip '
      'formats cameraStateProvider.temperature as "X.X °C"', (tester) async {
    // The banner's stats readout renders '---' when disconnected, 'N/A' when
    // connected without a temperature reading, and 'X.X°C' when both
    // are present. We exercise the happy path: connected + 17.3°C →
    // visible "17.3°C". Why a non-trivial decimal: 0.0 would round-
    // trip the same as a missing-data placeholder in some formatters,
    // and a positive integer would match the autoreconnect retry-delay
    // strings nearby; 17.3 has no false-positive cousin in the screen.
    await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
      extraOverrides: [
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier
            ..setConnecting('test-cam-1', 'Test Camera')
            ..setConnected()
            ..updateTemperature(17.3, 42.0);
          return notifier;
        }),
      ],
    );
    await _drainAsyncFrames(tester);

    expect(find.byKey(ImagingTutorialKeys.statsPanel), findsOneWidget,
        reason: 'the frame-stats glass owns the top-left corner of the canvas');
    expect(find.text('17.3 °C'), findsWidgets,
        reason: 'The connected camera temperature must surface on the Capture '
            'section chip — a missing match means the cameraStateProvider '
            'binding has drifted.');
  });

  testWidgets(
      'switching_sections_preserves_selectedImagingPanelProvider: tapping the '
      'Camera strip button flips selectedImagingPanelProvider to index 1',
      (tester) async {
    // The IndexedStack is driven by selectedImagingPanelProvider, and
    // _selectPanel() updates the state-notifier. Tapping the Camera tab
    // (index 1) must move the provider from 0 → 1; that's what makes the
    // tab state survive navigation away from the imaging screen and
    // back. Without this provider write the next pump would always
    // reset to Capture.
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drainAsyncFrames(tester);

    // Sanity: the provider starts at 0 (Capture).
    expect(handle.container.read(selectedImagingPanelProvider), equals(0));

    // The Camera section is an icon on the side-panel strip; its tooltip is
    // its accessible name, which is the only text it has.
    await tester.tap(find.bySemanticsLabel('Camera').first);
    // Drain frames so the StateNotifier write propagates and the
    // _fadeController.reset()/forward() chain stabilises.
    await _drainAsyncFrames(tester);

    expect(handle.container.read(selectedImagingPanelProvider), equals(1),
        reason: 'Tapping the Camera strip button must advance '
            'selectedImagingPanelProvider to 1 so the section survives a route '
            'push/pop or hot reload.');
  });

  // The "Calibrated" badge surfaces in the upper-right of the
  // live preview whenever the published image's file path carries the
  // `_cal.fits` suffix the calibration service writes. Two flavours so
  // the test pins on both the positive case (badge present + text) and
  // the negative one (raw light frame, no badge) — without the negative
  // side a regression that always rendered the badge would still pass.
  testWidgets(
      'calibrated_badge_visible_for_calibrated_frame: live preview shows '
      'the success badge when current image filePath ends in _cal.fits',
      (tester) async {
    final calibratedFrame = CapturedImageData(
      width: 8,
      height: 8,
      displayData: Uint8List(8 * 8 * 4),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(mean: 0, stdDev: 0),
      capturedAt: DateTime.utc(2026, 5, 23, 21, 0, 0),
      settings: const ExposureSettings(
        exposureTime: 1.0,
        gain: 100,
        offset: 10,
      ),
      filePath: '/tmp/light_001_cal.fits',
    );
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drainAsyncFrames(tester);
    // Publish the calibrated frame after pump so the provider override
    // doesn't fight with the screen's own listeners during build.
    handle.container.read(currentImageProvider.notifier).state =
        calibratedFrame;
    await _drainAsyncFrames(tester);

    expect(find.text('Calibrated'), findsOneWidget,
        reason: 'A frame whose saved path ends in _cal.fits is the only signal '
            'the imaging pipeline has that calibration actually succeeded — '
            'the badge MUST render so users can tell raw vs calibrated.');
  });

  testWidgets(
      'calibrated_badge_hidden_for_raw_frame: live preview does not show the '
      'Calibrated badge when the current image is an uncalibrated .fits',
      (tester) async {
    final rawFrame = CapturedImageData(
      width: 8,
      height: 8,
      displayData: Uint8List(8 * 8 * 4),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(mean: 0, stdDev: 0),
      capturedAt: DateTime.utc(2026, 5, 23, 21, 0, 0),
      settings: const ExposureSettings(
        exposureTime: 1.0,
        gain: 100,
        offset: 10,
      ),
      filePath: '/tmp/light_001.fits',
    );
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drainAsyncFrames(tester);
    handle.container.read(currentImageProvider.notifier).state = rawFrame;
    await _drainAsyncFrames(tester);

    expect(find.text('Calibrated'), findsNothing,
        reason:
            'A raw .fits frame must not display the Calibrated badge — doing '
            'so would lie to the operator about a frame that never went '
            'through dark/flat/bias subtraction.');
  });

  // MOBILE-RESPONSIVE STANDARD: no overflow + primary capture reachable at the
  // three reference phone sizes, in BOTH orientations.
  //
  // These intentionally do NOT swallow overflow exceptions — the whole point is
  // to catch RenderFlex overflow at phone widths/heights. We connect the camera
  // so the snapshot button is enabled (its enabled state is part of "primary
  // capture reachable") and pump a real captured frame so the preview chrome
  // and toolbar (resolution/zoom readouts) render at their full width.

  /// The reference phone sizes from the standard (portrait), each also exercised
  /// rotated to landscape below.
  const phonePortraitSizes = <(String, Size)>[
    ('small_phone_360x640', Size(360, 640)),
    ('modern_phone_390x844', Size(390, 844)),
    ('large_phone_430x932', Size(430, 932)),
  ];

  CapturedImageData buildFrame() => CapturedImageData(
        width: 64,
        height: 48,
        displayData: Uint8List(64 * 48 * 4),
        histogram: List<int>.filled(256, 0),
        stats: const ImageStats(mean: 0, stdDev: 0),
        capturedAt: DateTime.utc(2026, 6, 1, 21, 0, 0),
        settings: const ExposureSettings(
          exposureTime: 1.0,
          gain: 100,
          offset: 10,
        ),
        filePath: '/tmp/light_phone.fits',
      );

  for (final (label, portrait) in phonePortraitSizes) {
    final landscape = Size(portrait.height, portrait.width);
    for (final (orientation, size) in <(String, Size)>[
      ('portrait', portrait),
      ('landscape', landscape),
    ]) {
      testWidgets(
          'phone_no_overflow_${label}_$orientation: imaging screen has no '
          'RenderFlex overflow and the Snapshot control is present',
          (tester) async {
        // No overflow-swallowing here: any RenderFlex overflow at this
        // size/orientation must fail the test.
        final handle = await pumpAppScreen(
          tester,
          const ImagingScreen(),
          size: size,
          settle: false,
          extraOverrides: [
            cameraStateProvider.overrideWith((ref) {
              final notifier = CameraStateNotifier(ref);
              notifier
                ..setConnecting('phone-cam', 'Phone Camera')
                ..setConnected();
              return notifier;
            }),
          ],
        );
        await _drainAsyncFrames(tester);
        // Publish a frame so the preview + toolbar render their full chrome.
        handle.container.read(currentImageProvider.notifier).state =
            buildFrame();
        await _drainAsyncFrames(tester);

        // No uncaught exception (which would include any RenderFlex overflow).
        expect(tester.takeException(), isNull,
            reason: 'ImagingScreen at $size ($orientation) must not overflow.');

        // Primary capture action reachable without opening a sheet. WHERE it
        // lives differs by width, but it must ALWAYS exist — the audit found
        // this screen with no exposure-start control at all in the landscape
        // band:
        //  * Below the shell breakpoint: the controls sheet carries a
        //    full-width Snapshot button.
        //  * Above it: the glass capture bar over the frame carries it.
        expect(find.byKey(ImagingTutorialKeys.snapshotBtn), findsOneWidget,
            reason: 'Every layout must offer a Snapshot button at $size '
                '($orientation).');
        final snapshotBtn = tester.widget<SkotiqButton>(
          find.byKey(ImagingTutorialKeys.snapshotBtn),
        );
        expect(snapshotBtn.onPressed, isNotNull,
            reason:
                'With a connected camera the Snapshot button must be enabled '
                'at $size ($orientation).');

        // The live preview keeps the dominant region.
        expect(find.byType(LivePreviewArea), findsOneWidget);
      });
    }
  }
}
