// Translation-completeness guard for the in-app localization table.
//
// `SkotiqLocalizations` resolves strings from `_localizedValues`, a
// locale -> key -> value map. English (`en`) is the source of truth; every
// other supported locale MUST define exactly the same set of keys. A missing
// key silently falls back to English at runtime (see `text()`), so the gap is
// invisible until a user switches locale — this test makes it loud at CI time.
//
// When you add a key to `en`, add it to every other locale too, or this test
// fails with the exact list of missing/extra keys.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';

void main() {
  final values = SkotiqLocalizations.debugLocalizedValues;
  const sourceLocale = 'en';

  test('en is the source-of-truth locale and is non-empty', () {
    expect(values.containsKey(sourceLocale), isTrue,
        reason: 'The "$sourceLocale" locale must exist.');
    expect(values[sourceLocale]!.isNotEmpty, isTrue);
  });

  test('every supported locale is present in the translation table', () {
    for (final locale in SkotiqLocalizations.supportedLocales) {
      expect(values.containsKey(locale.languageCode), isTrue,
          reason: 'supportedLocales lists "${locale.languageCode}" but the '
              'translation table has no entry for it.');
    }
  });

  final enKeys = values[sourceLocale]!.keys.toSet();

  for (final locale in values.keys.where((l) => l != sourceLocale)) {
    final localeKeys = values[locale]!.keys.toSet();

    test('locale "$locale" defines every key present in "$sourceLocale"', () {
      final missing = enKeys.difference(localeKeys).toList()..sort();
      expect(missing, isEmpty,
          reason: 'Locale "$locale" is missing ${missing.length} key(s) '
              'present in "$sourceLocale": $missing');
    });

    test('locale "$locale" has no keys absent from "$sourceLocale"', () {
      final extra = localeKeys.difference(enKeys).toList()..sort();
      expect(extra, isEmpty,
          reason: 'Locale "$locale" defines ${extra.length} key(s) not in '
              '"$sourceLocale" (likely a typo or dead key): $extra');
    });

    test('locale "$locale" has no blank values', () {
      final blanks = values[locale]!
          .entries
          .where((e) => e.value.trim().isEmpty)
          .map((e) => e.key)
          .toList()
        ..sort();
      expect(blanks, isEmpty,
          reason: 'Locale "$locale" has empty string(s) for: $blanks');
    });

    test('locale "$locale" preserves every {placeholder} from "$sourceLocale"',
        () {
      final placeholderRe = RegExp(r'\{(\w+)\}');
      final mismatches = <String>[];
      for (final key in enKeys) {
        final enPlaceholders = placeholderRe
            .allMatches(values[sourceLocale]![key]!)
            .map((m) => m.group(1)!)
            .toSet();
        final localeValue = values[locale]![key];
        if (localeValue == null) continue; // covered by the "missing" test
        final localePlaceholders = placeholderRe
            .allMatches(localeValue)
            .map((m) => m.group(1)!)
            .toSet();
        if (enPlaceholders.difference(localePlaceholders).isNotEmpty ||
            localePlaceholders.difference(enPlaceholders).isNotEmpty) {
          mismatches.add('$key (en: $enPlaceholders, $locale: '
              '$localePlaceholders)');
        }
      }
      expect(mismatches, isEmpty,
          reason: 'Placeholder drift between "$sourceLocale" and "$locale": '
              '$mismatches');
    });
  }

  test('SkotiqLocalizations.text falls back and substitutes params', () {
    WidgetsFlutterBinding.ensureInitialized();
    final es = SkotiqLocalizations(const Locale('es'));
    // A known es key resolves to Spanish, not the key or the English value.
    expect(es.text('commonNext'), 'Siguiente');
    // Param substitution works.
    expect(
      es.text('firstNightWizardStepLabel',
          params: {'current': '2', 'total': '7'}),
      'Paso 2 de 7',
    );
    // Unknown key falls back to the key itself.
    expect(es.text('___definitely_missing___'), '___definitely_missing___');
  });
}
