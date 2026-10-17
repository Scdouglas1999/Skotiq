// Widget tests for the variable picker. Verifies the picker's
// core contract: opening the menu, inserting at the cursor, escaping
// existing text, and rendering the preview row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/sequence/variable_picker.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('VariablePickerButton', () {
    testWidgets('renders compact icon button by default', (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VariablePickerButton(controller: controller),
        ),
      ));
      expect(find.byIcon(Icons.code), findsOneWidget);
    });

    testWidgets('opens dialog when tapped', (tester) async {
      final controller = TextEditingController(text: '');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VariablePickerButton(controller: controller),
        ),
      ));
      await tester.tap(find.byIcon(Icons.code));
      await tester.pumpAndSettle();
      expect(find.text('Insert variable'), findsOneWidget);
      expect(find.text('TARGET'), findsOneWidget);
    });

    testWidgets('inserts placeholder at cursor when entry tapped',
        (tester) async {
      final controller = TextEditingController(text: 'pre suf');
      // Cursor between "pre " and "suf" (index 4).
      controller.selection = const TextSelection.collapsed(offset: 4);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VariablePickerButton(controller: controller),
        ),
      ));
      await tester.tap(find.byIcon(Icons.code));
      await tester.pumpAndSettle();
      // Tap the `${target.name}` row.
      await tester.tap(find.text(r'${target.name}').first);
      await tester.pumpAndSettle();
      expect(controller.text, r'pre ${target.name}suf');
      // Cursor moved to immediately after the inserted placeholder.
      expect(controller.selection.baseOffset, 4 + r'${target.name}'.length);
    });

    testWidgets('inserts at end when controller had no prior selection',
        (tester) async {
      final controller = TextEditingController(text: 'hello ');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VariablePickerButton(controller: controller),
        ),
      ));
      await tester.tap(find.byIcon(Icons.code));
      await tester.pumpAndSettle();
      await tester.tap(find.text(r'${target.name}').first);
      await tester.pumpAndSettle();
      expect(controller.text, r'hello ${target.name}');
    });
  });

  group('picker preview', () {
    testWidgets('renders a preview when the template has placeholders',
        (tester) async {
      final controller = TextEditingController(text: r'Hello ${target.name}!');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: VariablePickerButton(controller: controller)),
      ));
      await tester.tap(find.byIcon(Icons.code));
      await tester.pumpAndSettle();
      expect(find.textContaining('Hello M42!'), findsOneWidget);
    });

    testWidgets('hides the preview when the template has no placeholders',
        (tester) async {
      final controller = TextEditingController(text: 'plain literal');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: VariablePickerButton(controller: controller)),
      ));
      await tester.tap(find.byIcon(Icons.code));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.visibility), findsNothing);
    });

    // The preview must speak the same vocabulary the picker offers, or it
    // renders a sequencer example for a token the bound field cannot resolve.
    testWidgets('previews against the supplied vocabulary, not the default',
        (tester) async {
      final controller = TextEditingController(text: r'${integration.hms}');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VariablePickerButton(
            controller: controller,
            variables: watermarkVariableCatalog,
          ),
        ),
      ));
      await tester.tap(find.byIcon(Icons.code));
      await tester.pumpAndSettle();
      // The preview is the dialog's only SelectableText. Against the default
      // sequencer catalog this token is unknown and renders `${…?}`.
      final preview = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(preview.data, '2h12m');
    });

    testWidgets('forwards onChanged when the picker inserts a variable',
        (tester) async {
      var changed = 0;
      final controller = TextEditingController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VariablePickerButton(
            controller: controller,
            onChanged: () => changed++,
          ),
        ),
      ));
      await tester.tap(find.byIcon(Icons.code));
      await tester.pumpAndSettle();
      await tester.tap(find.text(r'${target.name}').first);
      await tester.pumpAndSettle();
      expect(changed, 1);
      expect(controller.text, r'${target.name}');
    });
  });

  group('catalog completeness', () {
    test('every catalog entry produces a non-empty placeholder', () {
      for (final entry in interpolationCatalog) {
        expect(entry.placeholder, isNotEmpty);
        expect(entry.placeholder, startsWith(r'${'));
        expect(entry.placeholder, endsWith('}'));
      }
    });
  });
}
