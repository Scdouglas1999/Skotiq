// Canonical in-Dart description of the committed real-HiPS framing test
// fixtures (component C-FIX).
//
// This is the single, load-bearing entry point an offline test imports to drive
// the framing GPU/HiPS tile layer against *real* DSS2-colour survey imagery
// without any network access. It answers, in pure Dart:
//
//   * which sky field the fixtures cover ([fieldRaDeg]/[fieldDecDeg], [fieldName]);
//   * the plate scale the committed tile set was computed for ([fixturePlateScale]);
//   * the survey identity + addressing the loader/selection code needs
//     ([surveyHipsId], [surveyBaseUrl], [surveyTileFormat], [allskyOrder], the
//     order range);
//   * the EXACT set of [HipsTileId]s on disk, per Norder, with their roles in the
//     level-of-detail chain ([primaryTiles], [parentFallbackTiles],
//     [grandparentFallbackTiles], [allTiles]);
//   * where each fixture file lives on disk ([fixtureRootDir], [tilePathFor],
//     [allskyPath], [propertiesPath]) and the committed integrity manifest
//     ([manifestPath]).
//
// The values here are NOT hand-authored guesses: the field, plate scale and
// per-order npix lists are the exact inputs/outputs of the production
// `HipsTileSelection.computeVisibleTiles` for this field (see
// `tools/hips_fixtures/fetch_hips_fixtures.dart`, the source-of-record that
// fetched the bytes, and `README.md` for provenance + DSS/STScI attribution).
// `tiles_manifest.json` carries the per-file sha256 + byte sizes so a test can
// assert the committed bytes are exactly the ones this descriptor promises.
//
// As a LIBRARY this is pure Dart + `dart:io` path resolution + the core
// `HipsTileId` value type; importing it (which is all the golden/render-verify
// tests do) pulls in no Flutter widget layer and touches no network. Resolving
// the fixture directory from a set of well-known candidate roots (handled by
// [fixtureRootDir]) means tests work regardless of the current working
// directory.
//
// Run DIRECTLY as a test (`flutter test test/fixtures/hips/fixture_field.dart`),
// its [main] is a self-validating fixture-integrity + real-data render-verify
// suite: it checks every committed file against `tiles_manifest.json`
// (sha256 + byte length), parses the real `properties` through the C0
// `HipsProperties.parse`, asserts the descriptor's npix lists are byte-identical
// to the production `HipsTileSelection.computeVisibleTiles` output for the field,
// decodes every committed tile + the Allsky into real `ui.Image`s via the
// production `ui.decodeImageFromList` path, composites them through the real
// `HipsTileLayerPainter`, and writes a human-inspectable mosaic PNG under
// `<repo>/.hips_verify/` (printing its absolute path) plus a byte-locked golden.
// The Flutter-test imports below are only reached when the file is executed as a
// test entrypoint.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/painters/hips_tile_layer_painter.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget;
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

/// Human-readable name of the fixture field.
const String fieldName = 'M31 (Andromeda Galaxy)';

/// Fixture field centre right ascension, in degrees (ICRS/J2000).
const double fieldRaDeg = 10.6847;

/// Fixture field centre declination, in degrees (ICRS/J2000).
const double fieldDecDeg = 41.2687;

/// Fixture field centre right ascension, in hours (`fieldRaDeg / 15`).
const double fieldRaHours = fieldRaDeg / 15.0;

/// Canonical CDS HiPS id of the committed survey (DSS2 colour) — identical to
/// the id the framing survey-image cutout path uses, so the tile layer streams
/// the same survey content.
const String surveyHipsId = 'CDS/P/DSS2/color';

/// Direct tile-pyramid base URL the committed bytes were fetched from. Tests run
/// fully offline; this is recorded for provenance and for a live-refresh via the
/// fetch tool, never contacted by the tests themselves.
const String surveyBaseUrl = 'https://alasky.cds.unistra.fr/DSS/DSSColor';

/// Tile edge length in pixels of the committed JPEG tiles (`hips_tile_width`).
const int surveyTileWidth = 512;

