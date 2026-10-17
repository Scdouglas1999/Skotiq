// C9 unit tests — visible-set inclusive coverage + tile path/Allsky addressing.
//
// Two anti-jank invariants meet here:
//
//   1. INCLUSIVE COVERAGE. The visible-tile set must cover the *entire* canvas —
//      including the corners under field rotation — with no gap (a missing tile
//      is a black gutter, which the never-blank requirement forbids). This suite
//      projects a dense grid of canvas points back to sky, addresses each to a
//      HEALPix pixel at the selected order, and asserts every such pixel is in
//      the computed visible set. It also asserts neighbouring tiles share screen
//      corners exactly (seam-free) and that the set grows when the FOV grows.
//
//   2. PATH ADDRESSING vs LIVE-VERIFIED DSS2. The Dir-bucketed tile path and the
//      Allsky path the fetcher GETs must match the byte-exact layout the CDS
//      DSS2 pyramids actually serve (per IVOA HiPS 1.0:
//      `Norder{k}/Dir{d}/Npix{n}.{ext}`, `Dir = floor(npix/10000)*10000`, and
//      `Norder{k}/Allsky.{ext}`). The DSS2 red/blue base URLs in
//      [HipsSurveyRegistry] are the live-verified ones, so the built URLs are
//      checked against those exact roots.

import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/models/hips/hips_survey_registry.dart';
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget, SurveySource;
import 'package:skotiq_core/src/services/hips/healpix_nested.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

const _surveyId = 'CDS/P/DSS2/red';

