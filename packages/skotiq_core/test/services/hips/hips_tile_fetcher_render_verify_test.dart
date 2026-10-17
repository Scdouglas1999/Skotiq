// Render-verification for component C5 (HiPS HTTP fetch + async decode client).
//
// Unlike a renderer, C5's job is to turn wire bytes into a GPU-ready
// [ui.Image]. This verification exercises the *full production path* end to end:
//
//   1. A real PNG is encoded with the `image` package and served by a
//      `package:http/testing` MockClient under a HiPS tile URL.
//   2. [HipsTileFetcher.fetchTile] GETs and decodes it via
//      `ui.instantiateImageCodec` (the off-UI-thread engine decode) to a
//      [ui.Image] — exactly what the framing tile painter would composite.
//   3. The decoded image's pixels are read back via `toByteData` and
//      re-encoded to PNG, proving the bytes survived the round-trip intact
//      (content + dimensions), then written as:
//        * sample: repo-root `.hips_verify/hips_tile_fetch_decode.png`
//        * golden: `test/services/hips/goldens/hips_tile_fetch_decode.png`
//
// The golden locks the decoded output so a break in the fetch/decode path
// (wrong format handling, channel swap, dimension loss) fails loudly.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('C5 fetch + decode round-trip produces a correct ui.Image (sample + '
      'golden)', () async {
    const tileSize = 96;

    // A recognisable test pattern: four colored quadrants + a diagonal, so a
    // channel swap or transpose in the decode path would change the golden.
    final source = img.Image(width: tileSize, height: tileSize);
    for (var y = 0; y < tileSize; y++) {
      for (var x = 0; x < tileSize; x++) {
        final left = x < tileSize ~/ 2;
        final top = y < tileSize ~/ 2;
        img.Color c;
        if (top && left) {
          c = img.ColorRgb8(220, 40, 40);
        } else if (top && !left) {
          c = img.ColorRgb8(40, 200, 80);
        } else if (!top && left) {
          c = img.ColorRgb8(60, 90, 230);
        } else {
          c = img.ColorRgb8(230, 200, 30);
        }
        if (x == y) c = img.ColorRgb8(255, 255, 255);
        source.setPixel(x, y, c);
      }
    }
    final encoded = Uint8List.fromList(img.encodePng(source));

    final client = MockClient((request) async {
      return http.Response.bytes(encoded, 200);
    });
    final fetcher = HipsTileFetcher(httpClient: client);
    addTearDown(fetcher.dispose);

    const baseUrl = 'https://alasky.cds.unistra.fr/DSS/DSS2Merged';
    final id = HipsTileId(survey: 'CDS/P/DSS2/red', norder: 4, npix: 777);

    final ui.Image image = await fetcher.fetchTile(
      id,
      baseUrl,
      HipsTileFormat.png,
    );
    addTearDown(image.dispose);

    expect(image.width, tileSize);
    expect(image.height, tileSize);

    // Read back the decoded GPU image and re-encode to PNG for the artifact.
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(byteData, isNotNull);
    final rgba = byteData!.buffer.asUint8List();
    expect(rgba.length, tileSize * tileSize * 4);

    final roundTrip = img.Image.fromBytes(
      width: tileSize,
      height: tileSize,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

    // Spot-check that the decoded content matches the source quadrants — the
    // fetch+decode path preserves pixels, not just dimensions.
    // Sample off the white diagonal (x != y) so the quadrant colours are read.
    final tl = roundTrip.getPixel(tileSize ~/ 4, tileSize ~/ 2 - 4);
    expect(tl.r, closeTo(220, 2));
    expect(tl.g, closeTo(40, 2));
    expect(tl.b, closeTo(40, 2));
    final br = roundTrip.getPixel(3 * tileSize ~/ 4, tileSize ~/ 2 + 4);
    expect(br.r, closeTo(230, 2));
    expect(br.g, closeTo(200, 2));
    expect(br.b, closeTo(30, 2));

    final png = Uint8List.fromList(img.encodePng(roundTrip));

    // Sample artifact at repo root for human inspection.
    final repoRoot = _repoRoot();
    final sampleDir = Directory('${repoRoot.path}/.hips_verify');
    sampleDir.createSync(recursive: true);
    final sample = File('${sampleDir.path}/hips_tile_fetch_decode.png');
    sample.writeAsBytesSync(png);
    // ignore: avoid_print
    print('HiPS C5 fetch+decode sample written: ${sample.absolute.path}');

    // Golden lock: write on first run, byte-compare thereafter.
    final goldenDir = Directory('test/services/hips/goldens');
    goldenDir.createSync(recursive: true);
    final golden = File('${goldenDir.path}/hips_tile_fetch_decode.png');
    if (!golden.existsSync()) {
      golden.writeAsBytesSync(png);
      // ignore: avoid_print
      print('Golden created: ${golden.absolute.path}');
    } else {
      expect(
        png,
        golden.readAsBytesSync(),
        reason:
            'C5 fetch+decode round-trip drifted from golden; if '
            'intentional, delete ${golden.path} to regenerate.',
      );
    }
  });
}

/// Walks up to the repo root (directory holding `version.yaml`).
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/version.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.parent.parent;
}
