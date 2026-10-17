// Strict HiPS `properties` parsing.
//
// The `properties` document is the survey's self-description; the tile layer
// drives LOD selection ([hips_order]/[hips_order_min]), tile addressing
// ([hips_tile_width]/[hips_tile_format]) and frame handling ([hips_frame]) from
// it. A missing required key, a malformed value, an out-of-range value, a
// duplicate key, or a syntactically broken line must surface as a
// [HipsPropertiesParseException] — a guessed default mis-levels or
// mis-addresses tiles instead.
//
// The only tolerated defaults are the two the IVOA HiPS 1.0 standard documents:
// `hips_order_min = 0` (silent, standard) and `hips_tile_width = 512` (applied
// AND logged, with the [tileWidthWasDefaulted] flag exposed so the fallback is
// observable). This suite pins all of that, plus the realistic CDS DSS2-style
// happy path, line continuation, comments, and optional attribution/initial-view
// keys.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';

void main() {
  group('happy path (CDS DSS2-style document)', () {
    test('parses a complete, well-formed properties document', () {
      final props = HipsProperties.parse('''
# CDS DSS2 red, abbreviated properties
creator_did       = ivo://CDS/P/DSS2/red
obs_title         = DSS2 red
hips_order        = 9
hips_order_min    = 3
hips_tile_width   = 512
hips_tile_format  = jpeg fits
hips_frame        = equatorial
obs_copyright     = DSS2 / STScI
obs_copyright_url = https://archive.stsci.edu/dss/
hips_creator      = CDS (Strasbourg)
hips_initial_ra   = 83.822
hips_initial_dec  = -5.391
hips_initial_fov  = 1.5
''');

      expect(props.hipsOrder, 9);
      expect(props.hipsOrderMin, 3);
      expect(props.tileWidth, 512);
      expect(props.tileWidthWasDefaulted, isFalse);
      expect(props.tileFormats, [HipsTileFormat.jpeg, HipsTileFormat.fits]);
      expect(props.preferredFormat, HipsTileFormat.jpeg);
      expect(props.hasJpeg, isTrue);
      expect(props.hasPng, isFalse);
      expect(props.frame, HipsFrame.equatorial);
      expect(props.obsCopyright, 'DSS2 / STScI');
      expect(props.obsCopyrightUrl, 'https://archive.stsci.edu/dss/');
      expect(props.creator, 'CDS (Strasbourg)');
      expect(props.initialRaDeg, closeTo(83.822, 1e-9));
      expect(props.initialDecDeg, closeTo(-5.391, 1e-9));
      expect(props.initialFovDeg, closeTo(1.5, 1e-9));
    });

    test('accepts both key=value and key = value spacing', () {
      final props = HipsProperties.parse('''
hips_order=4
hips_tile_format =png
hips_frame = galactic
''');
      expect(props.hipsOrder, 4);
      expect(props.tileFormats, [HipsTileFormat.png]);
      expect(props.frame, HipsFrame.galactic);
    });

    test('honours # comments and blank lines', () {
      final props = HipsProperties.parse('''

# a comment
hips_order = 6

   # indented comment
hips_tile_format = jpeg
hips_frame = equatorial
''');
      expect(props.hipsOrder, 6);
    });

    test('honours backslash line continuation in a value', () {
      final props = HipsProperties.parse('''
hips_order = 5
hips_tile_format = jpeg
hips_frame = equatorial
obs_copyright = Line one \\
continued here
''');
      // The backslash is stripped but the space before it is preserved, and the
      // continued line is trimmed, so the two fragments join as "...one " + "continued...".
      expect(props.obsCopyright, 'Line one continued here');
    });
  });

  group('standard documented defaults', () {
    test('hips_order_min defaults to 0 when absent (silent, standard)', () {
      final props = HipsProperties.parse('''
hips_order = 7
hips_tile_format = jpeg
hips_frame = equatorial
''');
      expect(props.hipsOrderMin, HipsProperties.defaultOrderMin);
      expect(props.hipsOrderMin, 0);
    });

    test('hips_tile_width defaults to 512 and flags the fallback', () {
      final props = HipsProperties.parse('''
hips_order = 7
hips_tile_format = jpeg
hips_frame = equatorial
''');
      expect(props.tileWidth, HipsProperties.defaultTileWidth);
      expect(props.tileWidth, 512);
      expect(props.tileWidthWasDefaulted, isTrue);
    });
  });

  group('required keys are mandatory (malformed surfaces error)', () {
    test('missing hips_order throws', () {
      expect(
        () => HipsProperties.parse('''
hips_tile_format = jpeg
hips_frame = equatorial
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('missing hips_tile_format throws', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 5
hips_frame = equatorial
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('empty hips_tile_format throws', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 5
hips_tile_format =
hips_frame = equatorial
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('missing hips_frame throws', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 5
hips_tile_format = jpeg
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });
  });

  group('malformed / out-of-range values surface errors', () {
    test('non-integer hips_order throws', () {
      expect(
        () => HipsProperties.parse('''
hips_order = nine
hips_tile_format = jpeg
hips_frame = equatorial
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('out-of-range hips_order throws', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 30
hips_tile_format = jpeg
hips_frame = equatorial
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('hips_order_min above hips_order throws', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 5
hips_order_min = 6
hips_tile_format = jpeg
hips_frame = equatorial
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('non-power-of-two hips_tile_width throws', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 5
hips_tile_width = 500
hips_tile_format = jpeg
hips_frame = equatorial
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('unrecognised hips_frame throws (no coercion to equatorial)', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 5
hips_tile_format = jpeg
hips_frame = supergalactic
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('hips_tile_format with only unknown tokens throws', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 5
hips_tile_format = tiff webp
hips_frame = equatorial
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('an out-of-range optional initial value throws', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 5
hips_tile_format = jpeg
hips_frame = equatorial
hips_initial_dec = 120
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });
  });

  group('document syntax errors surface', () {
    test('a line with no = is malformed', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 5
this line has no equals sign
hips_tile_format = jpeg
hips_frame = equatorial
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });

    test('a duplicate key is rejected (not last-write-wins)', () {
      expect(
        () => HipsProperties.parse('''
hips_order = 5
hips_order = 6
hips_tile_format = jpeg
hips_frame = equatorial
'''),
        throwsA(isA<HipsPropertiesParseException>()),
      );
    });
  });

  group('tile format token parsing', () {
    test('accepts the jpg alias for jpeg and dedups', () {
      final props = HipsProperties.parse('''
hips_order = 5
hips_tile_format = jpg jpeg png
hips_frame = equatorial
''');
      // jpg and jpeg collapse to a single jpeg entry, preserving order.
      expect(props.tileFormats, [HipsTileFormat.jpeg, HipsTileFormat.png]);
    });

    test('skips unknown tokens but keeps recognised ones', () {
      final props = HipsProperties.parse('''
hips_order = 5
hips_tile_format = tiff png fits
hips_frame = equatorial
''');
      expect(props.tileFormats, [HipsTileFormat.png, HipsTileFormat.fits]);
    });
  });

  group('frame and format enum parsing', () {
    test('HipsFrame.tryParse is case/space tolerant and strict on unknown', () {
      expect(HipsFrame.tryParse('  Equatorial '), HipsFrame.equatorial);
      expect(HipsFrame.tryParse('GALACTIC'), HipsFrame.galactic);
      expect(HipsFrame.tryParse('ecliptic'), HipsFrame.ecliptic);
      expect(HipsFrame.tryParse('mystery'), isNull);
    });

    test('HipsTileFormat.tryParse covers jpeg/jpg/png/fits and unknown', () {
      expect(HipsTileFormat.tryParse('jpeg'), HipsTileFormat.jpeg);
      expect(HipsTileFormat.tryParse('JPG'), HipsTileFormat.jpeg);
      expect(HipsTileFormat.tryParse('png'), HipsTileFormat.png);
      expect(HipsTileFormat.tryParse('fits'), HipsTileFormat.fits);
      expect(HipsTileFormat.tryParse('bmp'), isNull);
    });
  });

  group('allskyOrder (whole-sky base-layer order)', () {
    test(
      'is the standard Allsky order (3), NOT hips_order_min, when the survey '
      'omits/declares a lower hips_order_min',
      () {
        // The real CDS DSS pyramids declare hips_order_min=0 yet 404 on
        // Norder0/Allsky.jpg, publishing the Allsky only at the conventional
        // Norder3. allskyOrder must therefore be 3 here, not 0 — otherwise the
        // never-blank base layer would never load for the default DSS2 survey.
        final omitsMin = HipsProperties.parse('''
hips_order        = 9
hips_tile_width   = 512
hips_tile_format  = jpeg
hips_frame        = equatorial
''');
        expect(
          omitsMin.hipsOrderMin,
          0,
          reason: 'absent hips_order_min defaults to 0 per the standard',
        );
        expect(omitsMin.allskyOrder, HipsProperties.standardAllskyOrder);
        expect(omitsMin.allskyOrder, 3);

        final lowMin = HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 1
hips_tile_width   = 512
hips_tile_format  = jpeg
hips_frame        = equatorial
''');
        expect(
          lowMin.allskyOrder,
          3,
          reason: 'a low hips_order_min does not pull the Allsky order down',
        );
      },
    );

    test(
      'clamps into the survey published range for shallow/deep min surveys',
      () {
        // A survey whose deepest order is below the standard Allsky order cannot
        // publish an Allsky deeper than hips_order: clamp down to hips_order.
        final shallow = HipsProperties.parse('''
hips_order        = 2
hips_tile_format  = jpeg
hips_frame        = equatorial
''');
        expect(
          shallow.allskyOrder,
          2,
          reason: 'cannot exceed the deepest published order',
        );

        // A survey whose minimum published order exceeds 3: the Allsky cannot be
        // coarser than the survey's own minimum, so clamp up to hips_order_min.
        final deepMin = HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 5
hips_tile_width   = 512
hips_tile_format  = jpeg
hips_frame        = equatorial
''');
        expect(
          deepMin.allskyOrder,
          5,
          reason: 'cannot be coarser than the survey minimum order',
        );
      },
    );
  });

  group('value semantics', () {
    test('equal documents parse to equal values (Equatable)', () {
      const doc = '''
hips_order = 8
hips_order_min = 2
hips_tile_width = 1024
hips_tile_format = png
hips_frame = galactic
''';
      expect(HipsProperties.parse(doc), HipsProperties.parse(doc));
      expect(
        HipsProperties.parse(doc).hashCode,
        HipsProperties.parse(doc).hashCode,
      );
    });
  });
}
