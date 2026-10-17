import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Dart half of the shared `.wcs` conformance fixture.
///
/// The golden headers and the expected parses live in
/// `test_fixtures/wcs_conformance/` at the repo root and are read by BOTH this
/// suite and
/// `native/skotiq_native/imaging/src/platesolve_wcs_conformance_tests.rs`.
/// The two `.wcs` parsers drift apart easily: a Rust side that card-splits a
/// terminator-free FITS header while the Dart side splits on newlines reports
/// every successful ASTAP solve as a failure and takes the run with it. This
/// fixture turns that drift into a red build instead of a lost night.
///
/// Divergences between the two parsers are recorded in each case's `divergence`
/// field rather than papered over — see the fixture README.
void main() {
  // Loaded eagerly: the case list drives test *declaration*, so it cannot wait
  // for setUpAll.
  final fixtureRoot = _locateFixtureRoot();
  final doc =
      jsonDecode(File('${fixtureRoot.path}/cases.json').readAsStringSync())
          as Map<String, dynamic>;
  final cases = (doc['cases'] as List<dynamic>).cast<Map<String, dynamic>>();

  late ProviderContainer container;
  late PlateSolveService service;

  setUp(() {
    container = ProviderContainer();
    service = container.read(plateSolveServiceProvider);
  });

  tearDown(() => container.dispose());

  test('the fixture is the one the Rust suite reads', () {
    expect(doc['version'], 1);
    expect(
      cases,
      isNotEmpty,
      reason: 'an empty fixture would make this suite vacuously green',
    );
    for (final c in cases) {
      expect(
        File('${fixtureRoot.path}/${c['file']}').existsSync(),
        isTrue,
        reason: 'missing golden header for ${c['id']}',
      );
    }
  });

  group('card split matches the Rust fits_header_cards', () {
    for (final c in cases) {
      test(c['id'] as String, () {
        final content = File(
          '${fixtureRoot.path}/${c['file']}',
        ).readAsStringSync();
        final cards = fitsHeaderCardsForTest(content);
        final expected = c['cards'] as Map<String, dynamic>;

        expect(
          cards.length,
          expected['count'],
          reason:
              'card count drifted for ${c['id']}; a split boundary moved and '
              'every keyword after it changes meaning',
        );
        expect(
          cards.map((card) => card.length).reduce((a, b) => a > b ? a : b),
          expected['max_length'],
          reason: 'no card may exceed 80 characters',
        );
        (expected['at'] as Map<String, dynamic>).forEach((index, text) {
          expect(
            cards[int.parse(index)],
            text,
            reason: 'card $index of ${c['id']} is not byte-identical',
          );
        });
      });
    }

    test('a terminator-free header splits to the same cards as a CRLF one', () {
      // The separator a solver happens to use must not change a single card.
      final stream = fitsHeaderCardsForTest(
        File(
          '${fixtureRoot.path}/cases/astap_card_stream.wcs',
        ).readAsStringSync(),
      );
      final crlf = fitsHeaderCardsForTest(
        File(
          '${fixtureRoot.path}/cases/astap_crlf_delimited.wcs',
        ).readAsStringSync(),
      );
      expect(crlf, stream);
    });
  });

  group('parse matches the pinned Dart expectations', () {
    for (final c in cases) {
      test(c['id'] as String, () async {
        final expected = c['dart'] as Map<String, dynamic>;
        final result = await service.parseWcsFileForTest(
          '${fixtureRoot.path}/${c['file']}',
        );

        expect(
          result.success,
          expected['success'],
          reason: '${c['id']}: ${c['why']}\nerror was: ${result.error}',
        );
        // Verbatim fields are read straight out of a card: exact equality.
        _expectExact(result.ra, expected['ra'], '${c['id']} ra');
        _expectExact(result.dec, expected['dec'], '${c['id']} dec');
        // Derived fields: 1e-9.
        _expectClose(
          result.pixelScale,
          expected['pixel_scale'],
          '${c['id']} pixelScale',
        );
        _expectClose(
          result.rotation,
          expected['rotation'],
          '${c['id']} rotation',
        );

        // The Dart parser never recovers a CD matrix or SIP terms — it reads
        // CRVAL/CDELT/CROTA only. That is the standing contract (pinned by
        // plate_solve_service_test.dart) and the fixture's `divergence` notes
        // depend on it staying true.
        expect(result.cd11, 0);
        expect(result.cd12, 0);
        expect(result.cd21, 0);
        expect(result.cd22, 0);
        expect(result.sipACoeffs, isEmpty);
        expect(result.sipBCoeffs, isEmpty);
        expect(result.sipApCoeffs, isEmpty);
        expect(result.sipBpCoeffs, isEmpty);
      });
    }
  });

  test('every divergence from the Rust parser is documented', () {
    // A case whose two sides disagree MUST carry a written reason. This is the
    // rule that keeps the fixture honest: an undocumented disagreement is a bug
    // report, not a passing test.
    for (final c in cases) {
      final dart = c['dart'] as Map<String, dynamic>;
      final rust = c['rust'] as Map<String, dynamic>;
      final dartSucceeded = dart['success'] as bool;
      final rustSucceeded = rust['outcome'] == 'ok';
      if (dartSucceeded != rustSucceeded) {
        expect(
          c['divergence'],
          isA<String>(),
          reason:
              '${c['id']}: Dart says success=$dartSucceeded and Rust says '
              '${rust['outcome']}; that has to be explained in the fixture',
        );
        continue;
      }
      if (dartSucceeded && rustSucceeded) {
        // Position is the one thing they must never disagree about: a solve is
        // the same solve whichever parser read it.
        _expectExact(rust['ra'], dart['ra'], '${c['id']} ra agreement');
        _expectExact(rust['dec'], dart['dec'], '${c['id']} dec agreement');
        final agree =
            _sameNumber(rust['pixel_scale'], dart['pixel_scale']) &&
            _sameNumber(rust['rotation'], dart['rotation']);
        if (!agree) {
          expect(
            c['divergence'],
            isA<String>(),
            reason:
                '${c['id']}: the two parsers report different scale/rotation '
                'and the fixture does not say why',
          );
        }
      }
    }
  });
}

