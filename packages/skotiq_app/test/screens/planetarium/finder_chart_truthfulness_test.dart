// An exported finder chart must describe the sky it actually shows.
//
// With HIP42327 selected and the view panned to RA 0h / Dec 0 at 1.5 deg FOV,
// "Export finder chart" writes a PDF titled "Finder Chart: HIP42327" whose
// footer reads "Center: 0h 0m 0.0s +0d 0' 0"" — the view centre, 8h37m of RA and
// 19 deg of Dec from the named object, which appears nowhere on the chart. A
// hard-coded `fieldOfView < 10 ? 12.0 : 6.0` likewise claims "Mag limit: 12.0"
// over a chart holding about six stars, without consulting the plotted data.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/providers/finder_chart_catalog_provider.dart';
import 'package:skotiq_app/services/finder_chart_service.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// HIP42327: RA 8h37m46.7s, Dec +19d16'02".
const _subject = CelestialCoordinate(
  ra: 8 + 37 / 60 + 46.7 / 3600,
  dec: 19 + 16 / 60 + 2 / 3600,
);

Star _star(String id, double mag) => Star(
      id: id,
      name: id,
      coordinates: const CelestialCoordinate(ra: 8.6, dec: 19.2),
      magnitude: mag,
    );

void main() {
  group('finderChartPose', () {
    test('centres the chart on the object it is titled for', () {
      // The view is pointed somewhere else entirely.
      const view = SkyViewState(centerRA: 0, centerDec: 0, fieldOfView: 1.5);

      final (region: region, pose: pose) = finderChartPose(
        viewState: view,
        viewCenter: (0, 0),
        subject: _subject,
      );

      expect(region.centerRaHours, closeTo(_subject.ra, 1e-9));
      expect(region.centerDecDeg, closeTo(_subject.dec, 1e-9));
      expect(region.fovDeg, 1.5);
      // The rendered pose has to agree with the printed header, or the PDF is
      // titled for one patch of sky and filled with another.
      expect(pose.centerRA, closeTo(_subject.ra, 1e-9));
      expect(pose.centerDec, closeTo(_subject.dec, 1e-9));
    });

    test('falls back to the live view centre when nothing is selected', () {
      const view = SkyViewState(centerRA: 3, centerDec: -4, fieldOfView: 20);

      final (region: region, pose: pose) = finderChartPose(
        viewState: view,
        viewCenter: (3, -4),
      );

      expect(region.centerRaHours, 3);
      expect(region.centerDecDeg, -4);
      expect(pose.centerRA, 3);
      expect(pose.centerDec, -4);
    });

    test(
      'in the horizontal frame it uses the live centre, not the stale '
      'equatorial pose',
      () {
        // centerRA/centerDec hold the PRESERVED INACTIVE equatorial pose here.
        const view = SkyViewState(
          centerRA: 0,
          centerDec: 0,
          viewMode: SkyViewMode.horizontal,
          centerAz: 134,
          centerAltitude: 90,
          fieldOfView: 60,
        );

        final (region: region, pose: pose) = finderChartPose(
          viewState: view,
          // What viewCenterEquatorialProvider computes for that camera.
          viewCenter: (7.34, 40.0),
        );

        expect(region.centerRaHours, 7.34);
        expect(region.centerDecDeg, 40.0);
        expect(
          pose.centerRA,
          7.34,
          reason: 'printing 0h here is the original bug',
        );
        expect(
          pose.viewMode,
          SkyViewMode.equatorial,
          reason: 'a chart is a RA/Dec artifact; rendering it through the '
              'horizontal projection would key it to an instant instead',
        );
      },
    );

    test('everything else about the view is carried through unchanged', () {
      const view = SkyViewState(
        centerRA: 1,
        centerDec: 2,
        fieldOfView: 4.5,
        rotation: 33,
        projection: SkyProjection.orthographic,
      );

      final (region: _, pose: pose) = finderChartPose(
        viewState: view,
        viewCenter: (1, 2),
        subject: _subject,
      );

      expect(pose.fieldOfView, 4.5);
      expect(pose.rotation, 33);
      expect(pose.projection, SkyProjection.orthographic);
    });
  });

  group('printed magnitude depth', () {
    test('reports the faintest object actually plotted', () {
      final faintest = FinderChartService.faintestPlottedMagnitude(
        stars: [_star('a', 4.2), _star('b', 7.9), _star('c', 6.1)],
        dsos: const [],
      );
      expect(faintest, 7.9);
    });

    test('a sparse chart does not claim mag 12', () {
      // A 1.5 deg FOV over a field the loaded catalogs only fill to ~mag 8: a
      // field-of-view formula would print 12.0 here.
      final faintest = FinderChartService.faintestPlottedMagnitude(
        stars: [_star('a', 6.4), _star('b', 8.0)],
        dsos: const [],
      );
      expect(faintest, 8.0);
      expect(faintest, lessThan(12.0));
    });

    test('an empty field reports nothing rather than a number', () {
      expect(
        FinderChartService.faintestPlottedMagnitude(stars: [], dsos: const []),
        isNull,
      );
    });

    test('objects with no catalogued magnitude are not counted', () {
      final faintest = FinderChartService.faintestPlottedMagnitude(
        stars: [
          _star('a', 5.0),
          const Star(
            id: 'nomag',
            name: 'nomag',
            coordinates: CelestialCoordinate(ra: 8.6, dec: 19.2),
          ),
        ],
        dsos: const [],
      );
      expect(faintest, 5.0);
    });

    test('DSOs count toward the depth too', () {
      final faintest = FinderChartService.faintestPlottedMagnitude(
        stars: [_star('a', 5.0)],
        dsos: [
          const DeepSkyObject(
            id: 'ngc1',
            name: 'NGC 1',
            coordinates: CelestialCoordinate(ra: 8.6, dec: 19.2),
            type: DsoType.galaxy,
            magnitude: 11.2,
          ),
        ],
      );
      expect(faintest, 11.2);
    });
  });
}