/// The committed tile encoding for this survey (DSS2 colour publishes JPEG).
const HipsTileFormat surveyTileFormat = HipsTileFormat.jpeg;

/// Maximum Norder the survey publishes (`hips_order`).
const int surveyHipsOrder = 9;

/// Minimum Norder the survey publishes (`hips_order_min`).
const int surveyHipsOrderMin = 0;

/// The Norder the committed [allskyPath] whole-sky preview is at. CDS DSS
/// surveys publish their Allsky only at order 3 (404 at 0..2), so this is the
/// coarsest never-blank base-layer fallback the fixture provides.
const int allskyOrder = 3;

/// The angular field of view, in degrees, of the plate scale the committed tile
/// set was computed for (width).
const double fixtureFovWidthDeg = 3.0;

/// The angular field of view, in degrees, of the plate scale the committed tile
/// set was computed for (height).
const double fixtureFovHeightDeg = 2.0;

/// The survey-image pixel width of the plate scale the tile set was computed
/// for (the synthetic cutout dimensions used to derive px/deg).
const int fixturePixelWidth = 900;

/// The survey-image pixel height of the plate scale the tile set was computed
/// for.
const int fixturePixelHeight = 600;

/// The Norder of the sharp, current-LOD primary tiles at the golden zoom (1.0)
/// over the fixture field.
const int primaryNorder = 6;

/// The Norder of the one-step-up parent fallback tiles.
const int parentNorder = 5;

/// The Norder of the two-step-up grandparent fallback tiles.
const int grandparentNorder = 4;

/// NESTED npix of the committed primary (Norder6) tiles, ascending. This is the
/// exact `HipsTileSelection.computeVisibleTiles` output for the field at golden
/// zoom — the full, gap-free mosaic footprint (every tile is in Dir0).
const List<int> primaryNpix = <int>[
  2614, 2615, 2617, 2619, 2620, 2621, 2622, 2623, //
  2658, 2659, 2664, 2665, 2666, 2667, //
  2704, 2705, 2706, 2707, 2708, 2709, 2710, 2711, 2713, 2716, 2717, //
  2752, 2753, 2754, //
];

/// NESTED npix of the committed parent-fallback (Norder5) tiles, ascending.
const List<int> parentNpix = <int>[
  653, 654, 655, 664, 666, 676, 677, 678, 679, 688, //
];

/// NESTED npix of the committed grandparent-fallback (Norder4) tiles, ascending.
const List<int> grandparentNpix = <int>[163, 166, 169, 172];

/// The committed primary (Norder6) tile ids, keyed to [surveyHipsId].
final List<HipsTileId> primaryTiles = List<HipsTileId>.unmodifiable(
  primaryNpix.map(
    (npix) =>
        HipsTileId(survey: surveyHipsId, norder: primaryNorder, npix: npix),
  ),
);

/// The committed parent-fallback (Norder5) tile ids, keyed to [surveyHipsId].
final List<HipsTileId> parentFallbackTiles = List<HipsTileId>.unmodifiable(
  parentNpix.map(
    (npix) =>
        HipsTileId(survey: surveyHipsId, norder: parentNorder, npix: npix),
  ),
);

/// The committed grandparent-fallback (Norder4) tile ids, keyed to
/// [surveyHipsId].
final List<HipsTileId> grandparentFallbackTiles = List<HipsTileId>.unmodifiable(
  grandparentNpix.map(
    (npix) =>
        HipsTileId(survey: surveyHipsId, norder: grandparentNorder, npix: npix),
  ),
);

/// Every committed tile id across all orders (grandparent, parent, primary),
/// in ascending-order then ascending-npix sequence — the complete fixture set.
final List<HipsTileId> allTiles = List<HipsTileId>.unmodifiable(<HipsTileId>[
  ...grandparentFallbackTiles,
  ...parentFallbackTiles,
  ...primaryTiles,
]);

