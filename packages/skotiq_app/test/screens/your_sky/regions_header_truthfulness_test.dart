// The Regions header must say what it counts.
//
// On a fresh profile with no captures, naming a region (Your Sky > Name a region
// > Custom RA/Dec) must not make the header read "1 region imaged" — directly
// above that region's own card reading "0s / 0 tiles", and directly below an
// Atlas coverage strip reading 0s integration / 0 tiles / 0 frames, with
// sky_atlas_regions = 1, sky_tiles = 0, captured_images = 0 in the database.
// Naming a patch of sky is not imaging it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/your_sky/your_sky_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

SkyAtlasRegionRow _region({
  required int id,
  required String name,
  required int tileCount,
  double integrationSeconds = 0,
}) {
  return SkyAtlasRegionRow(
    id: id,
    name: name,
    kind: 'custom',
    centerRaDeg: 283.4,
    centerDecDeg: 33.03,
    radiusDeg: 0.5,
    tileCount: tileCount,
    integrationSeconds: integrationSeconds,
    createdAt: DateTime.utc(2026, 8, 3),
  );
}

Widget _surface(List<SkyAtlasRegionRow> regions) {
  return ProviderScope(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, _MockNetworkBackend()),
      ),
      skyAtlasRegionsProvider.overrideWith((ref) => Stream.value(regions)),
      skyAtlasCoverageProvider.overrideWith(
        (ref) => Stream.value(const <AtlasTileCoverage>[]),
      ),
    ],
    child: const MaterialApp(home: YourSkyScreen()),
  );
}

void main() {
  testWidgets('a named region with no tiles is not called imaged',
      (tester) async {
    await tester.pumpWidget(
      _surface([_region(id: 1, name: 'Ring Region', tileCount: 0)]),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 region imaged'), findsNothing);
    expect(find.text('1 region · none imaged yet'), findsOneWidget);
  });

  testWidgets('regions that really carry tiles are counted as imaged',
      (tester) async {
    await tester.pumpWidget(
      _surface([
        _region(
            id: 1, name: 'Ring Region', tileCount: 4, integrationSeconds: 1800),
        _region(id: 2, name: 'Veil', tileCount: 9, integrationSeconds: 3600),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 regions imaged'), findsOneWidget);
  });

  testWidgets('a mixed atlas reports how many are actually imaged',
      (tester) async {
    await tester.pumpWidget(
      _surface([
        _region(id: 1, name: 'Ring Region', tileCount: 0),
        _region(id: 2, name: 'Veil', tileCount: 9, integrationSeconds: 3600),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 regions · 1 imaged'), findsOneWidget);
  });
}
