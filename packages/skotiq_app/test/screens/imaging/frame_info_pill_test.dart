// The live view's one frame-info pill: what the frame is, when it landed, HFR
// and stars, and the badges that qualify it — including the accept / reject
// verdict, which used to float in its own box in another corner.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_hud.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_preview_area.dart';
import 'package:skotiq_app/screens/imaging/widgets/sub_quality_badge.dart';
import 'package:skotiq_app/widgets/image_preview/overlay_painters.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

CapturedImageData _frame({
  ImageStats stats = const ImageStats(
    hfr: 2,
    eccentricity: 0.25,
    starCount: 12,
    mean: 100,
    median: 90,
  ),
  ExposureSettings settings =
      const ExposureSettings(exposureTime: 1, gain: 0, offset: 0),
}) =>
    CapturedImageData(
      width: 64,
      height: 48,
      displayData: Uint8List(64 * 48 * 4),
      histogram: const [],
      stats: stats,
      capturedAt: DateTime(2026, 10, 17, 21, 24, 16),
      settings: settings,
    );

class _FakeScienceNotifier extends ScienceSettingsNotifier {
  _FakeScienceNotifier(this._settings);

  final ScienceSettings _settings;

  @override
  Future<ScienceSettings> build() async => _settings;
}

class _PreviewHost extends StatelessWidget {
  const _PreviewHost({this.showStarOverlay = false});

  final bool showStarOverlay;

  @override
  Widget build(BuildContext context) {
    return LivePreviewArea(
      colors: context.skotiqColors,
      zoomLevel: 1.0,
      panOffset: Offset.zero,
      showCrosshair: false,
      showStarOverlay: showStarOverlay,
      isStoppingCapture: false,
      onZoomIn: () {},
      onZoomOut: () {},
      onPanUpdate: (_) {},
    );
  }
}

String _tooltipOf(WidgetTester tester) => tester
    .widget<SkotiqTooltip>(
      find.descendant(
        of: find.byType(FrameInfoPill),
        matching: find.byType(SkotiqTooltip),
      ),
    )
    .message;

