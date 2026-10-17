// Component C11 — HiPS live-fetch smoke test (opt-in, never CI).
//
// Every other HiPS test in this package is hermetic: it serves bytes from a
// `package:http/testing` MockClient so the suite is fast, deterministic, and
// offline. That is exactly what CI needs. But it leaves one thing unverified by
// construction — that the *real* CDS HiPS endpoints the framing tile layer
// targets are actually reachable and serving the survey we think they are, in
// the layout (`properties`, `Norder{k}/Allsky.{ext}`, `Norder{k}/Dir{d}/
// Npix{n}.{ext}`) the addressing code (C0/C1) builds. A typo in a base URL, a
// survey that CDS moved or retired, an Allsky map that 404s at the order we
// fetch, or a `properties` document whose keys drifted would all sail past the
// mock-backed tests and only bite a user at runtime.
//
// This test closes that gap by exercising the genuine production fetch + decode
// path (component C5 [HipsTileFetcher], no mock) against the live DSS2-color
// pyramid for the canonical M42 fixture field, and asserting:
//
//   * `properties` GETs, decodes, and parses into a valid [HipsProperties] with
//     real attribution (obs_copyright) — the metadata the framing UI must show.
//   * the whole-sky `Allsky` thumbnail at the survey's published allsky order
//     ([HipsProperties.allskyOrder], the standard order 3 for DSS) GETs and
//     decodes to a non-empty [ui.Image] (the never-blank base LOD).
//   * a couple of higher-Norder tiles that *actually cover the fixture field*
//     (addressed via the same C1 HEALPix NESTED math the selection layer uses,
//     not hand-guessed pixel indices) GET and decode to non-empty [ui.Image]s.
//
// It is gated so it can never run by accident:
//
//   * `@Tags(['live-network'])` (registered in `dart_test.yaml`) lets the tag be
//     selected on the command line and keeps the annotation from being rejected
//     as unknown.
//   * The test marks itself skipped unless `SKOTIQ_LIVE_NETWORK=1` is set in
//     the environment. CI's `melos run test` and a plain `flutter test` never
//     set it, so they never open a socket. The opt-in run is:
//
//         SKOTIQ_LIVE_NETWORK=1 flutter test --tags live-network
//
// One sharp edge worth documenting: `flutter test` runs under
// [TestWidgetsFlutterBinding], which installs an [HttpOverrides] that stubs
// every real socket (all requests return 400 and nothing leaves the machine).
// That is exactly the right default — it stops a stray test from hitting the
// network — but it would make a *deliberate* live test impossible. So, only when
// the env gate is open, this test clears the override for its duration
// (`HttpOverrides.global = null`, restored in tearDown), letting the real
// platform [HttpClient] back in. Nothing changes when the gate is closed.
//
// A live endpoint that is unreachable, returns a non-200, or serves an
// undecodable body throws a typed [HipsFetchException] and fails this test.
// There is no skip-on-network-error fallback: an opt-in live check gives a real
// pass or fail.
@Tags(['live-network'])
library;

