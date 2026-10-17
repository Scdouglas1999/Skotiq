// Tests for the horizon obstruction-profile import parsers used by Feature 3
// (backyard horizon mask). The 8-point compass profile lives in
// settings_provider.dart and is exported through the barrel under the
// `LegacyHorizonProfile` alias; we import the source directly here to reach
// the factory constructors without the alias.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

void main() {
  group('HorizonProfile.parseHorizonText', () {
    test('parses Stellarium-style .hor whitespace pairs', () {
      const hor = '''
# A backyard skyline
0   25
90  10
180 5
270 15
''';
      final profile = HorizonProfile.parseHorizonText(hor);
      expect(profile.altitudeAt('N'), 25);
      expect(profile.altitudeAt('E'), 10);
      expect(profile.altitudeAt('S'), 5);
      expect(profile.altitudeAt('W'), 15);
      expect(profile.isFlat, isFalse);
    });

    test('parses CSV pairs and ignores comment / blank lines', () {
      const csv = '''
// azimuth,altitude
45,30

135,20
;trailing comment
''';
      final profile = HorizonProfile.parseHorizonText(csv);
      expect(profile.altitudeAt('NE'), 30);
      expect(profile.altitudeAt('SE'), 20);
      // Untouched sectors stay open sky.
      expect(profile.altitudeAt('N'), 0);
      expect(profile.altitudeAt('W'), 0);
    });

    test('bins multiple samples into a sector by taking the maximum', () {
      // Three samples land in the N sector (337.5°-22.5°); the tallest wins so
      // the obstruction is never under-reported.
      const hor = '0 8\n10 22\n350 14';
      final profile = HorizonProfile.parseHorizonText(hor);
      expect(profile.altitudeAt('N'), 22);
    });

    test('wraps azimuths past 360 and below 0 onto the right sector', () {
      const hor = '360 12\n-90 18';
      final profile = HorizonProfile.parseHorizonText(hor);
      expect(profile.altitudeAt('N'), 12); // 360 -> 0 -> N
      expect(profile.altitudeAt('W'), 18); // -90 -> 270 -> W
    });

    test('clamps altitudes into the valid 0-89 range', () {
      const hor = '0 120\n90 -5';
      final profile = HorizonProfile.parseHorizonText(hor);
      expect(profile.altitudeAt('N'), 89);
      expect(profile.altitudeAt('E'), 0);
    });

    test('round-trips through JSON', () {
      const hor = '0 25\n180 5';
      final profile = HorizonProfile.parseHorizonText(hor);
      final restored = HorizonProfile.fromJson(profile.toJson());
      expect(restored.altitudeAt('N'), 25);
      expect(restored.altitudeAt('S'), 5);
    });

    test('throws on a non-numeric field', () {
      expect(
        () => HorizonProfile.parseHorizonText('0 abc'),
        throwsFormatException,
      );
    });

    test('throws on a line with too few fields', () {
      expect(
        () => HorizonProfile.parseHorizonText('42'),
        throwsFormatException,
      );
    });

    test('throws when no usable samples are present', () {
      expect(
        () => HorizonProfile.parseHorizonText('# only comments\n\n'),
        throwsFormatException,
      );
    });
  });

  // An imported survey must keep its samples, not collapse to the eight
  // sector maxima: one 29° tree at azimuth 190 would otherwise block the whole
  // S sector (157.5°–202.5°). `altitudeAtAzimuth` is the single question every
  // visibility decision asks — the planner's filter and the planetarium's
  // 360-entry terrain table both call it — so these pin its answer.
  group('imported surveys keep their resolution', () {
    /// One sample every 10°, flat 5° except a 29° obstruction at azimuth 190.
    String thirtySix() {
      final lines = <String>[];
      for (var az = 0; az < 360; az += 10) {
        lines.add('$az ${az == 190 ? 29 : 5}');
      }
      return lines.join('\n');
    }

    test('a sample-backed profile answers at the file resolution', () {
      final profile = HorizonProfile.parseHorizonText(thirtySix());

      expect(profile.sampleCount, 36);
      // The summary the settings page shows is unchanged: sector maximum.
      expect(profile.altitudeAt('S'), 29);
      // ...but a target 30° away from the tree is not refused any more.
      expect(profile.altitudeAtAzimuth(190), closeTo(29, 1e-9));
      expect(profile.altitudeAtAzimuth(160), closeTo(5, 1e-9));
      expect(profile.altitudeAtAzimuth(220), closeTo(5, 1e-9));
      expect(profile.isAboveHorizon(10, 160), isTrue);
      expect(profile.isAboveHorizon(10, 190), isFalse);
    });

    test('between samples it interpolates linearly, wrapping at 360', () {
      final profile = HorizonProfile.parseHorizonText('0 10\n180 30');
      expect(profile.altitudeAtAzimuth(90), closeTo(20, 1e-9));
      // 270 is halfway back round the wrap from 180 to 360/0.
      expect(profile.altitudeAtAzimuth(270), closeTo(20, 1e-9));
      expect(profile.altitudeAtAzimuth(0), closeTo(10, 1e-9));
      expect(profile.altitudeAtAzimuth(360), closeTo(10, 1e-9));
    });

    test('the samples survive the JSON round trip', () {
      final profile = HorizonProfile.parseHorizonText(thirtySix());
      final restored = HorizonProfile.fromJson(profile.toJson());

      expect(restored.sampleCount, 36);
      expect(restored.altitudeAtAzimuth(160), closeTo(5, 1e-9));
      expect(restored.altitudeAt('S'), 29);
    });

    test('an 8-key blob with no samples still reads as the coarse mask', () {
      const legacy =
          '{"N":25.0,"NE":0.0,"E":0.0,"SE":0.0,'
          '"S":29.0,"SW":0.0,"W":0.0,"NW":0.0}';
      final profile = HorizonProfile.fromJson(legacy);

      expect(profile.sampleCount, 0);
      expect(profile.altitudeAt('S'), 29);
      // Smoothstep across the sector, exactly as before.
      expect(profile.altitudeAtAzimuth(180), closeTo(29, 1e-9));
      expect(profile.altitudeAtAzimuth(0), closeTo(25, 1e-9));
    });

    test('a hand-edited eight-value mask carries no samples', () {
      final profile = HorizonProfile({
        for (final dir in horizonDirections) dir: 12.0,
      });
      expect(profile.sampleCount, 0);
      expect(profile.toJson().contains('samples'), isFalse);
      expect(profile.altitudeAtAzimuth(190), closeTo(12, 1e-9));
    });

    test('a single sample is a flat horizon, not an interpolation', () {
      final profile = HorizonProfile.parseHorizonText('180 21');
      expect(profile.sampleCount, 0);
      expect(profile.altitudeAt('S'), 21);
    });

    test('a truncated blob still yields the compass values it has', () {
      final profile = HorizonProfile.fromJson('{"N":25.0,"S":29.0');
      expect(profile.altitudeAt('N'), 25);
      expect(profile.altitudeAt('S'), 29);
    });
  });
}