void main() {
  testWidgets(
      'the pill clears stale stats without an image and follows the '
      'displayed frame', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(lastImageStatsProvider.notifier).state =
        const ImageStats(hfr: 9, eccentricity: 0.99);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: FrameInfoPill(eccentricity: 0.11)),
      ),
    ));
    expect(find.byType(Glass), findsNothing,
        reason: 'no frame on screen, nothing over the canvas');

    container.read(currentImageProvider.notifier).state = _frame();
    await tester.pump();

    expect(find.text('Light · 1.0 s'), findsOneWidget);
    expect(find.text('21:24:16'), findsOneWidget);
    expect(find.text('HFR 2.00'), findsOneWidget);
    expect(find.text('12 stars'), findsOneWidget);
    expect(find.textContaining('9.00'), findsNothing);
    // The secondary numbers are one hover away, from the frame on screen.
    final detail = _tooltipOf(tester);
    expect(detail, contains('Eccentricity 0.25'));
    expect(detail, contains('Median 90'));
    expect(detail, contains('Mean 100'));
    expect(detail, isNot(contains('0.99')));
  });

  testWidgets('a value the frame did not measure is left out, not dashed',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentImageProvider.notifier).state =
        _frame(stats: const ImageStats(mean: 100));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: FrameInfoPill(eccentricity: null)),
      ),
    ));

    expect(find.textContaining('HFR'), findsNothing);
    expect(find.textContaining('stars'), findsNothing);
    expect(find.text('—'), findsNothing);
  });

  test('the identity leads with the filter for a filtered light frame', () {
    expect(
      FrameInfoPill.frameIdentity(
        const ExposureSettings(
            exposureTime: 180, gain: 0, offset: 0, filter: 'Ha'),
      ),
      'Ha · 180.0 s',
    );
    expect(
      FrameInfoPill.frameIdentity(
        const ExposureSettings(
          exposureTime: 300,
          gain: 0,
          offset: 0,
          filter: 'L',
          frameType: FrameType.dark,
        ),
      ),
      'Dark · 300.0 s',
    );
    expect(
      FrameInfoPill.frameIdentity(
        const ExposureSettings(exposureTime: 0.5, gain: 0, offset: 0),
      ),
      'Light · 0.50 s',
    );
    expect(
      FrameInfoPill.frameIdentity(
        const ExposureSettings(
          exposureTime: 0.00224,
          gain: 0,
          offset: 0,
          filter: 'R',
          frameType: FrameType.flat,
        ),
      ),
      'Flat · 2.2 ms',
    );
  });

  testWidgets(
      'the canvas carries one pill with the verdict inside it, and no '
      'floating verdict box', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const _PreviewHost(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: <Override>[
        scienceSettingsProvider.overrideWith(
          () => _FakeScienceNotifier(
            const ScienceSettings(autoFrameGradingEnabled: true),
          ),
        ),
      ],
    );
    // HFR 16 is far above the conservative maxHfr, so the frame is rejected.
    const stats = ImageStats(hfr: 16.29, starCount: 105, mean: 534);
    handle.container.read(lastImageStatsProvider.notifier).state = stats;
    handle.container.read(currentImageProvider.notifier).state =
        _frame(stats: stats);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(FrameInfoPill), findsOneWidget);
    expect(find.byType(SubQualityBadge), findsNothing);
    expect(
      find.descendant(
        of: find.byType(FrameInfoPill),
        matching: find.text('REJECT'),
      ),
      findsOneWidget,
    );
    expect(find.text('REJECT'), findsOneWidget);

    // The pill sits in the top-left corner of the canvas.
    final pill = tester.getTopLeft(find.byType(FrameInfoPill));
    final canvas = tester.getTopLeft(find.byType(LivePreviewArea));
    expect(pill.dx - canvas.dx, lessThan(40));
    expect(pill.dy - canvas.dy, lessThan(40));
  });

  // The rig on 2026-11-15 at 23:31: the end-of-night calibration's dark read
  // "Dark · 3.0 s ... 4 stars · REJECT", graded as if it were a light.
  testWidgets('a calibration frame carries no accept or reject verdict',
      (tester) async {
    await pumpAppScreen(
      tester,
      const _PreviewHost(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: <Override>[
        scienceSettingsProvider.overrideWith(
          () => _FakeScienceNotifier(
            const ScienceSettings(autoFrameGradingEnabled: true),
          ),
        ),
      ],
    ).then((handle) async {
      const stats = ImageStats(hfr: 2.77, starCount: 4, mean: 300);
      handle.container.read(lastImageStatsProvider.notifier).state = stats;
      handle.container.read(currentImageProvider.notifier).state = _frame(
        stats: stats,
        settings: const ExposureSettings(
          exposureTime: 3,
          gain: 0,
          offset: 0,
          frameType: FrameType.dark,
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    });

    expect(find.text('Dark · 3.0 s'), findsOneWidget);
    expect(find.text('REJECT'), findsNothing);
    expect(find.text('ACCEPT'), findsNothing);
  });

  // The rig on 2026-11-15 at 23:31: about 150 star markers of an earlier
  // light were drawn over a dark while the dark's own detection had not
  // given an answer.
  testWidgets('the star overlay never draws the previous frame\'s stars',
      (tester) async {
    final pending = Completer<StarDetectionResult>();
    final handle = await pumpAppScreen(
      tester,
      const _PreviewHost(showStarOverlay: true),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: <Override>[
        frameStarDetectorProvider.overrideWithValue(
          (path) => path == '/frames/light.fits'
              ? Future.value(const StarDetectionResult(
                  stars: [
                    DetectedStar(
                      x: 10,
                      y: 10,
                      flux: 1000,
                      hfr: 2,
                      fwhm: 4,
                      peak: 900,
                      background: 100,
                      snr: 50,
                    ),
                  ],
                  starCount: 1,
                  medianHfr: 2,
                  medianFwhm: 4,
                  medianSnr: 50,
                  background: 100,
                  noise: 5,
                ))
              : pending.future,
        ),
      ],
    );
    Iterable<CustomPaint> starPaints() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((paint) => paint.painter is StarOverlayPainter);

    handle.container.read(currentImageProvider.notifier).state =
        _frame().copyWith(filePath: '/frames/light.fits');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(starPaints(), hasLength(1), reason: 'the light shows its stars');

    handle.container.read(currentImageProvider.notifier).state = _frame(
      settings: const ExposureSettings(
        exposureTime: 3,
        gain: 0,
        offset: 0,
        frameType: FrameType.dark,
      ),
    ).copyWith(filePath: '/frames/dark.fits');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(starPaints(), isEmpty);
  });
}
