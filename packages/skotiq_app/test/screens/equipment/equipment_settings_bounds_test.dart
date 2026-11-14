// Equipment Settings wrote the default gain on every keystroke with no
// bounds: "-5" was stored as a gain of -5, and "12x" left the field showing
// text it never stored (stored 12). The fields now take the settings table's bounds and
// save when the field is done.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/tabs/settings_tab.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

Finder _fieldOf(String label) => find.descendant(
      of: find
          .ancestor(
            of: find.text(label),
            matching: find.byType(Row),
          )
          .first,
      matching: find.byType(EditableText),
    );

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a value past the bound is held to it and saved when done',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const EquipmentSettingsTab(),
      settle: false,
    );
    await _frames(tester);
    int? offset() =>
        handle.container.read(appSettingsProvider).valueOrNull?.defaultOffset;
    expect(offset(), 50);

    await tester.enterText(_fieldOf('Default offset'), '70000');
    await tester.pump();
    expect(offset(), 50, reason: 'typing alone writes nothing');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _frames(tester);
    expect(offset(), 65535);
    expect(find.text('The highest allowed value is 65535.'), findsOneWidget);
  });

  testWidgets('a gain cannot be typed below zero', (tester) async {
    await pumpAppScreen(tester, const EquipmentSettingsTab(), settle: false);
    await _frames(tester);

    await tester.enterText(_fieldOf('Default gain'), '-5');
    await tester.pump();

    expect(
      tester.widget<EditableText>(_fieldOf('Default gain')).controller.text,
      isNot(contains('-')),
    );
  });

  testWidgets('text that is not a number is refused, not dropped silently',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const EquipmentSettingsTab(),
      settle: false,
    );
    await _frames(tester);

    await tester.enterText(_fieldOf('Default offset'), '12x');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _frames(tester);

    expect(
      handle.container.read(appSettingsProvider).valueOrNull?.defaultOffset,
      50,
    );
    expect(
      tester.widget<EditableText>(_fieldOf('Default offset')).controller.text,
      isNot('12x'),
      reason: 'the field does not keep text the setting never took',
    );
  });
}
