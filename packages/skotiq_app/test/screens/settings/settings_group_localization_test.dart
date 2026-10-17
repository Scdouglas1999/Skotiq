import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/settings/settings_catalog.dart';

/// The settings sidebar must localize its GROUP headers, not just its leaf
/// items.
///
/// `SettingsGroupDef.title` is a structural identifier that has to stay English
/// (see [kGroupTitles]), so rendering it as the header puts "Apariencia" and
/// "Ubicación" under a header saying "EQUIPMENT" in Spanish. `displayTitle` is
/// the localized one.
void main() {
  Future<List<SettingsGroupDef>> groupsFor(
    WidgetTester tester,
    Locale locale,
  ) async {
    late List<SettingsGroupDef> captured;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            captured = buildSettingsGroups(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    // Localizations builds its subtree only once the delegate has resolved, so
    // the capturing Builder does not run on the first frame.
    await tester.pumpAndSettle();
    return captured;
  }

  testWidgets('every group has a resolved display title in English',
      (tester) async {
    final groups = await groupsFor(tester, const Locale('en'));
    expect(groups, isNotEmpty);
    for (final group in groups) {
      expect(group.displayTitle, isNotEmpty, reason: group.title);
      // A missing key would fall through to the key name itself.
      expect(
        group.displayTitle.startsWith('settingsGroup'),
        isFalse,
        reason: 'unresolved translation key for ${group.title}',
      );
    }
  });

  testWidgets('structural titles stay English regardless of locale',
      (tester) async {
    final spanish = await groupsFor(tester, const Locale('es'));
    expect(
      spanish.map((g) => g.title).toList(),
      kGroupTitles,
      reason:
          'structural ids must not follow the locale; callers match on them '
          'without a BuildContext',
    );
  });

  testWidgets('Spanish actually translates the group headers', (tester) async {
    final english = await groupsFor(tester, const Locale('en'));
    final spanish = await groupsFor(tester, const Locale('es'));

    final englishTitles = {for (final g in english) g.title: g.displayTitle};
    final spanishTitles = {for (final g in spanish) g.title: g.displayTitle};

    // 'General' and 'Science'->'Ciencia' etc. — at least the multi-word ones
    // must differ, or nothing is being translated.
    expect(
      spanishTitles['Equipment'],
      isNot(englishTitles['Equipment']),
      reason: 'Equipment header should be translated',
    );
    expect(
      spanishTitles['Automation & Safety'],
      isNot(englishTitles['Automation & Safety']),
      reason: 'Automation & Safety header should be translated',
    );
    expect(
      spanishTitles['Advanced'],
      isNot(englishTitles['Advanced']),
      reason: 'Advanced header should be translated',
    );
  });

  testWidgets('the search hint is localized too', (tester) async {
    late String en;
    late String es;
    for (final (locale, sink) in [
      (const Locale('en'), (String v) => en = v),
      (const Locale('es'), (String v) => es = v),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates:
              SkotiqLocalizations.localizationsDelegates,
          supportedLocales: SkotiqLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              sink(context.l10n.text('settingsSearchHint'));
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
    }
    expect(en, isNotEmpty);
    expect(es, isNotEmpty);
    expect(en, isNot(es), reason: 'search hint should differ by locale');
    expect(es, contains('Buscar'));
  });
}
