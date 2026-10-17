// Shared sidebar navigation for the SettingsScreen widget tests.
//
// Every settings test that opens a section drives the same grouped,
// collapsible, lazily-built sidebar, so the helper lives here once.
//
// NEVER read geometry before pumping. `tester.scrollUntilVisible` finishes with
// an un-awaited `Scrollable.ensureVisible` and no pump:
//
//   while (maxIteration > 0 && finder.evaluate().isEmpty) { drag; pump; }
//   await Scrollable.ensureVisible(finder.evaluate().single);   // <- no pump
//
// so on return the ScrollPosition has jumped to its new offset while the render
// tree still holds the previous one, and `tester.tap` reads a stale RenderBox
// centre. The tap then lands on the page background, the group never expands,
// and the failure surfaces later and elsewhere, looking like a layout fault.
// Whether the stale centre happens to fall inside the viewport is luck that
// turns on row height.
//
// Note also that the loop exits on `finder.evaluate().isEmpty`, i.e. as soon as
// the row EXISTS. A lazy ListView builds rows a little beyond the viewport, so
// "exists" does not mean "inside the clip"; the explicit ensureVisible below is
// what actually reveals it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/tutorial_keys/settings_keys.dart';

/// The sidebar's scrollable (the keyed grouped ListView). Targeting it
/// explicitly avoids grabbing a Scrollable inside the detail pane.
Finder get settingsSidebar => find.descendant(
      of: find.byKey(SettingsTutorialKeys.categories),
      matching: find.byType(Scrollable),
    );

/// Scrolls the sidebar until [target] is not merely built but fully inside the
/// viewport, and leaves the render tree in sync with the final scroll offset.
///
/// Safe to call at any row height and any surface size: nothing here assumes
/// the row is already on screen, or that the list is short enough to fit.
Future<void> revealInSettingsSidebar(
  WidgetTester tester,
  Finder target,
) async {
  await tester.scrollUntilVisible(target, 100, scrollable: settingsSidebar);
  // Flush the jump scrollUntilVisible performed but never pumped.
  await tester.pumpAndSettle();
  // ...then actually reveal it, since "built" != "inside the clip".
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// Reveals [target] in the sidebar and taps it.
///
/// A missed tap is made FATAL here rather than a console warning. These tests
/// exist to prove a user can reach a setting; a tap that sails past the row and
/// lands on the page background proves the opposite, and letting it pass
/// silently is how the stale-geometry defect above stayed hidden.
Future<void> tapInSettingsSidebar(
  WidgetTester tester,
  Finder target, {
  Duration settle = const Duration(milliseconds: 300),
}) async {
  await revealInSettingsSidebar(tester, target);
  WidgetController.hitTestWarningShouldBeFatal = true;
  await tester.tap(target);
  await tester.pumpAndSettle(settle);
}

/// Brings a sidebar group's (upper-cased) header into view.
///
/// The groups no longer collapse — the Observatory nav is a flat list under
/// three quiet eyebrows (06 §Settings) — so there is nothing to open. The
/// helper stays because every caller's next step is to tap a row inside the
/// group, and scrolling the header into view is still what puts that row within
/// reach; it now also ASSERTS the group is present, which is the claim the old
/// tap was making implicitly.
Future<void> expandSettingsGroup(
  WidgetTester tester,
  String groupTitle,
) async {
  final header = find.text(groupTitle.toUpperCase());
  await revealInSettingsSidebar(tester, header);
  expect(
    header,
    findsOneWidget,
    reason: 'the settings sidebar must show the "$groupTitle" group.',
  );
}

/// Selects a section row (its group must already be expanded).
Future<void> selectSettingsSection(
  WidgetTester tester,
  String sectionLabel,
) async {
  await tapInSettingsSidebar(
    tester,
    find.text(sectionLabel).first,
    settle: const Duration(seconds: 1),
  );
}
