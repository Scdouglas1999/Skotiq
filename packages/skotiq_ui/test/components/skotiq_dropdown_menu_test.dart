// The select's OPEN list.
//
// Wave 2 left the open list on Material's `DropdownButton`, whose menu entries
// assert a 48px floor — a touch figure applied to a pointer control. 05 §8 asks
// for 32px rows on the `popover` decoration, the value left-aligned, and a list
// an operator can drive from the keyboard. This suite pins all four, plus the
// touch platform's own floor, which is the ONE place 48 is right.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  const items = <String>['Light', 'Dark', 'Red night'];

  Widget host(Widget child, {TargetPlatform platform = TargetPlatform.linux}) =>
      MaterialApp(
        theme: SkotiqTheme.dark.copyWith(platform: platform),
        home: Scaffold(
          body: Center(child: SizedBox(width: 220, child: child)),
        ),
      );

  Finder rowAt(int index) =>
      find.byKey(ValueKey<String>('skotiqDropdownRow$index'));

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byType(SkotiqDropdown));
    await tester.pumpAndSettle();
  }

  testWidgets('every row in the open list is 32px on a pointer platform', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(SkotiqDropdown(value: 'Dark', items: items, onChanged: (_) {})),
    );
    await open(tester);

    for (var index = 0; index < items.length; index++) {
      expect(
        tester.getSize(rowAt(index)).height,
        SkotiqTokens.buttonHeight,
        reason: 'row $index is not the 32px the sheet asks for',
      );
    }
  });

  testWidgets('the open list wears the popover decoration', (tester) async {
    await tester.pumpWidget(
      host(SkotiqDropdown(value: 'Dark', items: items, onChanged: (_) {})),
    );
    await open(tester);

    final colors = SkotiqColors.dark;
    final menu = tester.widget<Container>(
      find.ancestor(of: rowAt(0), matching: find.byType(Container)).last,
    );
    final decoration = menu.decoration! as BoxDecoration;
    expect(decoration.color, colors.surfaceElevated);
    expect(decoration.boxShadow, isNotEmpty);
  });

  testWidgets('the value reads from the leading edge, not the middle', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(SkotiqDropdown(value: 'Dark', items: items, onChanged: (_) {})),
    );

    final field = tester.getRect(find.byType(SkotiqDropdown));
    final label = tester.getRect(find.text('Dark'));
    expect(
      label.left - field.left,
      closeTo(SkotiqTokens.inputPaddingHorizontal + 1, 1.5),
      reason: 'the value must sit against the field padding, not be centred',
    );
  });

  testWidgets('arrow keys move the highlight and Enter chooses', (
    tester,
  ) async {
    String? chosen;
    await tester.pumpWidget(
      host(
        SkotiqDropdown(
          value: 'Light',
          items: items,
          onChanged: (value) => chosen = value,
        ),
      ),
    );
    await open(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(chosen, 'Red night');
    expect(rowAt(0), findsNothing, reason: 'the list must close on a choice');
  });

  testWidgets('Escape closes the list and changes nothing', (tester) async {
    String? chosen;
    await tester.pumpWidget(
      host(
        SkotiqDropdown(
          value: 'Light',
          items: items,
          onChanged: (value) => chosen = value,
        ),
      ),
    );
    await open(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(rowAt(0), findsNothing);
    expect(chosen, isNull);
  });

  testWidgets('a tap on a row reports that row', (tester) async {
    String? chosen;
    await tester.pumpWidget(
      host(
        SkotiqDropdown(
          value: 'Light',
          items: items,
          onChanged: (value) => chosen = value,
        ),
      ),
    );
    await open(tester);

    await tester.tap(rowAt(1));
    await tester.pumpAndSettle();

    expect(chosen, 'Dark');
  });

  testWidgets('itemLabels drive what the list shows, items what it reports', (
    tester,
  ) async {
    String? chosen;
    await tester.pumpWidget(
      host(
        SkotiqDropdown(
          value: 'dark',
          items: const <String>['light', 'dark'],
          itemLabels: const <String>['Light', 'Dark'],
          onChanged: (value) => chosen = value,
        ),
      ),
    );
    await open(tester);

    expect(find.text('Light'), findsOneWidget);
    await tester.tap(rowAt(0));
    await tester.pumpAndSettle();

    expect(chosen, 'light');
  });

  testWidgets('a disabled select does not open', (tester) async {
    await tester.pumpWidget(
      host(const SkotiqDropdown(value: 'Dark', items: items)),
    );
    await tester.tap(find.byType(SkotiqDropdown));
    await tester.pumpAndSettle();

    expect(rowAt(0), findsNothing);
  });

  testWidgets('on a touch platform the field and the rows clear 48dp', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SkotiqDropdown(value: 'Dark', items: items, onChanged: (_) {}),
        platform: TargetPlatform.android,
      ),
    );

    expect(
      tester.getSize(find.byType(SkotiqDropdown)).height,
      greaterThanOrEqualTo(SkotiqTokens.minTouchTarget),
      reason:
          'the closed select measured 24px tall in the Android tap-target '
          'audit; the hit box, not the painted field, is what has to grow',
    );

    await open(tester);
    expect(
      tester.getSize(rowAt(0)).height,
      greaterThanOrEqualTo(SkotiqTokens.minTouchTarget),
    );
  });
}
