import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/models/hips/hips_survey_registry.dart';
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show SurveySource;

/// A realistic, minimal HiPS `properties` document modelled on the live
/// CDS/P/DSS2/red metadata (order 9, equatorial, 512px, jpeg+fits).
const _dss2RedProperties = '''
creator_did          = ivo://CDS/P/DSS2/red
obs_collection       = DSS2 Red (F+R)
obs_copyright        = Digitized Sky Survey - STScI/NASA, Healpixed by CDS
obs_copyright_url    = http://archive.stsci.edu/dss/copyright.html
hips_creator         = Boch T. (CDS)
hips_version         = 1.4
hips_order           = 9
hips_order_min       = 0
hips_frame           = equatorial
hips_tile_width      = 512
hips_tile_format     = jpeg fits
hips_initial_ra      = 83.6331
hips_initial_dec     = 22.0145
hips_initial_fov     = 1.5
dataproduct_type     = image
hips_status          = public master clonableOnce
''';

void main() {
  group('HipsProperties.parse', () {
    test('parses a complete, valid DSS2 properties document', () {
      final props = HipsProperties.parse(_dss2RedProperties);

      expect(props.hipsOrder, 9);
      expect(props.hipsOrderMin, 0);
      expect(props.tileWidth, 512);
      expect(props.tileWidthWasDefaulted, isFalse);
      expect(props.tileFormats, [HipsTileFormat.jpeg, HipsTileFormat.fits]);
      expect(props.preferredFormat, HipsTileFormat.jpeg);
      expect(props.hasJpeg, isTrue);
      expect(props.hasPng, isFalse);
      expect(props.frame, HipsFrame.equatorial);
      expect(
        props.obsCopyright,
        'Digitized Sky Survey - STScI/NASA, Healpixed by CDS',
      );
      expect(
        props.obsCopyrightUrl,
        'http://archive.stsci.edu/dss/copyright.html',
      );
      expect(props.creator, 'Boch T. (CDS)');
      expect(props.initialRaDeg, closeTo(83.6331, 1e-9));
      expect(props.initialDecDeg, closeTo(22.0145, 1e-9));
      expect(props.initialFovDeg, closeTo(1.5, 1e-9));
    });

    test('value equality holds for two parses of the same document', () {
      expect(
        HipsProperties.parse(_dss2RedProperties),
        HipsProperties.parse(_dss2RedProperties),
      );
    });

    test('honours comments, blank lines and key=value without spaces', () {
      const doc = '''
# a comment
hips_order=5

hips_frame=galactic
hips_tile_format=png
''';
      final props = HipsProperties.parse(doc);
      expect(props.hipsOrder, 5);
      expect(props.frame, HipsFrame.galactic);
      expect(props.tileFormats, [HipsTileFormat.png]);
      // order_min and tile_width fall back to documented standard defaults.
      expect(props.hipsOrderMin, HipsProperties.defaultOrderMin);
      expect(props.tileWidth, HipsProperties.defaultTileWidth);
      expect(props.tileWidthWasDefaulted, isTrue);
    });

    test('supports backslash line continuation in a value', () {
      const doc = '''
hips_order = 3
hips_frame = equatorial
hips_tile_format = jpeg
obs_copyright = Part one \\
and part two
''';
      final props = HipsProperties.parse(doc);
      expect(props.obsCopyright, 'Part one and part two');
    });

    test('accepts the jpg alias for jpeg', () {
      const doc =
          'hips_order = 3\nhips_frame = equatorial\nhips_tile_format = jpg\n';
      expect(HipsProperties.parse(doc).tileFormats, [HipsTileFormat.jpeg]);
    });

    test('skips unknown formats but keeps recognised ones', () {
      const doc =
          'hips_order = 3\nhips_frame = equatorial\nhips_tile_format = tiff png\n';
      expect(HipsProperties.parse(doc).tileFormats, [HipsTileFormat.png]);
    });

    test('missing hips_order is a surfaced error', () {
      const doc = 'hips_frame = equatorial\nhips_tile_format = jpeg\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(
          isA<HipsPropertiesParseException>().having(
            (e) => e.key,
            'key',
            'hips_order',
          ),
        ),
      );
    });

    test('missing hips_tile_format is a surfaced error', () {
      const doc = 'hips_order = 3\nhips_frame = equatorial\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(
          isA<HipsPropertiesParseException>().having(
            (e) => e.key,
            'key',
            'hips_tile_format',
          ),
        ),
      );
    });

    test('missing hips_frame is a surfaced error', () {
      const doc = 'hips_order = 3\nhips_tile_format = jpeg\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(
          isA<HipsPropertiesParseException>().having(
            (e) => e.key,
            'key',
            'hips_frame',
          ),
        ),
      );
    });

    test('unrecognised hips_frame is fatal (no silent equatorial fallback)', () {
      const doc =
          'hips_order = 3\nhips_frame = supergalactic\nhips_tile_format = jpeg\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(
          isA<HipsPropertiesParseException>()
              .having((e) => e.key, 'key', 'hips_frame')
              .having((e) => e.rawValue, 'rawValue', 'supergalactic'),
        ),
      );
    });

    test('no recognised format is fatal', () {
      const doc =
          'hips_order = 3\nhips_frame = equatorial\nhips_tile_format = tiff bmp\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(
          isA<HipsPropertiesParseException>().having(
            (e) => e.key,
            'key',
            'hips_tile_format',
          ),
        ),
      );
    });

    test('non-integer hips_order is a surfaced error', () {
      const doc =
          'hips_order = nine\nhips_frame = equatorial\nhips_tile_format = jpeg\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('out-of-range hips_order is a surfaced error', () {
      const doc =
          'hips_order = 99\nhips_frame = equatorial\nhips_tile_format = jpeg\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('non-power-of-two tile width is a surfaced error', () {
      const doc =
          'hips_order = 3\nhips_frame = equatorial\n'
          'hips_tile_format = jpeg\nhips_tile_width = 500\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(
          isA<HipsPropertiesParseException>().having(
            (e) => e.key,
            'key',
            'hips_tile_width',
          ),
        ),
      );
    });

    test('order_min greater than order is a surfaced error', () {
      const doc =
          'hips_order = 3\nhips_order_min = 5\n'
          'hips_frame = equatorial\nhips_tile_format = jpeg\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(
          isA<HipsPropertiesParseException>().having(
            (e) => e.key,
            'key',
            'hips_order_min',
          ),
        ),
      );
    });

    test('duplicate key is a surfaced error (not last-write-wins)', () {
      const doc =
          'hips_order = 3\nhips_order = 4\n'
          'hips_frame = equatorial\nhips_tile_format = jpeg\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(
          isA<HipsPropertiesParseException>().having(
            (e) => e.key,
            'key',
            'hips_order',
          ),
        ),
      );
    });

    test('a line without an = separator is a surfaced error', () {
      const doc =
          'hips_order = 3\nthis is not a property\n'
          'hips_frame = equatorial\nhips_tile_format = jpeg\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('out-of-range initial dec is a surfaced error', () {
      const doc =
          'hips_order = 3\nhips_frame = equatorial\n'
          'hips_tile_format = jpeg\nhips_initial_dec = 120\n';
      expect(
        () => HipsProperties.parse(doc),
        throwsA(
          isA<HipsPropertiesParseException>().having(
            (e) => e.key,
            'key',
            'hips_initial_dec',
          ),
        ),
      );
    });
  });

  group('HipsTileId', () {
    test('value equality and hashCode by survey/norder/npix', () {
      final a = HipsTileId(survey: 'CDS/P/DSS2/red', norder: 3, npix: 42);
      final b = HipsTileId(survey: 'CDS/P/DSS2/red', norder: 3, npix: 42);
      final c = HipsTileId(survey: 'CDS/P/DSS2/blue', norder: 3, npix: 42);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect({a, b}.length, 1, reason: 'usable as set member for dedup');
    });

    test('numberOfTiles is 12 * 4^order', () {
      expect(HipsTileId.numberOfTiles(0), 12);
      expect(HipsTileId.numberOfTiles(1), 48);
      expect(HipsTileId.numberOfTiles(3), 768);
      expect(HipsTileId.numberOfTiles(9), 12 * (1 << 18));
    });

    test('directory bucket is floor(npix/10000)*10000', () {
      expect(HipsTileId(survey: 's', norder: 5, npix: 0).directoryBucket, 0);
      expect(HipsTileId(survey: 's', norder: 5, npix: 9999).directoryBucket, 0);
      expect(
        HipsTileId(survey: 's', norder: 6, npix: 10000).directoryBucket,
        10000,
      );
      expect(
        HipsTileId(survey: 's', norder: 6, npix: 25000).directoryBucket,
        20000,
      );
    });

    test('relativePath follows Norder{k}/Dir{d}/Npix{n}.{ext}', () {
      final tile = HipsTileId(survey: 's', norder: 3, npix: 42);
      expect(tile.relativePath(HipsTileFormat.jpeg), 'Norder3/Dir0/Npix42.jpg');
      expect(tile.relativePath(HipsTileFormat.png), 'Norder3/Dir0/Npix42.png');

      final deep = HipsTileId(survey: 's', norder: 6, npix: 25000);
      expect(
        deep.relativePath(HipsTileFormat.fits),
        'Norder6/Dir20000/Npix25000.fits',
      );
    });

    test('tileUrl joins base + path, normalising a trailing slash', () {
      final tile = HipsTileId(survey: 's', norder: 3, npix: 42);
      expect(
        tile.tileUrl('https://h/DSS/DSS2Merged', HipsTileFormat.jpeg),
        'https://h/DSS/DSS2Merged/Norder3/Dir0/Npix42.jpg',
      );
      expect(
        tile.tileUrl('https://h/DSS/DSS2Merged/', HipsTileFormat.jpeg),
        'https://h/DSS/DSS2Merged/Norder3/Dir0/Npix42.jpg',
      );
    });

    test('Allsky path and URL', () {
      expect(
        HipsTileId.allskyRelativePath(3, HipsTileFormat.jpeg),
        'Norder3/Allsky.jpg',
      );
      expect(
        HipsTileId.allskyUrl(
          'https://h/DSS/DSS2Merged/',
          3,
          HipsTileFormat.jpeg,
        ),
        'https://h/DSS/DSS2Merged/Norder3/Allsky.jpg',
      );
    });

    test('npix beyond the order tile count is rejected', () {
      // Order 0 has exactly 12 tiles (npix 0..11); 12 is out of range.
      expect(
        () => HipsTileId(survey: 's', norder: 0, npix: 12),
        throwsA(isA<ArgumentError>()),
      );
      // Boundary: npix 11 at order 0 is valid.
      expect(HipsTileId(survey: 's', norder: 0, npix: 11).npix, 11);
    });

    test('numberOfTiles rejects an out-of-range order', () {
      expect(() => HipsTileId.numberOfTiles(-1), throwsA(isA<ArgumentError>()));
      expect(() => HipsTileId.numberOfTiles(30), throwsA(isA<ArgumentError>()));
    });
  });

  group('HipsSurveyRegistry', () {
    test('every SurveySource is registered (exhaustive, no gaps)', () {
      expect(
        HipsSurveyRegistry.debugAssertExhaustive(),
        SurveySource.values.length,
      );
      for (final source in SurveySource.values) {
        expect(
          HipsSurveyRegistry.entries.containsKey(source),
          isTrue,
          reason: 'missing entry for $source',
        );
      }
    });

    test('hips ids match the framing hips2fits cutout mapping exactly', () {
      // Kept byte-identical to FramingNotifier._getHipsId so the tile path and
      // the single-cutout path stream the same survey.
      expect(
        HipsSurveyRegistry.hipsIdFor(SurveySource.dss2Red),
        'CDS/P/DSS2/red',
      );
      expect(
        HipsSurveyRegistry.hipsIdFor(SurveySource.dss2Blue),
        'CDS/P/DSS2/blue',
      );
      expect(
        HipsSurveyRegistry.hipsIdFor(SurveySource.dss2IR),
        'CDS/P/DSS2/NIR',
      );
      expect(
        HipsSurveyRegistry.hipsIdFor(SurveySource.sdss),
        'CDS/P/SDSS9/color',
      );
      expect(
        HipsSurveyRegistry.hipsIdFor(SurveySource.twomassJ),
        'CDS/P/2MASS/J',
      );
      expect(
        HipsSurveyRegistry.hipsIdFor(SurveySource.twomassH),
        'CDS/P/2MASS/H',
      );
      expect(
        HipsSurveyRegistry.hipsIdFor(SurveySource.twomassK),
        'CDS/P/2MASS/K',
      );
      expect(
        HipsSurveyRegistry.hipsIdFor(SurveySource.wise12),
        'CDS/P/WISE/W3',
      );
    });

    test('DSS2 red and blue expose live-verified base URLs', () {
      expect(
        HipsSurveyRegistry.verifiedBaseUrlFor(SurveySource.dss2Red),
        'https://alasky.cds.unistra.fr/DSS/DSS2Merged',
      );
      expect(
        HipsSurveyRegistry.verifiedBaseUrlFor(SurveySource.dss2Blue),
        'https://alasky.cds.unistra.fr/DSS/DSS2-blue-XJ-S',
      );
      expect(
        HipsSurveyRegistry.entryFor(SurveySource.dss2Red).hasVerifiedBaseUrl,
        isTrue,
      );
    });

    test('unverified surveys expose no fabricated base URL', () {
      for (final source in [
        SurveySource.dss2IR,
        SurveySource.sdss,
        SurveySource.twomassJ,
        SurveySource.twomassH,
        SurveySource.twomassK,
        SurveySource.wise12,
      ]) {
        expect(
          HipsSurveyRegistry.verifiedBaseUrlFor(source),
          isNull,
          reason: '$source must be resolved at runtime',
        );
        expect(HipsSurveyRegistry.entryFor(source).hasVerifiedBaseUrl, isFalse);
      }
    });

    test('candidate base URL strips the CDS/P/ registry prefix', () {
      expect(
        HipsSurveyRegistry.candidateBaseUrlFor(SurveySource.twomassJ),
        'https://alasky.cds.unistra.fr/2MASS/J',
      );
      expect(
        HipsSurveyRegistry.candidateBaseUrlFor(SurveySource.sdss),
        'https://alasky.cds.unistra.fr/SDSS9/color',
      );
      // Verified entries return their verified base URL, not a derived guess.
      expect(
        HipsSurveyRegistry.candidateBaseUrlFor(SurveySource.dss2Red),
        'https://alasky.cds.unistra.fr/DSS/DSS2Merged',
      );
    });
  });
}
