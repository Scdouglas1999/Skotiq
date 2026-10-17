// Widget tests for the optional field-help affordance threaded through the
// imaging side-panel row widgets.
//
// `InputRow`, `InputRowEditable`, `DropdownRow`, and `SliderRowInteractive`
// each take an optional `helpId`. When supplied, a tooltipped help icon is
// appended after the label text (copy resolved from `helpFor`) and exposed to
// the accessibility tree via the affordance's Semantics label. When omitted,
// the row renders exactly as before — no help icon at all. These tests lock in
// both behaviours so a regression in the help wiring (or an accidental
// help icon on a help-less row) surfaces immediately.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_app/widgets/help/field_help_copy.dart';
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

  // The colors instance the imaging panels pass to every row widget.
  const colors = SkotiqColors.dark;

  group('InputRow help affordance', () {
    testWidgets('renders a help icon and semantics label when helpId is set',
        (tester) async {
      final handle = tester.ensureSemantics();
      final copy = helpFor(FieldHelpId.cameraGain);

      await _pump(
        tester,
        const InputRow(
          label: 'Gain',
          value: '100',
          colors: colors,
          helpId: FieldHelpId.cameraGain,
        ),
      );

      expect(find.text('Gain'), findsOneWidget);
      expect(find.byIcon(LucideIcons.helpCircle), findsOneWidget);
      expect(
        find.bySemanticsLabel('${copy.title}. ${copy.body}'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('renders no help icon when helpId is null', (tester) async {
      await _pump(
        tester,
        const InputRow(
          label: 'Gain',
          value: '100',
          colors: colors,
        ),
      );

      expect(find.text('Gain'), findsOneWidget);
      expect(find.byIcon(LucideIcons.helpCircle), findsNothing);
    });
  });

  group('InputRowEditable help affordance', () {
    testWidgets('renders a help icon and semantics label when helpId is set',
        (tester) async {
      final handle = tester.ensureSemantics();
      final copy = helpFor(FieldHelpId.cameraOffset);

      await _pump(
        tester,
        InputRowEditable(
          label: 'Offset',
          value: '30',
          colors: colors,
          onChanged: (_) {},
          helpId: FieldHelpId.cameraOffset,
        ),
      );

      expect(find.byIcon(LucideIcons.helpCircle), findsOneWidget);
      expect(
        find.bySemanticsLabel('${copy.title}. ${copy.body}'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('renders no help icon when helpId is null', (tester) async {
      await _pump(
        tester,
        InputRowEditable(
          label: 'Offset',
          value: '30',
          colors: colors,
          onChanged: (_) {},
        ),
      );

      expect(find.byIcon(LucideIcons.helpCircle), findsNothing);
    });
  });

  group('DropdownRow help affordance', () {
    testWidgets('renders a help icon and semantics label when helpId is set',
        (tester) async {
      final handle = tester.ensureSemantics();
      final copy = helpFor(FieldHelpId.captureFrameType);

      await _pump(
        tester,
        DropdownRow(
          label: 'Frame type',
          value: 'Light',
          items: const ['Light', 'Dark', 'Flat', 'Bias'],
          colors: colors,
          onChanged: (_) {},
          helpId: FieldHelpId.captureFrameType,
        ),
      );

      expect(find.byIcon(LucideIcons.helpCircle), findsOneWidget);
      expect(
        find.bySemanticsLabel('${copy.title}. ${copy.body}'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('renders no help icon when helpId is null', (tester) async {
      await _pump(
        tester,
        DropdownRow(
          label: 'Frame type',
          value: 'Light',
          items: const ['Light', 'Dark', 'Flat', 'Bias'],
          colors: colors,
          onChanged: (_) {},
        ),
      );

      expect(find.byIcon(LucideIcons.helpCircle), findsNothing);
    });
  });

  group('SliderRowInteractive help affordance', () {
    testWidgets('renders a help icon and semantics label when helpId is set',
        (tester) async {
      final handle = tester.ensureSemantics();
      final copy = helpFor(FieldHelpId.ditherAmount);

      await _pump(
        tester,
        SliderRowInteractive(
          label: 'Dither',
          value: 3,
          min: 0,
          max: 10,
          suffix: 'px',
          colors: colors,
          onChanged: (_) {},
          helpId: FieldHelpId.ditherAmount,
        ),
      );

      expect(find.byIcon(LucideIcons.helpCircle), findsOneWidget);
      expect(
        find.bySemanticsLabel('${copy.title}. ${copy.body}'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('renders no help icon when helpId is null', (tester) async {
      await _pump(
        tester,
        SliderRowInteractive(
          label: 'Dither',
          value: 3,
          min: 0,
          max: 10,
          suffix: 'px',
          colors: colors,
          onChanged: (_) {},
        ),
      );

      expect(find.byIcon(LucideIcons.helpCircle), findsNothing);
    });
  });
}
