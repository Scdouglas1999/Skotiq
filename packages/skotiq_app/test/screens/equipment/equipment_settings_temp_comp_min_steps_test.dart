// Temperature compensation stepped the owner's focuser by one on every probe
// reading. It now waits for a correction of a set size, and that size is the
// operator's to change beside the coefficient.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/tabs/settings_tab.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the smallest compensation move is shown and saved',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const EquipmentSettingsTab(),
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('Smallest compensation move'), findsOneWidget);
    final field = find.descendant(
      of: find.byKey(const ValueKey('temp-comp-min-steps')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(field).controller.text, '5');

    await tester.enterText(field, '12');
    // Typing alone writes nothing; the value is saved when the field is done.
    await tester.pump();
    expect(
      handle.container
          .read(appSettingsProvider)
          .valueOrNull
          ?.tempCompensationMinSteps,
      5,
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      handle.container
          .read(appSettingsProvider)
          .valueOrNull
          ?.tempCompensationMinSteps,
      12,
    );
  });
}