/// Resolves the on-disk fixture root directory (the `hips/` folder this file
/// lives in), independent of the test's current working directory.
///
/// This file is at `<pkg>/test/fixtures/hips/fixture_field.dart`; the fixtures
/// sit beside it. We locate it from this library's own URI so a test launched
/// from the package root, the repo root, or an IDE all resolve the same path.
/// Throws [StateError] if the directory cannot be found (a moved/renamed
/// fixture tree is a loud failure, never a silent empty load).
Directory fixtureRootDir() {
  // `Platform.script` points at the test entrypoint, not this file, so derive
  // the root from a set of candidate paths anchored at well-known markers and
  // pick the first that actually contains the manifest.
  final candidates = <String>[
    // From a package-cwd test run: cwd is <pkg>.
    '${Directory.current.path}/test/fixtures/hips',
    // From a repo-root test run.
    '${Directory.current.path}/packages/skotiq_app/test/fixtures/hips',
    // From a melos/aggregate run rooted one level above repo (defensive).
    '${Directory.current.path}/../packages/skotiq_app/test/fixtures/hips',
  ];
  for (final path in candidates) {
    final dir = Directory(path);
    if (File('${dir.path}/Norder6/Dir0/tiles_manifest.json').existsSync()) {
      return dir;
    }
  }
  throw StateError(
    'Could not locate the HiPS fixture root. Looked in:\n  '
    '${candidates.join('\n  ')}\n'
    'Run tests from the skotiq_app package root or the repository root, '
    'and ensure the committed fixtures under test/fixtures/hips are present.',
  );
}

/// Absolute path to the committed `tiles_manifest.json` integrity index.
String manifestPath() =>
    '${fixtureRootDir().path}/Norder6/Dir0/tiles_manifest.json';

/// Absolute path to the committed real DSS2-colour `properties` document.
String propertiesPath() => '${fixtureRootDir().path}/dss2color_properties.txt';

/// Absolute path to the committed Allsky (Norder3) whole-sky preview JPEG.
String allskyPath() => '${fixtureRootDir().path}/Allsky.jpg';

/// Absolute path to the committed JPEG tile for [id], using the standard
/// `Norder{k}/Dir{bucket}/Npix{n}.jpg` HiPS layout.
///
/// Throws [ArgumentError] if [id] is not part of the committed fixture set, so a
/// test asking for a tile that was never bundled fails loudly instead of reading
/// a missing file.
String tilePathFor(HipsTileId id) {
  if (!allTiles.contains(id)) {
    throw ArgumentError.value(
      id,
      'id',
      'is not part of the committed HiPS fixture set for $fieldName; '
          'bundled orders are $grandparentNorder/$parentNorder/$primaryNorder',
    );
  }
  final rel = id.relativePath(surveyTileFormat);
  return '${fixtureRootDir().path}/$rel';
}

/// Reads the raw committed JPEG bytes for [id] (synchronously; fixtures are
/// tiny). Surfaces a [FileSystemException] if the file is missing rather than
/// returning empty bytes.
List<int> readTileBytes(HipsTileId id) {
  final file = File(tilePathFor(id));
  if (!file.existsSync()) {
    throw FileSystemException(
      'committed HiPS fixture tile is missing on disk',
      file.path,
    );
  }
  return file.readAsBytesSync();
}

/// Reads the raw committed Allsky JPEG bytes.
List<int> readAllskyBytes() {
  final file = File(allskyPath());
  if (!file.existsSync()) {
    throw FileSystemException(
      'committed HiPS Allsky fixture is missing on disk',
      file.path,
    );
  }
  return file.readAsBytesSync();
}

/// Reads the committed real `properties` document text.
String readPropertiesText() {
  final file = File(propertiesPath());
  if (!file.existsSync()) {
    throw FileSystemException(
      'committed HiPS properties fixture is missing on disk',
      file.path,
    );
  }
  return file.readAsStringSync();
}

// Self-validating fixture-integrity + real-data render-verify suite.
//
// Reached only when this file is executed as a test entrypoint:
//   flutter test test/fixtures/hips/fixture_field.dart
// Importing the descriptor as a library never runs any of this.

