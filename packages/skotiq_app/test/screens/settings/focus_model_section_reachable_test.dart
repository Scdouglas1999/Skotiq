import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/merged_sections.dart';
import 'package:skotiq_app/screens/settings/settings_catalog.dart';
import 'package:skotiq_app/screens/settings/widgets/focus_model_settings.dart';

import '../../harness/harness.dart';

/// Focus Model shipped with no way to open it.
///
/// `kMergedSectionAliases` mapped `focus-model` onto `autofocus` and
/// `kSettingsSectionIndex` listed the key, so every deep link and search hit
/// resolved successfully — to an Autofocus pane that did not contain the widget.
/// Repo-wide, `FocusModelSettings`'s only references were inside its own
/// declaration: a whole settings screen with no route into it, which the
/// coverage ledger recorded as "unreachable BY DESIGN FAULT, not by budget".
///
/// The alias is the load-bearing part of the contract, so both halves are
/// asserted here: the key still resolves to Autofocus, AND Autofocus actually
/// renders the pane.
void main() {
  test('the focus-model key still merges into Autofocus', () {
    expect(kMergedSectionAliases['focus-model'], 'autofocus');
    expect(kSettingsSectionIndex.containsKey('focus-model'), isTrue);
  });

  testWidgets('the Autofocus section renders the Focus Model pane', (
    tester,
  ) async {
    final database = mockDatabase();
    addTearDown(database.close);
    await pumpAppScreen(
      tester,
      const AutofocusMergedSettings(),
      size: const Size(1280, 1400),
      database: database,
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(FocusModelSettings), findsOneWidget);
    expect(find.text('FOCUS MODEL'), findsOneWidget);
    // The two panes that were already mounted must survive the third slot.
    expect(find.text('AUTOFOCUS'), findsOneWidget);
    expect(find.text('PREDICTIVE AUTOFOCUS'), findsOneWidget);
  });

  testWidgets('the embedded pane brings no scroll view of its own', (
    tester,
  ) async {
    // `_MergedSection` is one continuous scroll; a child that keeps its own
    // would nest scrollables and render unbounded inside the column.
    final database = mockDatabase();
    addTearDown(database.close);
    await pumpAppScreen(
      tester,
      const FocusModelSettings(embedded: true),
      size: const Size(1280, 1000),
      database: database,
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(FocusModelSettings), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
