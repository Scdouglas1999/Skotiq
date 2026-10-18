// The live view's one frame-info pill: what the frame is, when it landed, HFR
// and stars, and the badges that qualify it — including the accept / reject
// verdict, which used to float in its own box in another corner.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_hud.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_preview_area.dart';
import 'package:skotiq_app/screens/imaging/widgets/sub_quality_badge.dart';
import 'package:skotiq_core/skotiq_core.dart';
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
  const _PreviewHost();

  @override
  Widget build(BuildContext context) {
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
}
