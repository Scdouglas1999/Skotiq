// The deep tier hands off at a magnitude the bundled catalog actually reaches.
//
// At an imaging FOV the chart renders essentially empty — a measured 3-5
// stars/sq deg against the 100-200 a real Lyra field carries to mag 12 — and
// the reason is the catalog. Counting the installed HYG file: 119,626 rows,
// 83,124 at mag <= 9, 107,938 at <= 10, 117,914 at <= 12, with the per-bin gain
// turning over after mag 9 (41,975 stars in 8-9, 24,814 in 9-10, 7,580 in
// 10-11). It is complete to about 9. A `kHygFaintFloorMag` of 11.5 tells the
// deep tier — the one thing that can fill that field — to drop everything
// brighter than 11.5, so a user who installs a Tycho-2-depth tileset (complete
// to ~11) throws away nearly all of it and keeps the empty field the tileset
// was installed to fix.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Records the seam the provider asks for and answers with a fixed star list
/// filtered exactly the way [DeepStarTileStore] filters it.
class _RecordingStore extends DeepStarTileStore {
  _RecordingStore(this.stars) : super(directory: '/does/not/exist');

  final List<Star> stars;
  double? lastMinMagnitude;
  double? lastMaxMagnitude;

  @override
  Future<List<Star>> queryBrightest(
    double centerRaHours,
    double centerDecDeg,
    double fovDegrees, {
    required double maxMagnitude,
    required int maxResults,
    double minMagnitude = double.negativeInfinity,
    double aspectRatio = 1.0,
  }) async {
    lastMinMagnitude = minMagnitude;
    lastMaxMagnitude = maxMagnitude;
    return stars
        .where((s) => (s.magnitude ?? 99) > minMagnitude)
        .where((s) => (s.magnitude ?? 99) <= maxMagnitude)
        .toList();
  }
}

Star _star(String id, double mag) => Star(
  id: id,
  name: id,
  coordinates: const CelestialCoordinate(ra: 18.9, dec: 33.0),
  magnitude: mag,
);

DeepStarManifest _manifest({required double magnitudeFloor}) =>
    DeepStarManifest(
      name: 'test-tycho',
      source: 'test',
      magnitudeFloor: magnitudeFloor,
      magnitudeLimit: 12.0,
      tiles: const [],
    );

Future<(List<Star>, _RecordingStore)> _query({
  required double magnitudeFloor,
  required List<Star> stars,
}) => _queryWith(
  manifest: _manifest(magnitudeFloor: magnitudeFloor),
  stars: stars,
);

Future<(List<Star>, _RecordingStore)> _queryWith({
  required DeepStarManifest manifest,
  required List<Star> stars,
}) async {
  final store = _RecordingStore(stars);
  final container = ProviderContainer(
    overrides: [
      showDeepStarsProvider.overrideWith((ref) => true),
      deepStarStoreProvider.overrideWithValue(store),
      deepStarManifestProvider.overrideWith(
        (ref) => Future<DeepStarManifest?>.value(manifest),
      ),
    ],
  );
  addTearDown(container.dispose);

  // Imaging scale: below kDeepStarFovThresholdDegrees so the tier engages.
  container.read(skyViewStateProvider.notifier).setFieldOfView(1.2);

  final result = await container.read(deepStarsInViewProvider.future);
  return (result, store);
}

void main() {
  test('the hand-off seam matches what the bundled catalog actually holds', () {
    expect(
      kHygFaintFloorMag,
      lessThanOrEqualTo(9.0),
      reason:
          'HYG is complete to about magnitude 9; a deeper claim '
          'silently deletes the tier that covers the gap',
    );
  });

  test(
    'a tileset built to a bright floor is not truncated to the constant',
    () async {
      final (stars, store) = await _query(
        magnitudeFloor: 8.0,
        stars: [
          _star('deep-9.5', 9.5),
          _star('deep-10.4', 10.4),
          _star('deep-11.2', 11.2),
        ],
      );

      expect(
        store.lastMinMagnitude,
        kHygFaintFloorMag,
        reason:
            'a tileset holding stars from mag 8 down must be asked for '
            'everything past HYG\'s real depth, not past 11.5',
      );
      expect(
        stars.map((s) => s.id),
        containsAll(<String>['deep-9.5', 'deep-10.4', 'deep-11.2']),
        reason:
            'these are exactly the stars that were missing from a 1 deg '
            'field, and exactly the ones the old seam discarded',
      );
    },
  );

  test(
    'a manifest with no declared floor does not re-open the mag 9-11.5 hole',
    () async {
      // The parser's fallback is the last place the retired 11.5 survived, and
      // the seam takes max(kHygFaintFloorMag, floor) — so a manifest missing the
      // field made the tier drop exactly the stars HYG has none of.
      final manifest = DeepStarManifest.fromJson(<String, Object?>{
        'format': DeepStarManifest.formatName,
        'formatVersion': DeepStarTile.formatVersion,
        'name': 'test-tycho',
        'source': 'test',
        'magnitudeLimit': 12.0,
        'tiles': <Object?>[],
      });

      expect(manifest.magnitudeFloor, kHygFaintFloorMag);

      final (stars, store) = await _queryWith(
        manifest: manifest,
        stars: [
          _star('deep-9.5', 9.5),
          _star('deep-10.4', 10.4),
          _star('deep-11.2', 11.2),
        ],
      );

      expect(store.lastMinMagnitude, kHygFaintFloorMag);
      expect(
        stars.map((s) => s.id),
        containsAll(<String>['deep-9.5', 'deep-10.4', 'deep-11.2']),
      );
    },
  );

  test('a tileset that starts fainter keeps its own floor', () async {
    final (_, store) = await _query(
      magnitudeFloor: 11.5,
      stars: [_star('deep-12', 12.0)],
    );

    expect(
      store.lastMinMagnitude,
      11.5,
      reason:
          'the seam is the fainter of the two: asking below a tileset\'s '
          'own bright cutoff cannot conjure stars it does not contain, but '
          'asking above it would double-draw the HYG tier',
    );
  });
}
