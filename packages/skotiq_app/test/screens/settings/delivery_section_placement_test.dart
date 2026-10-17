// Delivery destinations are where a night's masters, draft render and report
// leave the rig — a headline automation surface, not a diagnostic. Filing it
// under Advanced put it between the Log Viewer and Replay Debug, the two pages
// a user is told to open only when something is broken, so the feature read as
// a debug tool and `groupTitleForKey('delivery')` sent every in-app pointer
// and breadcrumb to "Advanced".
//
// It belongs with the rest of the unattended-night configuration. These tests
// pin the group so the placement cannot drift back, and pin the three
// structures that must stay in lock-step — the built catalog, the structural
// ordering behind `kSettingsSectionIndex`, and `groupTitleForKey`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/settings/settings_catalog.dart';

void main() {
  Future<List<SettingsGroupDef>> catalog(WidgetTester tester) async {
    late List<SettingsGroupDef> groups;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            groups = buildSettingsGroups(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return groups;
  }

  testWidgets('Delivery is an Automation & Safety section, not a debug tool', (
    tester,
  ) async {
    final groups = await catalog(tester);

    final owning = groups.firstWhere(
      (g) => g.sections.any((s) => s.key == 'delivery'),
      orElse: () => throw StateError(
        'no settings group renders the delivery section: '
        '${groups.map((g) => g.title).toList()}',
      ),
    );

    expect(owning.title, 'Automation & Safety');
  });

  testWidgets('no Advanced section builds the delivery page', (tester) async {
    final groups = await catalog(tester);

    final advanced = groups.firstWhere((g) => g.title == 'Advanced');

    expect(advanced.sections.map((s) => s.key), isNot(contains('delivery')));
  });

  test('the locale-independent group lookup agrees with the catalog', () {
    // `groupTitleForKey` reads `_structuralGroups`, a separate list from the
    // one `buildSettingsGroups` builds. A move that edits only the builder
    // leaves every deep link and breadcrumb naming the old group.
    expect(groupTitleForKey('delivery'), 'Automation & Safety');
  });

  test('the delivery deep link still resolves', () {
    // `/settings?section=delivery` is a navigation contract; moving the
    // section between groups must not break the link that opens it.
    expect(resolveSectionKey('delivery'), 'delivery');
  });
}