import 'dart:io' show HttpOverrides, Platform;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
import 'package:skotiq_core/src/services/hips/healpix_nested.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The live DSS2-color HiPS pyramid published by CDS. This is the colour
  // composite of the DSS2 red/blue mono pyramids the framing assistant streams;
  // its `properties`/`Allsky`/tile layout were confirmed against the standard
  // HiPS 1.0 paths. The canonical CDS HiPS id for it is `CDS/P/DSS2/color`.
  const baseUrl = 'https://alasky.cds.unistra.fr/DSS/DSSColor';
  const surveyId = 'CDS/P/DSS2/color';

  // The canonical fixture field used across the HiPS tests: M42, the Orion
  // Nebula. RA/Dec in the units the framing render path uses (hours / degrees).
  const fixtureRaHours = 5.5882; // 83.823 deg
  const fixtureDecDegrees = -5.391;
  const fixtureRaDeg = fixtureRaHours * 15.0;

  // The env gate. When unset the whole group is skipped (no socket opened),
  // belt-and-suspenders with the dart_test.yaml tag default-skip.
  final liveEnabled = Platform.environment['SKOTIQ_LIVE_NETWORK'] == '1';
  final skipReason = liveEnabled
      ? null
      : 'live-network test: set SKOTIQ_LIVE_NETWORK=1 and run with '
            '--tags live-network to enable real CDS HiPS fetches';

  group('HiPS live fetch smoke (DSS2-color @ M42)', () {
    late HipsTileFetcher fetcher;
    HttpOverrides? savedOverrides;

    setUp(() {
      // The flutter_test binding stubs all real HTTP (returns 400, no socket).
      // For the live path we restore the platform default by clearing the
      // override; we save and reinstate it in tearDown so the change is scoped
      // strictly to this opt-in test and cannot leak into any other suite.
      savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      // A real fetcher with a real HTTP client (production path). A modest
      // timeout keeps a hung mirror from stalling the opt-in run indefinitely;
      // a timeout surfaces as a typed [HipsFetchHttpException], a real failure.
      fetcher = HipsTileFetcher(timeout: const Duration(seconds: 30));
    });

    tearDown(() {
      fetcher.dispose();
      HttpOverrides.global = savedOverrides;
    });

    test(
      'fetches + parses the live properties document with attribution',
      () async {
        final props = await fetcher.fetchProperties(baseUrl);

        // Structural invariants the framing LOD + addressing depend on.
        expect(
          props.hipsOrder,
          greaterThanOrEqualTo(3),
          reason: 'DSS2-color publishes a multi-order pyramid',
        );
        expect(props.hipsOrderMin, greaterThanOrEqualTo(0));
        expect(props.hipsOrderMin, lessThanOrEqualTo(props.hipsOrder));
        expect(props.tileWidth, greaterThan(0));
        expect(props.tileFormats, isNotEmpty);
        expect(
          props.frame,
          HipsFrame.equatorial,
          reason: 'DSS2-color is tiled in the equatorial frame',
        );

        // Attribution the framing UI surfaces to the user must be present and
        // non-empty — a colour DSS composite always carries an STScI/NASA +
        // CDS credit. We assert it parsed, not its exact wording (CDS may revise
        // the copy), so the test stays robust to harmless text edits.
        expect(
          props.obsCopyright,
          isNotNull,
          reason: 'DSS2-color publishes obs_copyright attribution',
        );
        expect(props.obsCopyright!.trim(), isNotEmpty);
      },
    );

    test(
      'fetches + decodes the whole-sky Allsky base LOD to a valid image',
      () async {
        final props = await fetcher.fetchProperties(baseUrl);
        final format = props.preferredFormat;

        // CDS publishes the whole-sky `Allsky` map at a single low-resolution
        // *allsky order* — the standard HiPS convention (and the value used by
        // Aladin/HipsGen) is Norder 3, regardless of the pyramid's hips_order_min
        // (which for DSS2-color is the default 0 because the key is absent, yet
        // Norder0..2 have no Allsky map). [HipsProperties.allskyOrder] encodes that
        // convention (standard order 3, clamped to the survey range) and is the
        // SAME value the production loader/painter address the Allsky at — so we
        // fetch it here too, proving the production order resolves live.
        final allskyOrder = props.allskyOrder;
        expect(
          allskyOrder,
          3,
          reason:
              'DSS2-color omits hips_order_min (-> 0) but its Allsky lives '
              'at the standard order 3',
        );
        expect(
          props.hipsOrder,
          greaterThanOrEqualTo(allskyOrder),
          reason: 'survey must publish at least to the allsky order',
        );

        final ui.Image allsky = await fetcher.fetchAllsky(
          baseUrl,
          allskyOrder,
          format,
        );
        addTearDown(allsky.dispose);

        expect(allsky.width, greaterThan(0));
        expect(allsky.height, greaterThan(0));

        // Prove the decoded image actually has pixels (a degenerate/blank decode
        // would still report dimensions); read back the raw RGBA and confirm it
        // is the expected size and not entirely transparent-black.
        final byteData = await allsky.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(byteData, isNotNull);
        final rgba = byteData!.buffer.asUint8List();
        expect(rgba.length, allsky.width * allsky.height * 4);
        expect(
          rgba.any((b) => b != 0),
          isTrue,
          reason: 'a real sky thumbnail is not all-zero pixels',
        );
      },
    );

    test('fetches + decodes the Norder tiles covering the fixture field', () async {
      final props = await fetcher.fetchProperties(baseUrl);
      final format = props.preferredFormat;

      // Pick two concrete orders that exist in this pyramid: the minimum
      // published order (coarse, whole-field) and a deeper order clamped to the
      // pyramid's max. These bracket the LOD range the framing layer streams.
      final coarseOrder = props.hipsOrderMin;
      final deepOrder = props.hipsOrder < coarseOrder + 5
          ? props.hipsOrder
          : coarseOrder + 5;

      // Address the *exact* tile that contains M42 at each order using the same
      // C1 HEALPix NESTED math the selection layer uses — not a guessed
      // pixel index. This verifies the live server has imagery at the field we
      // actually frame, through the real addressing code path.
      for (final order in <int>{coarseOrder, deepOrder}) {
        final healpix = HealpixNested(order);
        final npix = healpix.ang2pixNest(fixtureRaDeg, fixtureDecDegrees);
        final id = HipsTileId(survey: surveyId, norder: order, npix: npix);

        final ui.Image tile = await fetcher.fetchTile(id, baseUrl, format);
        addTearDown(tile.dispose);

        expect(
          tile.width,
          greaterThan(0),
          reason: 'Norder$order/Npix$npix decoded to a positive width',
        );
        expect(tile.height, greaterThan(0));

        final byteData = await tile.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(byteData, isNotNull);
        final rgba = byteData!.buffer.asUint8List();
        expect(rgba.length, tile.width * tile.height * 4);
        // The M42 field is bright Milky-Way sky, so its tile is never an
        // all-zero (pure black/transparent) image at any published order.
        expect(
          rgba.any((b) => b != 0),
          isTrue,
          reason: 'the M42 tile at Norder$order has real sky signal',
        );
      }
    });

    test('a missing tile surfaces a typed HTTP error', () async {
      final props = await fetcher.fetchProperties(baseUrl);
      final format = props.preferredFormat;

      // Address a tile one order *beyond* the published maximum. The pyramid
      // has no such order, so the live server must answer non-200 and C5 must
      // surface it as a typed [HipsFetchHttpException] — never a silent blank.
      final missingOrder = props.hipsOrder + 1;
      final id = HipsTileId(survey: surveyId, norder: missingOrder, npix: 0);

      await expectLater(
        fetcher.fetchTile(id, baseUrl, format),
        throwsA(isA<HipsFetchHttpException>()),
      );
    });
  }, skip: skipReason);
}
