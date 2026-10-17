import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/catalogs/spatial_index.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';

Star _star(String id, double raHours, double decDeg, double mag) => Star(
  id: id,
  name: id,
  coordinates: CelestialCoordinate(ra: raHours, dec: decDeg),
  magnitude: mag,
);

void main() {
  group('StarSpatialIndex.queryBrightestInViewport', () {
    test('returns the brightest in-view stars, brightest-first, capped', () {
      final index = StarSpatialIndex();
      // In-view cluster near RA 6h / Dec 0, magnitudes 1..10.
      for (var i = 0; i < 10; i++) {
        index.add(_star('in$i', 6.0 + i * 0.01, 0.0 + i * 0.05, 1.0 + i));
      }
      // Far-away bright star that must NOT appear (other side of the sky).
      index.add(_star('far', 18.0, -60.0, 0.0));

      final result = index.queryBrightestInViewport(
        6.0,
        0.0,
        20.0,
        maxMagnitude: 12.0,
        maxResults: 3,
      );

      expect(result.length, 3, reason: 'must respect maxResults');
      // Brightest-first.
      expect(result[0].magnitude! <= result[1].magnitude!, isTrue);
      expect(result[1].magnitude! <= result[2].magnitude!, isTrue);
      // The 3 brightest in-view are in0(1.0), in1(2.0), in2(3.0).
      expect(result.map((s) => s.id), containsAll(['in0', 'in1', 'in2']));
      // The far star is out of view and must be excluded despite being brightest.
      expect(result.any((s) => s.id == 'far'), isFalse);
    });

    test('excludes stars fainter than maxMagnitude', () {
      final index = StarSpatialIndex();
      index.add(_star('bright', 6.0, 0.0, 4.0));
      index.add(_star('faint', 6.0, 0.0, 9.0));

      final result = index.queryBrightestInViewport(
        6.0,
        0.0,
        30.0,
        maxMagnitude: 6.0,
        maxResults: 100,
      );

      expect(result.map((s) => s.id), ['bright']);
    });

    test('narrow-FOV path returns same on-screen brightest set', () {
      final index = StarSpatialIndex();
      for (var i = 0; i < 50; i++) {
        index.add(
          _star(
            's$i',
            6.0 + (i - 25) * 0.001,
            0.0 + (i - 25) * 0.01,
            2.0 + i * 0.1,
          ),
        );
      }
      // 2-degree field exercises the cell-query branch (< _magWalkMinFovDegrees).
      final result = index.queryBrightestInViewport(
        6.0,
        0.0,
        2.0,
        maxMagnitude: 12.0,
        maxResults: 5,
      );
      expect(result.length, 5);
      for (var i = 0; i + 1 < result.length; i++) {
        expect(result[i].magnitude! <= result[i + 1].magnitude!, isTrue);
      }
    });
  });
}
