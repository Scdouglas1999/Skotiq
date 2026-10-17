import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The non-text contrast floor for the one part of a checkbox that carries its
/// whole state: the outline of an UNCHECKED box.
///
/// A checked box has a filled body and a tick to be seen by. An unchecked one
/// is an outline and nothing else, so if that outline disappears into the
/// surface the control is not "subtle", it is absent — the label reads as a
/// caption and the operator cannot tell an option they turned off from one that
/// was never offered. WCAG 1.4.11 puts the floor for a UI component's boundary
/// at 3:1, and it is measured here against the real painted decoration rather
/// than asserted about a token, because the widget chooses which token to paint.
///
/// Measured before the repair, on the `border` token every palette handed this
/// widget: red night 1.03:1 on `surfaceElevated` (the delivery destination
/// editor's dialog surface — the unchecked "Stage exports" box rendered as a
/// label with nothing beside it), and dark 1.17:1 on the same level. `border`
/// is the palette's DIVIDER weight; it is the correct colour for a card edge
/// and much too quiet for a control.
void main() {
  /// WCAG 2.x contrast ratio — [Color.computeLuminance] is the standard's own
  /// relative luminance, so the arithmetic below is the standard verbatim.
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Every surface level a checkbox can be placed on, per palette. A checkbox
  /// lands on `surface` in a settings row, `surfaceElevated` in a dialog and
  /// `surfaceOverlay` in a popover, and it has to survive all of them.
  List<Color> surfacesOf(SkotiqColors c) => [
    c.background,
    c.surface,
    c.surfaceAlt,
    c.surfaceHover,
    c.surfaceElevated,
    c.surfaceOverlay,
  ];

  /// The colour the widget actually paints around an unchecked box.
  Future<Color> outlineColor(
    WidgetTester tester,
    ThemeData theme, {
    required bool enabled,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: SkotiqCheckbox(
              value: false,
              onChanged: enabled ? (_) {} : null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(SkotiqCheckbox),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = container.decoration! as BoxDecoration;
    return decoration.border!.top.color;
  }

  final palettes = <String, (ThemeData, SkotiqColors)>{
    'dark': (SkotiqTheme.dark, SkotiqColors.dark),
    'light': (SkotiqTheme.light, SkotiqColors.light),
    'redNight': (SkotiqTheme.redNight, SkotiqColors.redNight),
  };

  for (final entry in palettes.entries) {
    testWidgets("an unchecked checkbox's outline clears 3:1 in ${entry.key}", (
      tester,
    ) async {
      final (theme, colors) = entry.value;
      final outline = await outlineColor(tester, theme, enabled: true);
      for (final surface in surfacesOf(colors)) {
        final ratio = contrast(outline, surface);
        expect(
          ratio,
          greaterThanOrEqualTo(3.0),
          reason:
              'the unchecked outline '
              '${outline.toARGB32().toRadixString(16)} on surface '
              '${surface.toARGB32().toRadixString(16)} measures '
              '${ratio.toStringAsFixed(2)}:1, under the 3:1 floor WCAG '
              '1.4.11 sets for the boundary of a UI component',
        );
      }
    });
  }

  testWidgets('a disabled unchecked box is still visible, if quieter', (
    tester,
  ) async {
    // Disabled controls are exempt from 1.4.11, but "exempt from the floor" is
    // not "allowed to vanish": an operator has to be able to see that the
    // option exists and is off before they can work out why they cannot change
    // it. 1.5:1 is the perceptibility floor this palette can pay for a control
    // it is deliberately dimming; red night's `border` paid 1.03:1.
    for (final entry in palettes.entries) {
      final (theme, colors) = entry.value;
      final outline = await outlineColor(tester, theme, enabled: false);
      for (final surface in surfacesOf(colors)) {
        final ratio = contrast(outline, surface);
        expect(
          ratio,
          greaterThanOrEqualTo(1.5),
          reason:
              'the disabled unchecked outline in ${entry.key} measures '
              '${ratio.toStringAsFixed(2)}:1 and is invisible',
        );
      }
    }
  });

  testWidgets('a checked box still reads as checked', (tester) async {
    // The repair must not repaint the checked state: its fill is `primary` and
    // its tick is `onPrimary`, and that pairing is what the palette's own
    // `onPrimary` assertions cover.
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.redNight,
        home: Scaffold(
          body: Center(child: SkotiqCheckbox(value: true, onChanged: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(SkotiqCheckbox),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.color, SkotiqColors.redNight.primary);
    expect(decoration.border!.top.color, SkotiqColors.redNight.primary);
  });
}
