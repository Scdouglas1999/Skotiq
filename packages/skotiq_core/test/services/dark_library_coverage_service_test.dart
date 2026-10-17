import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('DarkLibraryCoverageService', () {
    test('reports missing requirements with no matching darks', () {
      const service = DarkLibraryCoverageService();

      final report = service.evaluate(
        requirements: const [
          DarkFrameRequirement(
            gain: 100,
            offset: 10,
            durationSecs: 180,
            binX: 1,
            binY: 1,
            targetTemp: -10,
          ),
        ],
        entries: const [],
        minCoverage: 10,
      );

      expect(report.isCovered, isFalse);
      expect(report.missing, hasLength(1));
      expect(report.underCovered, isEmpty);
      expect(report.missing.single.describe(), contains('duration=180s'));
    });

    test('treats a master dark inside tolerance as covered', () {
      const service = DarkLibraryCoverageService();

      // The unified defaults are ±0.5s / ±1.0°C: the sample sits inside that
      // exposure window (180.3) and outside a ±0.5°C temperature window
      // (-9.2), so it only matches when both unified values are honoured.
      final report = service.evaluate(
        requirements: const [
          DarkFrameRequirement(
            gain: 100,
            offset: 10,
            durationSecs: 180,
            binX: 1,
            binY: 1,
            targetTemp: -10,
          ),
        ],
        entries: [
          _dark(
            exposureTime: 180.3,
            gain: 100,
            offset: 10,
            temperature: -9.2,
            masterDarkPath: '/tmp/master.fits',
          ),
        ],
        minCoverage: 10,
      );

      expect(report.isCovered, isTrue);
      expect(report.missing, isEmpty);
      expect(report.underCovered, isEmpty);
    });

    test('reports raw dark coverage below the configured quorum', () {
      const service = DarkLibraryCoverageService();
      const requirement = DarkFrameRequirement(
        gain: 100,
        offset: 10,
        durationSecs: 180,
        binX: 1,
        binY: 1,
        targetTemp: -10,
      );

      final report = service.evaluate(
        requirements: const [requirement],
        entries: List.generate(
          3,
          (index) =>
              _dark(exposureTime: 180, gain: 100, offset: 10, temperature: -10),
        ),
        minCoverage: 10,
      );

      expect(report.isCovered, isFalse);
      expect(report.missing, isEmpty);
      expect(report.underCovered, {requirement: 3});
    });

    test('regression: exact-exposure-and-temperature match counts as'
        'covered with the default tolerances', () {
      // The coverage UI and DarkLibraryDao.findBestMatch must agree on the
      // same 60.0s/60.0s pair: different tolerances have the UI claim "all
      // darks present" while the runtime match returns null on
      // floating-point representation alone.
      const service = DarkLibraryCoverageService();
      const requirement = DarkFrameRequirement(
        gain: 100,
        offset: 10,
        durationSecs: 60.0,
        binX: 1,
        binY: 1,
        targetTemp: -10,
      );

      final report = service.evaluate(
        requirements: const [requirement],
        entries: [
          _dark(
            exposureTime: 60.0,
            gain: 100,
            offset: 10,
            temperature: -10,
            masterDarkPath: '/tmp/master_60s.fits',
          ),
        ],
        minCoverage: 10,
      );

      expect(
        report.isCovered,
        isTrue,
        reason:
            'a 60.0s dark MUST match a 60.0s request — this was the '
            ' failure mode',
      );
    });

    test('exposure delta beyond the configured tolerance is not covered', () {
      const service = DarkLibraryCoverageService();
      const requirement = DarkFrameRequirement(
        gain: 100,
        offset: 10,
        durationSecs: 60.0,
        binX: 1,
        binY: 1,
        targetTemp: -10,
      );

      // 60.0 vs 60.6 — outside ±0.5s default.
      final report = service.evaluate(
        requirements: const [requirement],
        entries: [
          _dark(
            exposureTime: 60.6,
            gain: 100,
            offset: 10,
            temperature: -10,
            masterDarkPath: '/tmp/master_606.fits',
          ),
        ],
        minCoverage: 10,
      );

      expect(report.isCovered, isFalse);
      expect(report.missing, hasLength(1));
    });

    test('honors a caller-supplied tolerances override', () {
      // Wider tolerances let a 60.0-vs-60.6 pair count as covered.
      const service = DarkLibraryCoverageService();
      const requirement = DarkFrameRequirement(
        gain: 100,
        offset: 10,
        durationSecs: 60.0,
        binX: 1,
        binY: 1,
        targetTemp: -10,
      );

      final report = service.evaluate(
        requirements: const [requirement],
        entries: [
          _dark(
            exposureTime: 60.6,
            gain: 100,
            offset: 10,
            temperature: -10,
            masterDarkPath: '/tmp/master_606.fits',
          ),
        ],
        minCoverage: 10,
        tolerances: const DarkLibraryMatchTolerances(
          exposureSecs: 1.0,
          temperatureC: 1.0,
        ),
      );

      expect(report.isCovered, isTrue);
    });
  });

  group('DarkLibraryMatchTolerances', () {
    test('defaults are ±0.5s exposure and ±1.0°C temperature', () {
      const t = DarkLibraryMatchTolerances.defaults;
      expect(t.exposureSecs, 0.5);
      expect(t.temperatureC, 1.0);
    });

    test('validated() throws on negative exposure tolerance', () {
      expect(
        () => DarkLibraryMatchTolerances.validated(
          exposureSecs: -0.1,
          temperatureC: 1.0,
        ),
        throwsArgumentError,
      );
    });

    test('validated() throws on negative temperature tolerance', () {
      expect(
        () => DarkLibraryMatchTolerances.validated(
          exposureSecs: 0.5,
          temperatureC: -0.5,
        ),
        throwsArgumentError,
      );
    });

    test('validated() throws on NaN or infinite values', () {
      expect(
        () => DarkLibraryMatchTolerances.validated(
          exposureSecs: double.nan,
          temperatureC: 1.0,
        ),
        throwsArgumentError,
      );
      expect(
        () => DarkLibraryMatchTolerances.validated(
          exposureSecs: 0.5,
          temperatureC: double.infinity,
        ),
        throwsArgumentError,
      );
    });
  });
}

DarkLibraryEntry _dark({
  required double exposureTime,
  int gain = 100,
  int offset = 10,
  int binX = 1,
  int binY = 1,
  double? temperature,
  String? masterDarkPath,
}) {
  return DarkLibraryEntry(
    id: 1,
    filePath: '/tmp/dark.fits',
    exposureTime: exposureTime,
    frameType: 'dark',
    temperature: temperature,
    gain: gain,
    offset: offset,
    binX: binX,
    binY: binY,
    width: 100,
    height: 100,
    masterDarkPath: masterDarkPath,
    masterFrameCount: masterDarkPath == null ? null : 10,
    createdAt: DateTime(2026),
  );
}
