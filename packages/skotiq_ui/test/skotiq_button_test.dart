import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(body: Center(child: child)),
);

BoxDecoration _decorationOf(WidgetTester tester, Finder finder) {
  final container = tester.widget<AnimatedContainer>(
    find.descendant(of: finder, matching: find.byType(AnimatedContainer)),
  );
  return container.decoration as BoxDecoration;
}

void main() {
  testWidgets('primary button is a solid fill and NO border', (tester) async {
    await tester.pumpWidget(
      _wrap(SkotiqButton(label: 'Save', onPressed: () {})),
    );
    await tester.pump();

    final deco = _decorationOf(tester, find.byType(SkotiqButton));
    expect(deco.gradient, isNull);
    expect(deco.color, SkotiqColors.dark.primary);
    // 05 §6: a primary button has no border. The fill is the button; an outline
    // around a filled control is a second boundary saying the same thing.
    final border = deco.border! as Border;
    expect(border.top.color.a, 0.0);
  });

  testWidgets('a disabled button dims, it does not change colour', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const SkotiqButton(label: 'Save', onPressed: null)),
    );
    await tester.pump();
    final deco = _decorationOf(tester, find.byType(SkotiqButton));
    expect(deco.gradient, isNull);
    // Same fill as the live button; only the opacity above it changes, so a
    // disabled destructive still reads as the destructive one.
    expect(deco.color, SkotiqColors.dark.primary);
    expect(
      tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(SkotiqButton),
              matching: find.byType(Opacity),
            ),
          )
          .opacity,
      SkotiqTokens.opacityDisabled,
    );
  });

  testWidgets('the three sizes are 28 / 32 / 40 tall on a pointer platform', (
    tester,
  ) async {
    double heightOf() => tester
        .getSize(
          find.descendant(
            of: find.byType(SkotiqButton),
            matching: find.byType(AnimatedContainer),
          ),
        )
        .height;

    for (final (size, height) in <(ButtonSize, double)>[
      (ButtonSize.small, 28),
      (ButtonSize.medium, 32),
      (ButtonSize.large, 40),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          // The dense sizes are the DESKTOP sizes. On a touch platform the
          // button still floors at the 48dp tap target, which is the whole
          // point of SkotiqTouchTarget; asserting 28 without pinning the
          // platform measures the floor, not the design.
          theme: SkotiqTheme.dark.copyWith(platform: TargetPlatform.linux),
          home: Scaffold(
            body: Center(
              child: SkotiqButton(
                label: 'Go',
                size: size,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(heightOf(), height, reason: '$size');
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark.copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: Center(
            child: SkotiqButton(
              label: 'Go',
              size: ButtonSize.small,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(heightOf(), SkotiqTokens.minTouchTarget);
  });

  testWidgets('the start variant wears its own fill and ink', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SkotiqButton(
          label: 'Start',
          variant: ButtonVariant.start,
          onPressed: () {},
        ),
      ),
    );
    await tester.pump();

    final deco = _decorationOf(tester, find.byType(SkotiqButton));
    expect(deco.color, SkotiqColors.dark.startFill);
    expect(
      tester.widget<Text>(find.text('Start')).style!.color,
      SkotiqColors.dark.onStart,
    );
  });

  testWidgets('hover state changes synchronously without glow shadow', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(SkotiqButton(label: 'Hover me', onPressed: () {})),
    );
    await tester.pump();

    var deco = _decorationOf(tester, find.byType(SkotiqButton));
    final defaultColor = deco.color;

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.byType(SkotiqButton)));
    await tester.pump();

    deco = _decorationOf(tester, find.byType(SkotiqButton));
    expect(deco.boxShadow, anyOf(isNull, isEmpty));
    expect(deco.color, isNot(equals(defaultColor)));
  });

  testWidgets('onPressed fires on tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(SkotiqButton(label: 'Click', onPressed: () => taps++)),
    );
    await tester.tap(find.byType(SkotiqButton));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('isLoading suppresses onPressed', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        SkotiqButton(
          label: 'Loading',
          isLoading: true,
          onPressed: () => taps++,
        ),
      ),
    );
    await tester.tap(find.byType(SkotiqButton));
    await tester.pump();
    expect(taps, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('outline variant renders a non-transparent border on hover', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        SkotiqButton(
          label: 'Outline',
          variant: ButtonVariant.outline,
          onPressed: () {},
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.byType(SkotiqButton)));
    await tester.pump();

    final deco = _decorationOf(tester, find.byType(SkotiqButton));
    final border = deco.border! as Border;
    expect(border.top.color.a, greaterThan(0));
  });

  testWidgets('semantics: button + enabled flag tracks onPressed', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _wrap(const SkotiqButton(label: 'DisabledLbl', onPressed: null)),
      );
      await tester.pump();
      final semantics = tester.getSemantics(
        find.descendant(
          of: find.byType(SkotiqButton),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == 'DisabledLbl',
          ),
        ),
      );
      expect(semantics.flagsCollection.isButton, isTrue);
      expect(semantics.flagsCollection.isEnabled, Tristate.isFalse);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('semantics: enabled when onPressed is set', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _wrap(SkotiqButton(label: 'ActiveLbl', onPressed: () {})),
      );
      await tester.pump();
      final semantics = tester.getSemantics(
        find.descendant(
          of: find.byType(SkotiqButton),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == 'ActiveLbl',
          ),
        ),
      );
      expect(semantics.flagsCollection.isButton, isTrue);
      expect(semantics.flagsCollection.isEnabled, Tristate.isTrue);
    } finally {
      handle.dispose();
    }
  });
}