/// Decodes encoded image [bytes] into a [ui.Image] through the exact production
/// path the framing provider and HiPS fetcher use (`ui.decodeImageFromList`),
/// which performs the codec work off the build thread on the engine's IO/raster
/// workers — never blocking the caller's frame.
Future<ui.Image> _decode(List<int> bytes) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(_asUint8(bytes), completer.complete);
  return completer.future;
}

Uint8List _asUint8(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

/// Computes the lowercase-hex SHA-256 of [data].
///
/// A self-contained FIPS 180-4 implementation so the fixture-integrity check
/// needs no extra package dependency (the descriptor library stays importable by
/// any test without pulling `package:crypto` into this package's declared
/// dependencies). Used only by the self-test below, not by the descriptor API.
String _sha256Hex(List<int> data) {
  const k = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  final h = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];

  const mask = 0xffffffff;
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & mask;

  // Pad: append 0x80, then zeros, then 64-bit big-endian bit length.
  final bitLen = data.length * 8;
  final padded = <int>[...data, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLen >> (8 * i)) & 0xff);
  }

  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final j = chunk + i * 4;
      w[i] = (padded[j] << 24) |
          (padded[j + 1] << 16) |
          (padded[j + 2] << 8) |
          padded[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & mask;
    }

    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & mask) & g);
      final t1 = (hh + s1 + ch + k[i] + w[i]) & mask;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & mask;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & mask;
    }
    h[0] = (h[0] + a) & mask;
    h[1] = (h[1] + b) & mask;
    h[2] = (h[2] + c) & mask;
    h[3] = (h[3] + d) & mask;
    h[4] = (h[4] + e) & mask;
    h[5] = (h[5] + f) & mask;
    h[6] = (h[6] + g) & mask;
    h[7] = (h[7] + hh) & mask;
  }

  final buffer = StringBuffer();
  for (final value in h) {
    buffer.write(value.toRadixString(16).padLeft(8, '0'));
  }
  return buffer.toString();
}

