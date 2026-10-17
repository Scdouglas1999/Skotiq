// The settings search must not offer a runtime STATE as if it were a row.
//
// Live on a machine with no solver installed: searching "catalog" listed
// "ASTAP detected — catalog missing" under Plate Solving, while the Plate
// Solving page itself said "ASTAP not installed — Skotiq cannot
// plate-solve". Two Settings surfaces disagreeing about one fact, because the
// generated index harvests every `title:` literal and `SolverDetectionCard`
// has five mutually exclusive headlines of which at most one is ever on
// screen.
//
// The generator now honours a `settings-search: ignore` marker on such a
// widget (see tools/production/settings_search_index_gen.dart); this test is
// what stops the headlines coming back if the marker is dropped or the card is
// rewritten.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_search_index.g.dart';

/// The headlines `SolverDetectionCard` can render. Exactly one is on screen at
/// a time and which one depends on what is installed, so none of them names a
/// row anybody can navigate to.
const _detectionHeadlines = <String>[
  'ASTAP detected — catalog missing',
  'Selected Astrometry.net solver is not installed',
];

void main() {
  test('no detection-state headline is indexed as a Plate Solving row', () {
    final terms = kSettingsSearchTerms['plate-solving'] ?? const <String>[];
    for (final headline in _detectionHeadlines) {
      expect(
        terms,
        isNot(contains(headline)),
        reason: '"$headline" is what the solver card says when ASTAP IS '
            'present but its catalog is missing. Offering it as a row claims '
            'that state on every machine, including one where nothing is '
            'installed at all.',
      );
    }
  });

  test('no settings section indexes a detection-state headline', () {
    for (final entry in kSettingsSearchTerms.entries) {
      for (final headline in _detectionHeadlines) {
        expect(entry.value, isNot(contains(headline)),
            reason: 'section "${entry.key}" indexes "$headline"');
      }
    }
  });

  test('the real Plate Solving rows are still indexed', () {
    // Dropping the detection headlines must not take the page's actual
    // controls with them — these are rendered whatever is installed.
    final terms = kSettingsSearchTerms['plate-solving'] ?? const <String>[];
    expect(terms, contains('ASTAP catalog directory'));
    expect(terms, contains('ASTAP executable'));
    expect(terms, contains('Active solver'));
    expect(terms, contains('Search radius'));
  });
}
