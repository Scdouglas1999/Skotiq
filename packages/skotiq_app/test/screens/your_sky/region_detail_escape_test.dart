// Escape must back out of the Your Sky region detail.
//
// The region detail is a full-screen route that hides the Plan Tonight tab bar,
// so without it the only exit is a 40 px arrow in the corner — the same shape
// the fullscreen image viewer handles.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const RegionDetailScreen(regionId: _regionId),
                ),
              ),
              child: const Text('open region'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('Escape backs out of the region detail route', (tester) async {
    await tester.pumpWidget(_surface());
    await tester.pumpAndSettle();

    await tester.tap(find.text('open region'));
    await tester.pumpAndSettle();
    expect(find.text('Ring Region'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Ring Region'), findsNothing);
    expect(find.text('open region'), findsOneWidget);
  });
}