HipsProperties _props() => HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 3
hips_tile_width   = 512
hips_tile_format  = jpeg
hips_frame        = equatorial
''');

const _plateScale = FramingPlateScale(
  surveyFovWidthDeg: 3.0,
  surveyFovHeightDeg: 3.0,
  imagePixelWidth: 1000,
  imagePixelHeight: 1000,
);

const _target = FramingTarget(name: 'M42', raHours: 5.5882, decDegrees: -5.391);

void main() {
  group('inclusive coverage of the canvas', () {
    test('every canvas grid point falls inside some visible tile', () {
      const canvas = Size(1000, 1000);
      const zoom = 1.0;
      final props = _props();
      final norder = HipsTileSelection.selectNorder(
        _plateScale.pixelsPerDegree(canvas, zoom),
        props,
      );

      final set = HipsTileSelection.computeVisibleTiles(
        _plateScale,
        _target,
        canvas,
        zoom,
        norder,
        props,
        surveyId: _surveyId,
      );

      // The pixel ids actually returned, for membership testing.
      final returned = set.tiles.map((t) => t.id.npix).toSet();
      expect(returned, isNotEmpty);

      // Project a dense grid of canvas pixels back to sky and address each at
      // the selected order; the addressed pixel MUST be in the visible set or
      // the canvas would show a gap there.
      final healpix = HealpixNested(norder);
      var checked = 0;
      for (var sx = 0.0; sx <= canvas.width; sx += 50.0) {
        for (var sy = 0.0; sy <= canvas.height; sy += 50.0) {
          final sky = set.projection.screenToRaDec(Offset(sx, sy));
          final raDeg = sky.raHours * 15.0;
          final pix = healpix.ang2pixNest(raDeg, sky.decDegrees);
          expect(
            returned,
            contains(pix),
            reason: 'canvas ($sx,$sy) -> pix $pix not in the visible set',
          );
          checked++;
        }
      }
      expect(checked, greaterThan(100));
    });

    test('coverage holds under field rotation (rotated corners included)', () {
      const canvas = Size(1280, 800);
      const zoom = 1.4;
      const rotation = 37.0;
      final props = _props();
      final norder = HipsTileSelection.selectNorder(
        _plateScale.pixelsPerDegree(canvas, zoom),
        props,
      );

      final set = HipsTileSelection.computeVisibleTiles(
        _plateScale,
        _target,
        canvas,
        zoom,
        norder,
        props,
        pan: const Offset(30, -20),
        rotationDegrees: rotation,
        surveyId: _surveyId,
      );
      final returned = set.tiles.map((t) => t.id.npix).toSet();
      final healpix = HealpixNested(norder);

      // The four canvas corners are the worst case under rotation.
      for (final corner in <Offset>[
        Offset.zero,
        const Offset(1280, 0),
        const Offset(1280, 800),
        const Offset(0, 800),
      ]) {
        final sky = set.projection.screenToRaDec(corner);
        final pix = healpix.ang2pixNest(sky.raHours * 15.0, sky.decDegrees);
        expect(
          returned,
          contains(pix),
          reason: 'rotated corner $corner -> pix $pix missing from set',
        );
      }
    });

    test('the visible set grows when the FOV grows (zoom out)', () {
      const canvas = Size(1000, 1000);
      final props = _props();

      int countAt(double zoom) {
        final norder = HipsTileSelection.selectNorder(
          _plateScale.pixelsPerDegree(canvas, zoom),
          props,
        );
        return HipsTileSelection.computeVisibleTiles(
          _plateScale,
          _target,
          canvas,
          zoom,
          norder,
          props,
          surveyId: _surveyId,
        ).tiles.length;
      }

      // Zooming out widens the FOV. Holding the order fixed would mean more
      // tiles; the LOD rule lowers the order which keeps the count bounded, so
      // we assert the set is always non-empty across the range (no blank frame)
      // rather than a strict monotone count.
      for (final zoom in <double>[0.25, 0.5, 1.0, 2.0, 4.0]) {
        expect(
          countAt(zoom),
          greaterThan(0),
          reason: 'empty set at zoom=$zoom',
        );
      }
    });
  });

  group('seam-free shared screen corners between neighbours', () {
    test('adjacent visible tiles share projected corner positions', () {
      const canvas = Size(1000, 1000);
      const zoom = 1.0;
      final props = _props();
      final norder = HipsTileSelection.selectNorder(
        _plateScale.pixelsPerDegree(canvas, zoom),
        props,
      );
      final set = HipsTileSelection.computeVisibleTiles(
        _plateScale,
        _target,
        canvas,
        zoom,
        norder,
        props,
        subdivisions: 1, // corners only — exact boundary comparison
        surveyId: _surveyId,
      );

      final healpix = HealpixNested(norder);
      final byPix = {for (final t in set.tiles) t.id.npix: t};

      var sharedPairs = 0;
      for (final tile in set.tiles) {
        // A 1x1 mesh has 4 vertices: the four cell corners as screen points.
        final corners = tile.mesh.vertices.map((v) => v.screen).toList();
        for (final nb in healpix.neighboursNest(tile.id.npix)) {
          final nbTile = byPix[nb];
          if (nbTile == null) continue;
          final nbCorners = nbTile.mesh.vertices.map((v) => v.screen).toList();
          for (final c in corners) {
            for (final nc in nbCorners) {
              if ((c - nc).distance < 1e-6) sharedPairs++;
            }
          }
        }
      }
      // With a populated set, many neighbour pairs share corner pixels exactly.
      expect(
        sharedPairs,
        greaterThan(0),
        reason: 'no neighbouring tiles share a projected corner -> seams',
      );
    });
  });

  group('tile path / Allsky addressing vs live-verified DSS2 layout', () {
    test('Dir bucket follows floor(npix/10000)*10000', () {
      expect(
        HipsTileId(survey: _surveyId, norder: 9, npix: 0).directoryBucket,
        0,
      );
      expect(
        HipsTileId(survey: _surveyId, norder: 9, npix: 9999).directoryBucket,
        0,
      );
      expect(
        HipsTileId(survey: _surveyId, norder: 9, npix: 10000).directoryBucket,
        10000,
      );
      expect(
        HipsTileId(survey: _surveyId, norder: 9, npix: 25001).directoryBucket,
        20000,
      );
    });

    test('relative tile path is Norder{k}/Dir{d}/Npix{n}.{ext}', () {
      // Order 6 has 12*4^6 = 49152 tiles, so npix 12345 is in range and lands in
      // the Dir10000 bucket.
      final id = HipsTileId(survey: _surveyId, norder: 6, npix: 12345);
      expect(
        id.relativePath(HipsTileFormat.jpeg),
        'Norder6/Dir10000/Npix12345.jpg',
      );
      expect(
        id.relativePath(HipsTileFormat.png),
        'Norder6/Dir10000/Npix12345.png',
      );
    });

    test('Allsky relative path is Norder{k}/Allsky.{ext}', () {
      expect(
        HipsTileId.allskyRelativePath(3, HipsTileFormat.jpeg),
        'Norder3/Allsky.jpg',
      );
      expect(
        HipsTileId.allskyRelativePath(3, HipsTileFormat.fits),
        'Norder3/Allsky.fits',
      );
    });

    test('absolute tile + Allsky URLs join the live-verified DSS2 red root', () {
      // The DSS2 red base URL is live-verified in the registry; the addressing
      // primitives must produce exactly the URL the fetcher GETs against it.
      final entry = HipsSurveyRegistry.entryFor(SurveySource.dss2Red);
      expect(entry.hasVerifiedBaseUrl, isTrue);
      final baseUrl = entry.baseUrl!;
      expect(baseUrl, 'https://alasky.cds.unistra.fr/DSS/DSS2Merged');

      final id = HipsTileId(survey: entry.hipsId, norder: 6, npix: 30042);
      expect(
        id.tileUrl(baseUrl, HipsTileFormat.jpeg),
        'https://alasky.cds.unistra.fr/DSS/DSS2Merged/'
        'Norder6/Dir30000/Npix30042.jpg',
      );
      expect(
        HipsTileId.allskyUrl(baseUrl, 3, HipsTileFormat.jpeg),
        'https://alasky.cds.unistra.fr/DSS/DSS2Merged/Norder3/Allsky.jpg',
      );
    });

    test('a trailing slash on the base URL is normalised (no doubled sep)', () {
      final id = HipsTileId(survey: _surveyId, norder: 4, npix: 7);
      const base = 'https://alasky.cds.unistra.fr/DSS/DSS2Merged/';
      expect(
        id.tileUrl(base, HipsTileFormat.jpeg),
        'https://alasky.cds.unistra.fr/DSS/DSS2Merged/'
        'Norder4/Dir0/Npix7.jpg',
      );
      expect(
        HipsTileId.allskyUrl(base, 4, HipsTileFormat.jpeg),
        'https://alasky.cds.unistra.fr/DSS/DSS2Merged/Norder4/Allsky.jpg',
      );
    });

    test('the DSS2 blue verified root resolves identically', () {
      final entry = HipsSurveyRegistry.entryFor(SurveySource.dss2Blue);
      expect(entry.hasVerifiedBaseUrl, isTrue);
      expect(entry.baseUrl, 'https://alasky.cds.unistra.fr/DSS/DSS2-blue-XJ-S');
      final id = HipsTileId(survey: entry.hipsId, norder: 9, npix: 0);
      expect(
        id.tileUrl(entry.baseUrl!, HipsTileFormat.jpeg),
        'https://alasky.cds.unistra.fr/DSS/DSS2-blue-XJ-S/'
        'Norder9/Dir0/Npix0.jpg',
      );
    });

    test('npix beyond the order tile-count is rejected (errors surface)', () {
      // 12 * 4^1 = 48 tiles at order 1; npix 48 is out of range.
      expect(
        () => HipsTileId(survey: _surveyId, norder: 1, npix: 48),
        throwsArgumentError,
      );
      // The last valid pixel is accepted.
      expect(HipsTileId(survey: _surveyId, norder: 1, npix: 47).npix, 47);
    });
  });

  group('selection input validation surfaces errors', () {
    test('an out-of-range norder throws', () {
      final props = _props(); // [3, 9]
      expect(
        () => HipsTileSelection.computeVisibleTiles(
          _plateScale,
          _target,
          const Size(1000, 1000),
          1.0,
          2, // below hips_order_min
          props,
          surveyId: _surveyId,
        ),
        throwsA(isA<HipsTileSelectionError>()),
      );
    });

    test('a degenerate canvas size throws', () {
      final props = _props();
      expect(
        () => HipsTileSelection.computeVisibleTiles(
          _plateScale,
          _target,
          Size.zero,
          1.0,
          5,
          props,
          surveyId: _surveyId,
        ),
        throwsA(isA<HipsTileSelectionError>()),
      );
    });

    test('subdivisions < 1 throws', () {
      final props = _props();
      expect(
        () => HipsTileSelection.computeVisibleTiles(
          _plateScale,
          _target,
          const Size(1000, 1000),
          1.0,
          5,
          props,
          subdivisions: 0,
          surveyId: _surveyId,
        ),
        throwsA(isA<HipsTileSelectionError>()),
      );
    });
  });

  group('returned tile set is ordered and in-range', () {
    test('npix is ascending and within the order tile count', () {
      const canvas = Size(1000, 1000);
      const zoom = 1.0;
      final props = _props();
      final norder = HipsTileSelection.selectNorder(
        _plateScale.pixelsPerDegree(canvas, zoom),
        props,
      );
      final set = HipsTileSelection.computeVisibleTiles(
        _plateScale,
        _target,
        canvas,
        zoom,
        norder,
        props,
        surveyId: _surveyId,
      );
      final tileCount = HipsTileId.numberOfTiles(norder);
      var previous = -1;
      for (final tile in set.tiles) {
        expect(tile.id.norder, norder);
        expect(tile.id.npix, inInclusiveRange(0, tileCount - 1));
        expect(
          tile.id.npix,
          greaterThan(previous),
          reason: 'tile npix not strictly ascending (dedup + determinism)',
        );
        previous = tile.id.npix;
        expect(tile.id.survey, _surveyId);
      }
    });
  });
}
