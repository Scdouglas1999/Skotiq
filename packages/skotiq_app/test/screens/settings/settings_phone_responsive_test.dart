// Phone-tier responsive tests for SettingsScreen.
//
// The mobile-responsive standard (docs/plans/2026-06-01-mobile-responsive-
// standard.md) requires every screen to work, with no overflow, at three phone
// sizes in BOTH orientations. SettingsScreen is a grouped, searchable list ->
// full-screen detail flow on phones (width < 600).
//
// These tests pump the screen at each phone size in portrait and landscape and
// assert:
//   * no RenderFlex overflow,
//   * the grouped category list renders (group headers present),
//   * the search box is reachable,
//   * tapping a category pushes the full-screen detail pane (and the list is
//     gone), then Back returns to the list.

import 'dart:ui' show SemanticsAction, SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/general_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// In-memory [AppSettingsNotifier] serving a fixed state (no DB/network).
class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;
  @override
  Future<AppSettingsState> build() async => _initial;
}

List<Override> _stubSettings([
  AppSettingsState state = const AppSettingsState(),
]) =>
    [appSettingsProvider.overrideWith(() => _StubAppSettingsNotifier(state))];

/// The three phone sizes from the standard, each in portrait and the rotated
/// landscape variant.
const _phonePortrait = <(String, Size)>[
  ('small 360x640', Size(360, 640)),
  ('modern 390x844', Size(390, 844)),
  ('large 430x932', Size(430, 932)),
];
const _phoneLandscape = <(String, Size)>[
  ('small 640x360', Size(640, 360)),
  ('modern 844x390', Size(844, 390)),
  ('large 932x430', Size(932, 430)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search survives a shell-consumed landscape keyboard inset',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpAppScreen(
        tester,
        const SizedBox(height: 64, child: SettingsScreen()),
        size: const Size(932, 430),
        extraOverrides: _stubSettings(),
      );

      final searchField = find.byType(TextField).first;
      expect(tester.takeException(), isNull);
      expect(searchField.hitTestable(), findsOneWidget);
      expect(find.text('Settings'), findsNothing);

      await tester.tap(searchField);
      await tester.enterText(searchField, 'latitude');
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // Every test size/orientation: no overflow + a reachable, working search box.
  // (Layout is driven by *device class* — shortest side < 600 — not the live
  // width, so a phone rotated to landscape stays a phone and keeps the list ->
  // detail flow even though its long edge crosses 600.)
  for (final (label, size) in [..._phonePortrait, ..._phoneLandscape]) {
    testWidgets(
        'settings_$label: renders with no overflow and a reachable, '
        'working search box', (tester) async {
      await pumpAppScreen(
        tester,
        const SettingsScreen(),
        size: size,
        extraOverrides: _stubSettings(),
      );

      expect(tester.takeException(), isNull,
          reason: 'SettingsScreen must not overflow at $label.');

      // Grouped categories are present (group headers render in UPPER CASE).
      expect(find.text('GENERAL'), findsOneWidget,
          reason: 'The grouped category list must render at $label.');

      // The search box must be reachable and usable in either layout.
      final searchField = find.byType(TextField).first;
      await tester.enterText(searchField, 'latitude');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(find.text('Location'), findsOneWidget,
          reason: 'Searching must narrow to a matching section at $label.');
      expect(tester.takeException(), isNull,
          reason: 'Searching must not overflow at $label.');
    });
  }

  // Phone PORTRAIT (width < 600) uses list -> full-screen detail navigation.
  for (final (label, size) in _phonePortrait) {
    testWidgets(
        'settings_phone_${label}_detail: tapping a category opens the '
        'full-screen detail pane (list gone), Back returns to the list',
        (tester) async {
      await pumpAppScreen(
        tester,
        const SettingsScreen(),
        size: size,
        extraOverrides: _stubSettings(),
      );

      // The phone list view shows the grouped list, not a detail pane.
      expect(find.byType(GeneralSettings), findsNothing,
          reason: 'The phone flow starts on the list, not a detail pane, '
              'at $label.');

      // The General group is expanded by default; tap its General entry.
      await tester.tap(find.text('General').first);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(tester.takeException(), isNull,
          reason: 'Opening the detail pane must not overflow at $label.');
      expect(find.byType(GeneralSettings), findsOneWidget,
          reason: 'Tapping a category must push its full-screen detail pane '
              'at $label.');
      // The grouped list is gone now that the detail pane is full-screen
      // (list -> detail navigation, not a split).
      //
      // GENERAL, not EQUIPMENT, is the sentinel: the list is a lazy
      // ListView.builder, so on a short phone EQUIPMENT is simply never built
      // and `findsNothing` passed for the wrong reason — it could not tell
      // "the list is gone" from "the list is here but that row is below the
      // fold". GENERAL is the first row, so it is built whenever the list is.
      expect(find.text('GENERAL'), findsNothing,
          reason: 'The detail pane is full-screen on phone; the grouped list '
              'must not also be visible at $label.');

      // Back returns to the list. The detail header has a single icon button
      // (the back arrow), now the design system's SkotiqIconButton.
      await tester.tap(find.byType(SkotiqIconButton).first);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.text('GENERAL'), findsOneWidget,
          reason: 'Back from the detail pane must restore the grouped list '
              'at $label.');

      // …and the rest of the taxonomy is still reachable from there.
      final list = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(find.text('EQUIPMENT'), 100,
          scrollable: list);
      await tester.pumpAndSettle();
      expect(find.text('EQUIPMENT'), findsOneWidget,
          reason: 'Later groups must remain reachable by scrolling the '
              'restored list at $label.');
    });
  }

  // Phone LANDSCAPE keeps the phone list -> full-screen detail flow. Layout is
  // driven by *device class* (shortest side < 600), not the current width, so a
  // rotated phone stays a phone: its long edge crossing 600 does NOT promote it
  // to the tablet sidebar+detail split. The grouped list shows by default and
  // tapping a category pushes the full-screen detail pane.
  for (final (label, size) in _phoneLandscape) {
    testWidgets(
        'settings_landscape_${label}_detail: stays in the phone list -> '
        'full-screen detail flow (no split)', (tester) async {
      await pumpAppScreen(
        tester,
        const SettingsScreen(),
        size: size,
        extraOverrides: _stubSettings(),
      );

      expect(tester.takeException(), isNull,
          reason: 'The phone landscape layout must not overflow at $label.');
      // The grouped list is shown by default; the detail pane is not a split.
      expect(find.text('GENERAL'), findsOneWidget,
          reason: 'The grouped category list must render at $label.');
      expect(find.byType(GeneralSettings), findsNothing,
          reason: 'The phone flow starts on the list, not a detail pane, '
              'at $label.');

      // Tapping a category pushes its full-screen detail pane.
      await tester.tap(find.text('General').first);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(tester.takeException(), isNull,
          reason: 'Opening the detail pane must not overflow at $label.');
      expect(find.byType(GeneralSettings), findsOneWidget,
          reason: 'Tapping a category must push its full-screen detail pane '
              'at $label.');
      // GENERAL (the first, always-built row) rather than EQUIPMENT — see the
      // portrait case above for why a below-the-fold row is a false sentinel.
      expect(find.text('GENERAL'), findsNothing,
          reason: 'The detail pane is full-screen on phone; the grouped list '
              'must not also be visible at $label.');
    });
  }

  // A search result has two kinds of row: the section, and the settings inside
  // it that matched. The second kind is indented on the left, and at 430px it
  // ran flat off the RIGHT edge of the window with its corner radius cut away,
  // between two section rows that were inset on both sides.
  testWidgets('a matched setting is inset on both sides at phone width', (
    tester,
  ) async {
    const width = 430.0;
    await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(width, 900),
      extraOverrides: _stubSettings(),
    );

    await tester.enterText(find.byType(TextField).first, 'delivery');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    // The turn-down arrow is the sub-result's own mark; the section rows above
    // and below it carry a chevron instead.
    final marker = find.byIcon(LucideIcons.cornerDownRight);
    expect(marker, findsWidgets,
        reason: 'the search must produce a sub-result');

    final row =
        find.ancestor(of: marker.first, matching: find.byType(Container)).first;
    // The painted, rounded box inside the row's margin — the thing that was
    // being clipped.
    final painted = tester.getRect(
      find.descendant(of: row, matching: find.byType(DecoratedBox)).first,
    );

    expect(painted.left, greaterThanOrEqualTo(20.0));
    expect(
      painted.right,
      lessThanOrEqualTo(width - 16),
      reason: 'the row reached ${painted.right} of a ${width}px window, so its '
          'trailing corner is off screen',
    );
  });

  // At phone width these rows are the ONLY route into a settings section —
  // there is no sidebar behind them — and measured on the release bundle
  // 2026-08-31 every one of them reached AT-SPI as
  // `panel: 'Delivery' -> ['focusable', 'showing', 'visible']`: no button role,
  // no enabled state, while the identical desktop entry came back
  // `button: 'Delivery' -> ['enabled', 'focusable', 'sensitive', 'showing']`
  // and the leaf row under it ("Delivery destinations") was already correct.
  testWidgets('every phone settings row publishes a live button', (
    tester,
  ) async {
    await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(430, 900),
      extraOverrides: _stubSettings(),
    );
    final semantics = tester.ensureSemantics();

    /// The node the platform is handed under exactly [label].
    SemanticsNode? published(String label) {
      SemanticsNode? found;
      void visit(SemanticsNode node) {
        if (found == null && node.label == label) found = node;
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
      return found;
    }

    await tester.enterText(find.byType(TextField).first, 'delivery');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    for (final label in ['Delivery', 'Night-end automation']) {
      final node = published(label);
      expect(node, isNotNull, reason: 'no node is published under "$label"');
      final data = node!.getSemanticsData();
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue,
          reason: '"$label" is the only route to that section and publishes '
              'no button role');
      expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue,
          reason: '"$label" states neither enabled nor disabled');
      expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue, reason: label);
      expect(data.hasAction(SemanticsAction.tap), isTrue, reason: label);
    }

    // The group label of the unsearched list carries the OPPOSITE contract.
    // The Observatory nav is a flat list under three quiet eyebrows
    // (06 §Settings): there is nothing to expand, so the label must publish no
    // button role, no expanded state and no tap action — seven dead stops
    // removed from the traversal order rather than seven controls to operate
    // before the sections can be read.
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    final header = published('GENERAL');
    expect(header, isNotNull, reason: 'the group label must still be read out');
    final headerData = header!.getSemanticsData();
    expect(headerData.hasFlag(SemanticsFlag.isButton), isFalse);
    expect(headerData.hasFlag(SemanticsFlag.hasExpandedState), isFalse);
    expect(headerData.hasAction(SemanticsAction.tap), isFalse);

    semantics.dispose();
  });
}