/// Repo root located by walking up until `.git`/`version.yaml` is found, so the
/// `.hips_verify/` sample lands at the repository root like the other HiPS
/// verification artifacts.
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    if (Directory('${dir.path}/.git').existsSync() ||
        File('${dir.path}/version.yaml').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
      'HiPS fixtures (C-FIX) — committed real DSS2-colour data for $fieldName',
      () {
    test('fixture root + manifest resolve and the descriptor is consistent',
        () {
      final root = fixtureRootDir();
      expect(root.existsSync(), isTrue,
          reason: 'fixture root must exist on disk');

      final manifest = jsonDecode(File(manifestPath()).readAsStringSync())
          as Map<String, dynamic>;

      // Field + survey metadata in the manifest agree with the Dart descriptor.
      final field = manifest['field'] as Map<String, dynamic>;
      expect(field['name'], fieldName);
      expect(field['raDeg'], closeTo(fieldRaDeg, 1e-9));
      expect(field['decDeg'], closeTo(fieldDecDeg, 1e-9));

      final survey = manifest['survey'] as Map<String, dynamic>;
      expect(survey['hipsId'], surveyHipsId);
      expect(survey['baseUrl'], surveyBaseUrl);
      expect(survey['tileWidth'], surveyTileWidth);
      expect(survey['hipsOrder'], surveyHipsOrder);
      expect(survey['hipsOrderMin'], surveyHipsOrderMin);
      expect(survey['allskyOrder'], allskyOrder);

      // The npix the descriptor exposes per order equal the manifest's, and the
      // total matches.
      final orders = (manifest['orders'] as List).cast<Map<String, dynamic>>();
      Map<String, dynamic> orderBlock(int n) =>
          orders.firstWhere((o) => o['norder'] == n);
      List<int> npixOf(int n) => (orderBlock(n)['tiles'] as List)
          .map((t) => (t as Map<String, dynamic>)['npix'] as int)
          .toList();
      expect(npixOf(grandparentNorder), grandparentNpix);
      expect(npixOf(parentNorder), parentNpix);
      expect(npixOf(primaryNorder), primaryNpix);
      expect(manifest['totalTileCount'], allTiles.length);
      expect(allTiles.length,
          grandparentNpix.length + parentNpix.length + primaryNpix.length);
    });

    test('every committed file matches its manifest sha256 + byte length', () {
      final root = fixtureRootDir();
      final manifest = jsonDecode(File(manifestPath()).readAsStringSync())
          as Map<String, dynamic>;

      void verify(Map<String, dynamic> entry) {
        final rel = entry['path'] as String;
        final file = File('${root.path}/$rel');
        expect(file.existsSync(), isTrue,
            reason: 'committed fixture missing: $rel');
        final bytes = file.readAsBytesSync();
        expect(bytes.length, entry['bytes'],
            reason: 'byte length mismatch for $rel');
        expect(_sha256Hex(bytes), entry['sha256'],
            reason: 'sha256 mismatch for $rel — re-run the fetch tool');
      }

      verify(manifest['properties'] as Map<String, dynamic>);
      verify(manifest['allsky'] as Map<String, dynamic>);
      for (final order in (manifest['orders'] as List)) {
        for (final tile in ((order as Map<String, dynamic>)['tiles'] as List)) {
          verify(tile as Map<String, dynamic>);
        }
      }
    });

    test('real properties parse via C0 and agree with the descriptor', () {
      final props = HipsProperties.parse(readPropertiesText());
      expect(props.hipsOrder, surveyHipsOrder);
      expect(props.hipsOrderMin, surveyHipsOrderMin);
      expect(props.tileWidth, surveyTileWidth);
      expect(props.tileWidthWasDefaulted, isFalse);
      expect(props.frame, HipsFrame.equatorial);
      expect(props.tileFormats, contains(HipsTileFormat.jpeg));
      expect(props.preferredFormat, surveyTileFormat);
      // The committed DSS2-colour attribution survives the round-trip.
      expect(props.obsCopyright, isNotNull);
      expect(props.obsCopyright, contains('Digitized Sky Survey - STScI/NASA'));
      expect(
          props.obsCopyrightUrl, 'http://archive.stsci.edu/dss/copyright.html');
    });

    test('descriptor npix == production HipsTileSelection output for the field',
        () {
      final props = HipsProperties.parse(readPropertiesText());
      const plate = FramingPlateScale(
        surveyFovWidthDeg: fixtureFovWidthDeg,
        surveyFovHeightDeg: fixtureFovHeightDeg,
        imagePixelWidth: fixturePixelWidth,
        imagePixelHeight: fixturePixelHeight,
      );
      final canvas = Size(
        fixturePixelWidth.toDouble(),
        fixturePixelHeight.toDouble(),
      );
      const target = FramingTarget(
        name: fieldName,
        catalogId: 'M31',
        raHours: fieldRaHours,
        decDegrees: fieldDecDeg,
      );

      // At golden zoom 1.0 the LOD rule must pick the primary order, and its
      // visible-tile npix must be exactly the committed primary set.
      final norder = HipsTileSelection.selectNorder(
        plate.pixelsPerDegree(canvas, 1.0),
        props,
      );
      expect(norder, primaryNorder,
          reason: 'golden-zoom LOD order drifted from the committed fixture');
      final selected = HipsTileSelection.computeVisibleTiles(
        plate,
        target,
        canvas,
        1.0,
        norder,
        props,
        surveyId: surveyHipsId,
      );
      expect(selected.tileIds.map((t) => t.npix).toList(), primaryNpix,
          reason: 'committed primary tile set no longer matches selection');

      // The parent/grandparent fallback ids are the (deduped, ascending) HEALPix
      // ancestors of the primary set — exactly what the loader prefetches.
      List<int> ancestors(List<int> npix, int levels) {
        final set = <int>{};
        for (final n in npix) {
          set.add(n >> (2 * levels));
        }
        final list = set.toList()..sort();
        return list;
      }

      expect(ancestors(primaryNpix, 1), parentNpix,
          reason: 'committed Norder5 parents are not the primary set parents');
      expect(ancestors(primaryNpix, 2), grandparentNpix,
          reason: 'committed Norder4 grandparents drifted');
    });

    test('every committed tile + Allsky decodes to a real ui.Image', () async {
      // Allsky.
      final allsky = await _decode(readAllskyBytes());
      addTearDown(allsky.dispose);
      expect(allsky.width, greaterThan(0));
      expect(allsky.height, greaterThan(0));

      // Every tile across all orders.
      for (final id in allTiles) {
        final image = await _decode(readTileBytes(id));
        expect(image.width, surveyTileWidth,
            reason: 'tile $id is not ${surveyTileWidth}px wide');
        expect(image.height, surveyTileWidth,
            reason: 'tile $id is not ${surveyTileWidth}px tall');
        image.dispose();
      }
    });

    test('real-data mosaic composites + writes golden and .hips_verify sample',
        () async {
      final props = HipsProperties.parse(readPropertiesText());
      const plate = FramingPlateScale(
        surveyFovWidthDeg: fixtureFovWidthDeg,
        surveyFovHeightDeg: fixtureFovHeightDeg,
        imagePixelWidth: fixturePixelWidth,
        imagePixelHeight: fixturePixelHeight,
      );
      final canvas = Size(
        fixturePixelWidth.toDouble(),
        fixturePixelHeight.toDouble(),
      );
      const target = FramingTarget(
        name: fieldName,
        catalogId: 'M31',
        raHours: fieldRaHours,
        decDegrees: fieldDecDeg,
      );

      final cache = HipsTileCache(
        maxEntries: 256,
        maxBytes: 256 * 1024 * 1024,
      );
      addTearDown(cache.dispose);

      // Make every committed primary tile resident, decoded from the real bytes.
      final norder = HipsTileSelection.selectNorder(
        plate.pixelsPerDegree(canvas, 1.0),
        props,
      );
      final visibleSet = HipsTileSelection.computeVisibleTiles(
        plate,
        target,
        canvas,
        1.0,
        norder,
        props,
        surveyId: surveyHipsId,
      );
      final primary = <HipsVisibleTile>[];
      for (final tile in visibleSet.tiles) {
        cache.put(tile.id, await _decode(readTileBytes(tile.id)));
        primary.add(tile);
      }

      final allskyImage = await _decode(readAllskyBytes());
      addTearDown(allskyImage.dispose);

      final snapshot = HipsResidentSnapshot(
        version: 1,
        selectedNorder: visibleSet.norder,
        primaryTiles: List.unmodifiable(primary),
        fallbackTiles: const [],
        allsky: allskyImage,
        cacheSnapshot: cache.snapshot(),
        visibleSet: visibleSet,
        failures: const [],
      );

      final painter = HipsTileLayerPainter(
        snapshot: snapshot,
        allskyOrder: allskyOrder,
      );

      // Rasterise the painter directly (a Picture.toImage is deterministic and
      // does not hang the golden comparator on an offscreen drawVertices tree,
      // matching the C8 golden's approach).
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder);
      c.drawRect(
        Offset.zero & canvas,
        Paint()..color = const Color(0xFF05070C),
      );
      painter.paint(c, canvas);
      final picture = recorder.endRecording();
      final ui.Image image;
      try {
        image = await picture.toImage(
          fixturePixelWidth,
          fixturePixelHeight,
        );
      } finally {
        picture.dispose();
      }
      addTearDown(image.dispose);

      // Write the human-inspectable sample under <repo>/.hips_verify/.
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(png, isNotNull,
          reason: 'PNG encode of the real-data mosaic failed');
      final outDir = Directory('${_repoRoot().path}/.hips_verify');
      outDir.createSync(recursive: true);
      final outFile = File('${outDir.path}/hips_fixture_m31_mosaic_sample.png');
      outFile.writeAsBytesSync(png!.buffer.asUint8List());
      // ignore: avoid_print
      print('HiPS fixture M31 real-data mosaic written to: '
          '${outFile.absolute.path}');

      // Byte-lock the rendered real-data mosaic.
      await expectLater(
        image,
        matchesGoldenFile('goldens/hips_fixture_m31_mosaic.png'),
      );
    });
  });
}
