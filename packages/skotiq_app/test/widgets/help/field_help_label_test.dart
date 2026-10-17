// Widget tests for the reusable field-help affordances.
//
// `FieldHelpLabel` and `helpAffordance` are shared across the onboarding spine,
// the equipment-profile editor and the hardware-preset editor. These tests
// prove they render the label + help icon, enforce the mutually-exclusive
// help-payload contract (a misconfigured affordance must throw, not render an
// empty mysterious icon), and expose the help text to the accessibility tree.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/widgets/help/field_help_label.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FieldHelpLabel', () {
    testWidgets('renders the label text and a help icon', (tester) async {
      await _pump(
        tester,
        const FieldHelpLabel(
          label: 'Focal length (mm)',
          help: 'The optical focal length of the imaging train.',
        ),
      );

      expect(find.text('Focal length (mm)'), findsOneWidget);
      expect(find.byIcon(LucideIcons.helpCircle), findsOneWidget);
    });

    testWidgets('rich form (title + body) renders the label and icon',
        (tester) async {
      await _pump(
        tester,
        const FieldHelpLabel(
          label: 'Gain',
          helpTitle: 'Recommended gain',
          helpBody: 'Higher gain lowers read noise.',
        ),
      );

      expect(find.text('Gain'), findsOneWidget);
      expect(find.byIcon(LucideIcons.helpCircle), findsOneWidget);
    });

    testWidgets('exposes help text to the semantics tree', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const FieldHelpLabel(
          label: 'Aperture (mm)',
          help: 'The clear aperture diameter.',
        ),
      );

      expect(
        find.bySemanticsLabel('The clear aperture diameter.'),
        findsOneWidget,
      );
      handle.dispose();
    });

    test('asserts when neither help nor title/body is supplied', () {
      expect(
        () => FieldHelpLabel(label: 'X'),
        throwsAssertionError,
      );
    });

    test('asserts when both help and rich payload are supplied', () {
      expect(
        () => FieldHelpLabel(
          label: 'X',
          help: 'plain',
          helpTitle: 'rich',
          helpBody: 'body',
        ),
        throwsAssertionError,
      );
    });
  });

  group('helpAffordance', () {
    testWidgets('renders just the tooltipped help icon', (tester) async {
      await _pump(
        tester,
        Builder(
          builder: (context) => helpAffordance(
            context,
            message: 'Inline hint beside an existing label.',
          ),
        ),
      );

      expect(find.byIcon(LucideIcons.helpCircle), findsOneWidget);
      // No label text is rendered for the inline affordance.
      expect(find.text('Inline hint beside an existing label.'), findsNothing);
    });

    testWidgets('throws when neither message nor title/body is supplied',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                expect(
                  () => helpAffordance(context),
                  throwsArgumentError,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    });

    testWidgets('throws when both message and rich payload are supplied',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                expect(
                  () => helpAffordance(
                    context,
                    message: 'plain',
                    title: 'rich',
                    body: 'body',
                  ),
                  throwsArgumentError,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    });
  });
}
