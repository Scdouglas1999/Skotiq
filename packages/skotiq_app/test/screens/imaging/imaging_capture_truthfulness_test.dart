// Regressions for the imaging-capture audit findings where the app was hiding
// something true, or asserting something untrue:
//
//  * the measurement readouts vanished on a 2.5 s idle timer, so a frame could
//    land and the histogram / HFR panel stayed blank until you moved the mouse;
//  * the exposure progress ring was drawn on top of the "No Image / take a
//    snapshot" empty state, telling the operator to start a capture that was
//    already running;
//  * below ~820 px in landscape the capture bar was dropped entirely, leaving
//    no way at all to start an exposure.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_preview_area.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_hud.dart';
import 'package:skotiq_app/widgets/tutorial_keys/imaging_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

CapturedImageData _frame() => CapturedImageData(
      width: 64,
      height: 48,
      displayData: Uint8List(64 * 48 * 4),
      histogram: List<int>.filled(256, 7),
      stats: const ImageStats(mean: 120, stdDev: 10, hfr: 2.51, starCount: 39),
      capturedAt: DateTime.utc(2026, 7, 29, 15, 34),
      settings: const ExposureSettings(
        exposureTime: 3.0,
        gain: 100,
        offset: 10,
      ),
      filePath: '/tmp/light.fits',
    );

List<Override> _connectedCamera() => [
      cameraStateProvider.overrideWith((ref) {
        final notifier = CameraStateNotifier(ref);
        notifier
          ..setConnecting('sim_camera_1', 'Simulated Camera')
          ..setConnected();
        return notifier;
      }),
    ];

/// Hosts the real [LivePreviewArea] on its own so the assertions are about the
/// canvas rather than the whole screen's layout.
class _PreviewHost extends ConsumerWidget {
  const _PreviewHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LivePreviewArea(
      colors: context.skotiqColors,
      zoomLevel: 1.0,
      panOffset: Offset.zero,
      showCrosshair: false,
      showStarOverlay: false,
      isStoppingCapture: false,
      onZoomIn: () {},
      onZoomOut: () {},
      onPanUpdate: (_) {},
    );
  }
}

/// Fails if [finder]'s widget is present but painted invisible.
///
/// Presence alone is not enough: an idle-hide that wraps these overlays in an
/// `AnimatedOpacity(opacity: 0)` keeps the widgets in the tree, so any
/// `findsOneWidget` assertion passes while the operator sees nothing.
void expectVisible(WidgetTester tester, Finder finder, String label) {
  expect(finder, findsOneWidget, reason: '$label must be in the tree');
  final faded = <String>[];
  finder.evaluate().single.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    double? opacity;
    if (widget is Opacity) opacity = widget.opacity;
    if (widget is AnimatedOpacity) opacity = widget.opacity;
    if (widget is FadeTransition) opacity = widget.opacity.value;
    if (opacity != null && opacity < 1.0) {
      faded.add('${widget.runtimeType}=$opacity');
    }
    return true;
  });
  expect(faded, isEmpty, reason: '$label is faded out by $faded');
}

void main() {
  testWidgets(
      'readouts stay visible with no pointer activity after a frame lands',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const _PreviewHost(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: _connectedCamera(),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // A frame lands. The pointer is never moved — exactly the state a sequence
    // runs in, and the only state a remote viewer on a screen share can be in.
    handle.container.read(currentImageProvider.notifier).state = _frame();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expectVisible(tester, find.byType(FrameInfoPill), 'frame info');

    // Well past any plausible idle-hide delay: the readouts do not self-hide.
    await tester.pump(const Duration(seconds: 6));
    expectVisible(tester, find.byType(FrameInfoPill), 'frame info');

    // Turning the readouts off is now an explicit, user-owned decision.
    handle.container.read(previewReadoutsVisibleProvider.notifier).state =
        false;
    await tester.pump();
    expect(find.byType(FrameInfoPill), findsNothing);
  });

  testWidgets('an in-flight exposure suppresses the empty-state prompt',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const _PreviewHost(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: _connectedCamera(),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // No image yet: the empty state is the right thing to show.
    expect(find.text('No frames yet'), findsOneWidget);
    expect(
      find.text('Take a snapshot or start a loop and the frame appears here.'),
      findsOneWidget,
    );

    // 32% into a 3 s exposure, with still no image to display.
    handle.container.read(exposureProgressProvider.notifier).state =
        const ExposureProgress(elapsed: 0.96, remaining: 2.04, percent: 0.32);
    await tester.pump();

    expect(
      find.text('No frames yet'),
      findsNothing,
      reason: 'the progress overlay owns the canvas while exposing',
    );
    expect(
      find.text('Take a snapshot or start a loop and the frame appears here.'),
      findsNothing,
      reason: 'must not prompt for a capture that is already running',
    );

    // Exposure over, no frame delivered: the prompt comes back.
    handle.container.read(exposureProgressProvider.notifier).state =
        const ExposureProgress(elapsed: 0, remaining: 0, percent: 0);
    await tester.pump();
    expect(find.text('No frames yet'), findsOneWidget);
  });

  group('the capture bar survives every compact layout', () {
    // Sizes drawn from the audit: the 800x620 window where the bar vanished
    // entirely, plus the phone-landscape sizes that take the same code path.
    for (final size in const [
      Size(800, 620),
      Size(760, 620),
      Size(932, 430),
      Size(905, 369),
      Size(430, 932),
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await pumpAppScreen(
            tester,
            const ImagingScreen(),
            size: size,
            settle: false,
            extraOverrides: _connectedCamera(),
          );
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }

          // Present AND laid out inside the viewport. Presence alone would
          // also be satisfied by a control scrolled or clipped off-screen,
          // which is no shutter at all. (hitTestable() is deliberately not
          // used: this harness's first-use catalog prompt raises a modal
          // barrier that blocks the hit test regardless of the layout.)
          for (final key in [
            ImagingTutorialKeys.snapshotBtn,
            ImagingTutorialKeys.loopBtn,
          ]) {
            final finder = find.byKey(key);
            expect(
              finder,
              findsOneWidget,
              reason: 'there must always be a way to start an exposure',
            );
            final rect = tester.getRect(finder);
            expect(rect.width, greaterThan(0));
            expect(rect.height, greaterThan(0));
            expect(
              rect.left >= 0 &&
                  rect.top >= 0 &&
                  rect.right <= size.width &&
                  rect.bottom <= size.height,
              isTrue,
              reason: '$key is off-screen at $size: $rect',
            );
          }
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });
}
