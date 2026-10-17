// A newly created region must not open on a blank rectangle.
//
// A free 3:2 AspectRatio for the hero cutout renders ~1030px tall on a 1600x900
// desktop window — taller than the viewport — so everything that says anything
// (the coordinates, "Contributing frames", the deepening chart) sits below the
// fold and the screen is flat background with one small grey glyph and no words.
// The parent Your Sky screen handles the same state with a sentence and a next
// step.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/your_sky/region_detail_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _regionId = 42;

SkyAtlasRegionRow _region() => SkyAtlasRegionRow(
      id: _regionId,
      name: 'Ring Region',
      kind: 'ring',
      centerRaDeg: 283.4,
      centerDecDeg: 33.03,
      radiusDeg: 0.50,
      tileCount: 0,
      integrationSeconds: 0,
      createdAt: DateTime.utc(2026, 8, 2),
    );

Widget _surface() {
  return ProviderScope(
    overrides: [
      atlasRegionProvider(_regionId).overrideWith((ref) async => _region()),
      atlasRegionTilesProvider(_regionId).overrideWith((ref) async => const []),
      atlasRegionTimelineProvider(_regionId)
          .overrideWith((ref) => Stream.value(const <SkyAtlasFoldRow>[])),
      atlasRegionGrowthProvider(_regionId)
          .overrideWith((ref) async => AtlasGrowthCurve.empty),
      atlasRegionProvenanceProvider(_regionId)
          .overrideWith((ref) async => null),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const RegionDetailScreen(regionId: _regionId),
    ),
  );
}

void main() {
  testWidgets(
      'an empty region says so inside the preview, and its facts stay '
      'on a 1600x900 screen', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_surface());
    await tester.pumpAndSettle();

    // The empty state is words, in the preview, not a mute glyph.
    expect(find.text('Nothing imaged here yet'), findsOneWidget);
    expect(
      find.text(
        'Point a session at this patch of sky and its frames fold in here.',
      ),
      findsOneWidget,
    );

    // The preview no longer eats the viewport: the coordinate line under it is
    // near the top of the window, not a screen and a half down.
    final coordinates = find.textContaining('r 0.50°');
    expect(coordinates, findsOneWidget);
    expect(
      tester.getTopLeft(coordinates).dy,
      lessThan(430),
      reason: 'the capped preview must leave the coordinates high on screen',
    );

    // And the informative sections below it are reachable without scrolling.
    final contributing = find.text('Contributing frames');
    expect(contributing, findsOneWidget);
    expect(
      tester.getTopLeft(contributing).dy,
      lessThan(900),
      reason: 'contributing frames must be visible without scrolling',
    );
  });

  // The same fix claimed a second, untested effect: capping the hero narrowed
  // the growth card's empty placeholder into its own column, which a FIXED
  // 170px chart box clipped. Pump the whole screen at phone width and scroll it
  // end to end — an overflowing RenderFlex raises through FlutterError and
  // fails the test, so this pins the ConstrainedBox(minHeight) as well as the
  // hero cap on the layout that actually binds.
  testWidgets('the empty region detail lays out at 360dp without overflow',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_surface());
    await tester.pumpAndSettle();

    expect(find.text('Nothing imaged here yet'), findsOneWidget);
    // The cap must not bind on a phone: 360 * 2/3 is well under it, so the
    // preview keeps its proportions rather than becoming a letterbox.
    final preview = tester.getSize(
      find
          .ancestor(
            of: find.text('Nothing imaged here yet'),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(preview.height, lessThan(320));

    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(
        find.text('Image this region again to see it deepen'), findsOneWidget);
  });
}
