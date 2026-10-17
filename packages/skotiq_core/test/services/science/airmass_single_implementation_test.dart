// There must be exactly ONE airmass implementation in the product.
//
// The defect this pins was not a wrong formula, it was five right-ish formulas.
// The AAVSO exporter ran Pickering clamped to 1..40, the photometric-calibration
// wizard ran Kasten & Young 1989 clamped to 1..8, the headless host ran a third
// copy of Kasten & Young for the same wizard driven from a tablet, the automatic
// science pipeline ran a fourth, and the planner ran unclamped Pickering to the
// horizon. Every one of them was reachable for the SAME frame, and at 4 degrees
// altitude they published 12.36, 8.0, 8.0, 8.0 and 12.36 air masses respectively
// for an atmosphere that is 11.90 deep.
//
// Value tests (airmass_test.dart) cannot catch that class of defect, because a
// re-derived copy at a call site passes every test that calls the shared helper
// directly. So this file asserts two structural properties instead:
//
//   1. No library source outside the canonical file contains an airmass formula.
//      Reverting any consumer to its own copy fails here.
//   2. Each consumer that publishes an airmass still calls the shared model by
//      name. Deleting the call — the "cut the production call site and every
//      test stays green" failure — fails here.
//
// It also pins the one legitimate divergence: `AstronomyCalculations.airmass`
// layers a scheduling CONVENTION (infinity below the horizon) over the shared
// model rather than being a second model.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Walks up from the test's working directory to the repository root — the
/// directory holding both `packages/` and `apps/`. Tests run with the package
/// directory as cwd, so the depth differs between `flutter test` invocations.
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (Directory('${dir.path}/packages').existsSync() &&
        Directory('${dir.path}/apps').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('could not locate the repository root from ${Directory.current.path}');
}

/// Every shipped Dart library source in the product: `lib/` of every package
/// and app. Tests, tools and generated build output are excluded — a formula
/// in a test is a reference value, not a second implementation.
List<File> _libraryDartSources() {
  final root = _repoRoot();
  final result = <File>[];
  for (final group in const ['packages', 'apps']) {
    final groupDir = Directory('${root.path}/$group');
    if (!groupDir.existsSync()) continue;
    for (final unit in groupDir.listSync().whereType<Directory>()) {
      final lib = Directory('${unit.path}/lib');
      if (!lib.existsSync()) continue;
      result.addAll(
        lib
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => !f.path.endsWith('.g.dart'))
            .where((f) => !f.path.endsWith('.freezed.dart')),
      );
    }
  }
  expect(
    result.length,
    greaterThan(500),
    reason:
        'source scan found almost nothing — the walk is broken, and a '
        'broken walk would pass this file vacuously',
  );
  return result;
}

/// The canonical implementation. Relative to the repo root so the assertion
/// below names one exact file rather than "whichever file matched".
const String _canonicalPath =
    'packages/skotiq_planetarium/lib/src/astronomy/'
    'astronomy_calculations.dart';

/// Numeric fingerprints of the airmass formulas. Any of these appearing in a
/// library source means that file computes airmass itself.
///
///  * `0.50572` / `6.07995` / `1.6364` — Kasten & Young (1989).
///  * `1.002432` / `0.148386` / `0.0096467` — Young (1994).
///  * `47.0 * ` powf 1.1 with 244/165 — Pickering (2002); matched on its two
///    distinctive integers together so ordinary 244s and 165s do not trip it.
const List<String> _kastenYoungMarkers = ['0.50572', '6.07995', '1.6364'];
const List<String> _young1994Markers = ['1.002432', '0.148386', '0.0096467'];

bool _looksLikePickering(String source) {
  // "244 / (165 + 47" with any spacing/decimal style.
  final pattern = RegExp(r'244(\.0)?\s*/\s*\(\s*165(\.0)?\s*\+\s*47');
  return pattern.hasMatch(source);
}

String _relative(File file) {
  final rootPath = '${_repoRoot().path}/';
  return file.path.startsWith(rootPath)
      ? file.path.substring(rootPath.length)
      : file.path;
}

