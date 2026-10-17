// Regression tests for the Imaging preview's zoom scale.
//
// The viewer state's `zoomLevel` is a multiplier *relative to fit-to-window*
// (imaging_viewer_state_provider.dart documents "1.0 = fit-to-window"), but two
// consumers read it as if it were screen-pixels-per-image-pixel:
//
//   * the toolbar printed `${zoomLevel * 100}%`, so a 4144 x 2822 frame shown
//     inside a ~990 px viewport (23.8% actual) was labelled "100%";
//   * every overlay painter (stars, annotations, celestial grid, science and
//     moving-object overlays) was handed the same raw `zoomLevel` together with
//     `computeImageOffset`, whose `scaledSize = imageSize * zoomLevel` assumes
//     native scale — so markers were spread over 4.2x the true footprint and
//     only landed on their stars at the exact centre of the frame.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/imaging/widgets/annotation_tooltip.dart';
import 'package:skotiq_app/screens/imaging/widgets/image_display.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_app/screens/imaging/widgets/preview_display_scale.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const int _imageWidth = 2000;
const int _imageHeight = 1200;

CapturedImageData _frame() => CapturedImageData(
      width: _imageWidth,
      height: _imageHeight,
      displayData: Uint8List(_imageWidth * _imageHeight * 4),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(mean: 0, stdDev: 0),
      capturedAt: DateTime.utc(2026, 8, 3, 21, 0, 0),
      settings:
          const ExposureSettings(exposureTime: 1.0, gain: 100, offset: 10),
      filePath: '/tmp/light_001.fits',
    );

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Invoke the viewer toolbar's own `onPressed` for the button carrying
/// [tooltip].
void _pressToolbarButton(WidgetTester tester, String tooltip) {
  final button = tester.widget<SkotiqIconButton>(find
      .byWidgetPredicate((w) => w is SkotiqIconButton && w.tooltip == tooltip));
  button.onPressed!();
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

  testWidgets(
      'fit-to-window is reported as its true on-screen scale, not as 100%',
      (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drain(tester);
    handle.container.read(currentImageProvider.notifier).state = _frame();
    await _drain(tester);

    // The preview viewport is whatever height the Expanded left over.
    final viewport = tester.getSize(find.byType(ImageDisplayWidget));
    // BoxFit.contain inside a box that is itself clamped to the viewport, with
    // no upscaling of a smaller frame.
    final expectedScale = [
      1.0,
      viewport.width / _imageWidth,
      viewport.height / _imageHeight,
    ].reduce((a, b) => a < b ? a : b);
    expect(expectedScale, lessThan(0.9),
        reason: 'the frame must be larger than the viewport for this test to '
            'say anything');

    final percent = '${(expectedScale * 100).round()}%';
    expect(
      find.text(percent),
      findsOneWidget,
      reason: 'the zoom readout must state the real screen-px-per-image-px '
          'ratio; "100%" for a 4.2x-downsampled frame is what made the 1:1 '
          'button look like a no-op',
    );
    expect(
      find.text('100%'),
      findsNothing,
      reason: 'fit-to-window is not 1:1',
    );
  });

  testWidgets('overlay painters are handed the scale the image is drawn at',
      (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drain(tester);
    handle.container.read(currentImageProvider.notifier).state = _frame();
    await _drain(tester);

    final viewport = tester.getSize(find.byType(ImageDisplayWidget));
    final expectedScale = [
      1.0,
      viewport.width / _imageWidth,
      viewport.height / _imageHeight,
    ].reduce((a, b) => a < b ? a : b);

    final overlay = tester.widget<AnnotationOverlayWrapper>(
        find.byType(AnnotationOverlayWrapper));
    expect(
      overlay.zoomLevel,
      closeTo(expectedScale, 0.001),
      reason: 'image-space -> viewport-space mapping uses this number together '
          'with computeImageOffset; feeding it the fit-relative multiplier put '
          'every marker at 1/fitScale times its true offset from the centre',
    );

    // The offset must agree with where the image really is: its left edge.
    final expectedLeft = (viewport.width - _imageWidth * expectedScale) / 2;
    expect(overlay.imageOffset.dx, closeTo(expectedLeft, 0.5));
  });

  testWidgets('the 1:1 button really shows one image pixel per screen pixel',
      (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drain(tester);
    handle.container.read(currentImageProvider.notifier).state = _frame();
    await _drain(tester);

    final fitScale = handle.container.read(previewFitScaleProvider);
    expect(fitScale, lessThan(0.9),
        reason: 'the frame must be larger than the viewport for 1:1 to differ '
            'from fit');

    // Fire the toolbar button's own callback rather than a synthetic tap: the
    // imaging screen parks a full-bleed tour prompt over the Overlay in a fresh
    // profile, which swallows hit tests on the trailing controls. This is still
    // the production wiring — the closure `ImagingPreviewToolbar` was built
    // with, i.e. `onZoom1to1: _zoom1to1`.
    _pressToolbarButton(tester, '1:1 zoom');
    await _drain(tester);

    expect(
      handle.container.read(previewDisplayScaleProvider),
      closeTo(1.0, 0.001),
      reason: '"1:1 zoom" must draw the frame at native scale; it used to be a '
          'byte-for-byte copy of fitToWindow, so pressing it returned to the '
          'same 23.8%-of-actual view it was pressed from',
    );
    expect(find.text('100%'), findsOneWidget);

    // The overlays must follow the image, not stay at the fit mapping.
    final overlay = tester.widget<AnnotationOverlayWrapper>(
        find.byType(AnnotationOverlayWrapper));
    expect(overlay.zoomLevel, closeTo(1.0, 0.001));

    // ...and the pixels really are drawn at that scale: the stored multiplier
    // is fit-relative, so 1:1 is 1 / fitScale, not 1.0.
    final display =
        tester.widget<ImageDisplayWidget>(find.byType(ImageDisplayWidget));
    expect(display.zoomLevel * fitScale, closeTo(1.0, 0.001));
  });

  testWidgets('the zoom ceiling is 8x actual, not 8x fit', (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drain(tester);
    handle.container.read(currentImageProvider.notifier).state = _frame();
    await _drain(tester);

    // 1.25^n saturates well before 40 presses at any realistic fit scale.
    for (var i = 0; i < 40; i++) {
      _pressToolbarButton(tester, 'Zoom in');
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _drain(tester);

    expect(
      handle.container.read(previewDisplayScaleProvider),
      closeTo(ImagingViewerStateNotifier.maxDisplayScale, 0.001),
      reason: 'the bounds used to be multipliers on fit, so on this frame the '
          'maximum reachable magnification was 8 * fitScale — under 2x actual — '
          'and on a larger sensor true 1:1 sat outside the clamp entirely',
    );
  });
}