/// `"nan"` stands in for NaN, which JSON cannot express.
double _expectedDouble(Object? raw) {
  if (raw == 'nan') return double.nan;
  return (raw as num).toDouble();
}

bool _sameNumber(Object? a, Object? b) {
  final x = _expectedDouble(a);
  final y = _expectedDouble(b);
  if (x.isNaN && y.isNaN) return true;
  return (x - y).abs() <= 1e-9;
}

void _expectExact(Object? actual, Object? expected, String label) {
  final want = _expectedDouble(expected);
  final got = actual is num ? actual.toDouble() : _expectedDouble(actual);
  if (want.isNaN) {
    expect(got.isNaN, isTrue, reason: '$label must be NaN, was $got');
    return;
  }
  expect(got, want, reason: label);
}

void _expectClose(Object? actual, Object? expected, String label) {
  final want = _expectedDouble(expected);
  final got = actual is num ? actual.toDouble() : _expectedDouble(actual);
  if (want.isNaN) {
    expect(got.isNaN, isTrue, reason: '$label must be NaN, was $got');
    return;
  }
  expect(got, closeTo(want, 1e-9), reason: label);
}

/// Walk up from the test's working directory to the repo root. `flutter test`
/// runs with the package as its cwd, but the fixture is shared with the Rust
/// crate and therefore lives above it.
Directory _locateFixtureRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory('${dir.path}/test_fixtures/wcs_conformance');
    if (File('${candidate.path}/cases.json').existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'test_fixtures/wcs_conformance/cases.json not found above '
    '${Directory.current.path}',
  );
}