void main() {
  group('one airmass implementation', () {
    test('no library source but the canonical one carries an airmass formula', () {
      final offenders = <String, String>{};
      for (final file in _libraryDartSources()) {
        final relative = _relative(file);
        final source = file.readAsStringSync();

        final hits = <String>[];
        if (_kastenYoungMarkers.every(source.contains)) {
          hits.add('Kasten & Young 1989');
        }
        if (_young1994Markers.every(source.contains)) {
          hits.add('Young 1994');
        }
        if (_looksLikePickering(source)) {
          hits.add('Pickering 2002');
        }
        if (hits.isEmpty) continue;
        if (relative == _canonicalPath) continue;
        offenders[relative] = hits.join(' + ');
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'these files compute airmass themselves instead of calling '
            'airmassForTrueAltitude:\n'
            '${offenders.entries.map((e) => '  ${e.key}: ${e.value}').join('\n')}\n'
            'Four copies of this formula disagreed by 4 air masses on the same '
            'frame. Add a consumer, not a copy.',
      );
    });

    test('the canonical file really is where the formula lives', () {
      final canonical = File('${_repoRoot().path}/$_canonicalPath');
      expect(canonical.existsSync(), isTrue, reason: _canonicalPath);
      final source = canonical.readAsStringSync();
      expect(_young1994Markers.every(source.contains), isTrue);
      expect(_looksLikePickering(source), isTrue);
      expect(source.contains('double? airmassForTrueAltitude('), isTrue);
    });

    test('every publishing consumer still calls the shared model', () {
      // Each of these publishes an airmass a user or an archive can read. The
      // paths are spelled out so that deleting a call site — rather than
      // replacing it with a private copy — is also a failure here.
      const consumers = <String, String>{
        'packages/skotiq_core/lib/src/services/science/'
                'aavso_export_service.dart':
            'the AMASS column of an AAVSO upload',
        'packages/skotiq_core/lib/src/services/science/'
                'science_processing_service/private_helpers.dart':
            'the automatic science pipeline, for every frame it processes',
        'packages/skotiq_app/lib/screens/analytics/widgets/'
                'photometric_calibration_wizard/star_matching.dart':
            'the extinction fit in the in-app calibration wizard',
        'apps/desktop/lib/headless_api/handlers/science_handlers.dart':
            'the same wizard driven from a paired tablet or phone',
      };

      final root = _repoRoot().path;
      for (final entry in consumers.entries) {
        final file = File('$root/${entry.key}');
        expect(file.existsSync(), isTrue, reason: entry.key);
        expect(
          file.readAsStringSync(),
          contains('airmassForTrueAltitude('),
          reason:
              '${entry.key} publishes ${entry.value}; it must take that number '
              'from the shared model',
        );
      }
    });
  });

  group('the planner is a convention over the model, not a second model', () {
    test(
      'AstronomyCalculations.airmass is the shared model above the horizon',
      () {
        for (final altitude in [89.0, 60.0, 30.0, 15.0, 10.0, 9.0, 4.0, 1.0]) {
          expect(
            AstronomyCalculations.airmass(altitude),
            airmassForTrueAltitude(altitude),
            reason:
                'planner airmass must equal the product model at $altitude°',
          );
        }
        // Pickering unclamped reads 38.75 at the horizon against the model's
        // 31.74 — a 22% disagreement with the AIRMASS card of the frame the
        // planner just told the operator to take.
        expect(AstronomyCalculations.airmass(0.5), lessThan(32.0));
      },
    );

    test('below the horizon it reports infinity, by documented policy', () {
      // Deliberate divergence from the model's `null`: weighted target scoring
      // drives an unobservable target to zero without special-casing a null.
      expect(AstronomyCalculations.airmass(0.0), double.infinity);
      expect(AstronomyCalculations.airmass(-10.0), double.infinity);
      expect(airmassForTrueAltitude(-10.0), isNull);
    });
  });
}
