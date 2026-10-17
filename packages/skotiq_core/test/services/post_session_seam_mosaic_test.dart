// Seam-level guard for the Mosaic M2 `stitchMosaic` addition to
// [PostSessionSeam].
//
// `stitchMosaic` spans two contracts that must agree on the exact JSON shape:
//
//   1. The production seam ([BridgePostSessionSeam.stitchMosaic]) jsonEncodes the
//      request map straight through to `apiStitchMosaic` and jsonDecodes the
//      reply into a [MosaicStitchResult]. The request map is the native
//      `StitchMosaicArgs` shape and the reply is the native `StitchMosaicResult`
//      (camelCase via serde `rename_all`).
//   2. A fake ([_FakeSeam]) lets the orchestration services run end-to-end
//      without the Rust library: it is scriptable and records the request map.
//
// The bridge half issues a real FFI call and so cannot run here without native
// code. What this test pins is the half that does not need the library: the
// `MosaicStitchResult` decoder against the *exact* native serde key spelling
// (`previewPngPath`, `outWidth`, `meanPanelGain`, …), the request envelope
// shape, and the fake's scriptable / call-recording behaviour. If the native
// result keys drift, or the model's defensive decode regresses, this catches it.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/mosaic_stitch_result.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';

/// A scriptable [PostSessionSeam] that records the `stitchMosaic` request and
/// returns a canned result, so the bridge encode/decode contract can be checked
/// without native code. Only the members exercised here are meaningful; the rest
/// throw if called (this fake is intentionally minimal, not a service double).
class _FakeSeam implements PostSessionSeam {
  final List<Map<String, dynamic>> stitchCalls = [];
  MosaicStitchResult? scripted;

  @override
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args) async {
    stitchCalls.add(args);
    return scripted ??
        MosaicStitchResult(
          outputPath:
              (args['output'] as Map?)?['mosaicFitsPath'] as String? ?? '',
          outWidth: 0,
          outHeight: 0,
          overlapPairs: 0,
          meanPanelGain: 1.0,
        );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

void main() {
  group('MosaicStitchResult.fromJson (native StitchMosaicResult shape)', () {
    test('decodes the exact native serde camelCase keys', () {
      // This is the literal JSON shape the Rust `StitchMosaicResult` serializes
      // (rename_all = "camelCase"): note `previewPngPath`, not `previewPath`.
      const nativeJson = '''
      {
        "outputPath": "/out/mosaic.fits",
        "coveragePath": "/out/coverage.fits",
        "previewPngPath": "/out/mosaic.png",
        "outWidth": 4096,
        "outHeight": 2048,
        "overlapPairs": 12,
        "meanPanelGain": 1.0375
      }
      ''';
      final r = MosaicStitchResult.fromJson(
        jsonDecode(nativeJson) as Map<String, dynamic>,
      );

      expect(r.outputPath, '/out/mosaic.fits');
      expect(r.coveragePath, '/out/coverage.fits');
      expect(r.previewPath, '/out/mosaic.png');
      expect(r.outWidth, 4096);
      expect(r.outHeight, 2048);
      expect(r.overlapPairs, 12);
      expect(r.meanPanelGain, closeTo(1.0375, 1e-9));
    });

    test('omitted optional paths decode to null, ints coerce from num', () {
      // A minimal native reply: no coverage / preview requested, integer-valued
      // gain arriving as a JSON int must coerce to double.
      final r = MosaicStitchResult.fromJson(const {
        'outputPath': '/out/m.fits',
        'outWidth': 100,
        'outHeight': 80,
        'overlapPairs': 0,
        'meanPanelGain': 1,
      });

      expect(r.coveragePath, isNull);
      expect(r.previewPath, isNull);
      expect(r.meanPanelGain, 1.0);
    });

    test('round-trips through toJson and value-equality', () {
      const r = MosaicStitchResult(
        outputPath: '/out/m.fits',
        coveragePath: '/out/c.fits',
        previewPath: '/out/p.png',
        outWidth: 200,
        outHeight: 100,
        overlapPairs: 3,
        meanPanelGain: 0.97,
      );
      final round = MosaicStitchResult.fromJson(
        jsonDecode(jsonEncode(r.toJson())),
      );
      expect(round, r);
      expect(round.hashCode, r.hashCode);
      // toJson emits the native preview key so a re-encoded request is decodable
      // by the same path the native reply takes.
      expect(r.toJson()['previewPngPath'], '/out/p.png');
    });
  });

  group('BridgePostSessionSeam.stitchMosaic request envelope', () {
    test(
      'the documented StitchMosaicArgs shape round-trips through jsonEncode',
      () {
        // The production seam does `jsonEncode(args)` verbatim. Pin that the
        // documented request envelope (panels[].fitsPath + optional wcs, config,
        // output paths) survives encode unchanged — this is the shape the native
        // `StitchMosaicArgs` deserializer consumes.
        final args = <String, dynamic>{
          'panels': [
            {'fitsPath': '/panels/p0.fits'},
            {
              'fitsPath': '/panels/p1.fits',
              'wcs': {
                'crval1': 120.0,
                'crval2': 10.0,
                'crpix1': 48.5,
                'crpix2': 48.5,
                'cd1_1': -0.0011,
                'cd1_2': 0.0,
                'cd2_1': 0.0,
                'cd2_2': 0.0011,
              },
            },
          ],
          'config': {
            'normalize': true,
            'blend': 'feather',
            'resampler': 'lanczos3',
          },
          'output': {
            'mosaicFitsPath': '/out/mosaic.fits',
            'coverageFitsPath': '/out/coverage.fits',
            'previewPngPath': '/out/mosaic.png',
          },
        };

        final decoded = jsonDecode(jsonEncode(args)) as Map<String, dynamic>;
        expect((decoded['panels'] as List), hasLength(2));
        expect((decoded['panels'] as List)[0]['fitsPath'], '/panels/p0.fits');
        expect((decoded['panels'] as List)[1]['wcs']['cd1_1'], -0.0011);
        expect(decoded['config']['resampler'], 'lanczos3');
        expect(decoded['output']['mosaicFitsPath'], '/out/mosaic.fits');
        expect(decoded['output']['previewPngPath'], '/out/mosaic.png');
      },
    );
  });

  group('Fake stitchMosaic seam (scriptable)', () {
    test('returns the scripted result and records the request args', () async {
      final fake = _FakeSeam();
      const scripted = MosaicStitchResult(
        outputPath: '/scripted/mosaic.fits',
        coveragePath: '/scripted/coverage.fits',
        previewPath: '/scripted/mosaic.png',
        outWidth: 4096,
        outHeight: 2048,
        overlapPairs: 12,
        meanPanelGain: 1.05,
      );
      fake.scripted = scripted;

      final args = <String, dynamic>{
        'panels': [
          {'fitsPath': '/p0.fits'},
          {'fitsPath': '/p1.fits'},
        ],
        'output': {'mosaicFitsPath': '/out/mosaic.fits'},
      };
      final result = await fake.stitchMosaic(args);

      expect(result, scripted);
      expect(fake.stitchCalls, hasLength(1));
      expect((fake.stitchCalls.single['panels'] as List), hasLength(2));
    });

    test('echoes the output path when no result is scripted', () async {
      final fake = _FakeSeam();
      final result = await fake.stitchMosaic(const {
        'panels': [
          {'fitsPath': '/p0.fits'},
        ],
        'output': {'mosaicFitsPath': '/echo/mosaic.fits'},
      });
      expect(result.outputPath, '/echo/mosaic.fits');
    });
  });
}
