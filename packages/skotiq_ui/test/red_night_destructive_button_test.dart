import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// D2-UX-05 — under red night, Delete and Save must not be two shades of red.
///
/// Red night is monochrome by construction, so `primary` #DC2626 and `error`
/// #EF5350 are one hue at two lightnesses. Measured on the release bundle
/// (Settings > Appearance = Red night, Settings > Delivery > edit a
/// destination, pixel-sampled off the raw root capture): the footer put Delete
/// rgb(239,83,80) beside Save rgb(220,38,38) — two adjacent, equally-weighted
/// solid-red fills, with the channel that normally carries "this one deletes"
/// already spent on the mode. These tests hold the replacement channel: under
/// red night exactly one of the pair is filled.
void main() {
  Widget wrap(ThemeData theme, Widget child) => MaterialApp(
    theme: theme,
    home: Scaffold(body: Center(child: child)),
  );

  BoxDecoration decorationOf(WidgetTester tester, Finder finder) {
    final container = tester.widget<AnimatedContainer>(
      find.descendant(of: finder, matching: find.byType(AnimatedContainer)),
    );
    return container.decoration! as BoxDecoration;
  }

  Finder buttonLabelled(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(SkotiqButton));

  Widget pair() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SkotiqButton(
        label: 'Delete',
        variant: ButtonVariant.destructive,
        onPressed: () {},
      ),
      SkotiqButton(label: 'Save', onPressed: () {}),
    ],
  );

  testWidgets('red night gives the pair different fill weights, not two reds', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(SkotiqTheme.redNight, pair()));
    await tester.pump();

    final destructive = decorationOf(tester, buttonLabelled('Delete'));
    final primary = decorationOf(tester, buttonLabelled('Save'));

    expect(
      destructive.color!.a,
      0.0,
      reason: 'the destructive face is hollow — that absence is the channel',
    );
    expect(
      primary.color,
      SkotiqColors.redNight.primary,
      reason: 'the primary keeps the solid fill it has in every theme',
    );
  });

  testWidgets('the destructive ring wears error and nothing else does', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SkotiqTheme.redNight,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SkotiqButton(
              label: 'Delete',
              variant: ButtonVariant.destructive,
              onPressed: () {},
            ),
            SkotiqButton(
              label: 'Browse',
              variant: ButtonVariant.secondary,
              onPressed: () {},
            ),
            SkotiqButton(label: 'Save', onPressed: () {}),
          ],
        ),
      ),
    );
    await tester.pump();

    final destructive =
        decorationOf(tester, buttonLabelled('Delete')).border! as Border;
    final outline =
        decorationOf(tester, buttonLabelled('Browse')).border! as Border;
    final primary =
        decorationOf(tester, buttonLabelled('Save')).border! as Border;

    expect(
      destructive.top.color,
      SkotiqColors.redNight.error,
      reason: 'the ring is the marker, so it wears the error token',
    );
    expect(
      outline.top.color,
      SkotiqColors.redNight.borderHighlight,
      reason: 'a secondary button must not read as destructive',
    );
    expect(
      primary.top.color.a,
      0.0,
      reason: 'a filled button has no border to compete with its fill',
    );
  });

  testWidgets('the destructive label clears the red-night text floor', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(SkotiqTheme.redNight, pair()));
    await tester.pump();

    final label = tester.widget<Text>(find.text('Delete'));
    const colors = SkotiqColors.redNight;
    expect(label.style!.color, colors.error);

    // The button sits on whichever surface hosts it; check the whole ladder,
    // because a dialog footer and a settings card are not the same ground.
    const surfaces = <Color>[
      Color(0xFF0A0000), // background
      Color(0xFF140808), // surface
      Color(0xFF1C0C0C), // surfaceAlt — the destination editor's own footer
      Color(0xFF241010), // surfaceHover
      Color(0xFF281212), // surfaceElevated
      Color(0xFF301616), // surfaceOverlay
    ];
    for (final surface in surfaces) {
      final la = colors.error.computeLuminance();
      final lb = surface.computeLuminance();
      final ratio = ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'a hollow button spends its own colour as text, so the '
            'label answers to the 4.5:1 floor the palette holds',
      );
    }
  });

  testWidgets('the fill stays absent through hover and press', (tester) async {
    await tester.pumpWidget(wrap(SkotiqTheme.redNight, pair()));
    await tester.pump();

    final target = tester.getCenter(buttonLabelled('Delete'));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(target);
    await tester.pump();

    final hovered = decorationOf(tester, buttonLabelled('Delete'));
    expect(
      hovered.color!.a,
      lessThan(SkotiqColors.redNight.primary.a),
      reason: 'hover washes the interior; it does not fill it',
    );

    await tester.press(buttonLabelled('Delete'));
    await tester.pump();
    final pressed = decorationOf(tester, buttonLabelled('Delete'));
    expect(pressed.color!.a, lessThan(SkotiqColors.redNight.primary.a));
  });

  testWidgets('every theme now spends fill weight, not hue', (tester) async {
    // 05 §6 promotes the red-night repair to the whole app: destructive is
    // hollow with an `error` ring in EVERY theme. Hue still separates the pair
    // in dark and light, but it is no longer the only thing that does, so a
    // screenshot of the footer reads the same way in all three modes.
    for (final entry in <String, ThemeData>{
      'dark': SkotiqTheme.dark,
      'light': SkotiqTheme.light,
      'red night': SkotiqTheme.redNight,
    }.entries) {
      await tester.pumpWidget(wrap(entry.value, pair()));
      await tester.pump();

      final destructive = decorationOf(tester, buttonLabelled('Delete'));
      final primary = decorationOf(tester, buttonLabelled('Save'));

      expect(
        destructive.color!.a,
        0.0,
        reason: '${entry.key}: the destructive face is hollow',
      );
      expect(
        primary.color!.a,
        1.0,
        reason: '${entry.key}: the primary is the filled one of the pair',
      );
      expect(
        (destructive.border! as Border).top.color,
        isNot((primary.border! as Border).top.color),
        reason: '${entry.key}: only the destructive carries a ring',
      );
    }
  });
}
