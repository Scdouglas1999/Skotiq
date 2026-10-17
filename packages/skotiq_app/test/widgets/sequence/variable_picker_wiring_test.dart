// VariablePickerButton shipped with zero call sites: the live-stacking
// watermark interpolates ${target} / ${integration.hms} / ${frames} /
// ${stack.method}, and the only place that template is authored offered no
// insert control — the operator had to type the names from the helper text by
// hand. This pins the picker to that field, and to that field's vocabulary.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/live_stacking_properties.dart';
import 'package:skotiq_app/widgets/sequence/variable_picker.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

void main() {
  testWidgets('the watermark template field offers the variable picker',
      (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SingleChildScrollView(
          child: LiveStackingProperties(
            colors: SkotiqColors.of(context),
            node: LiveStackingNode(watermarkText: 'M42'),
          ),
        ),
      ),
      size: const Size(600, 900),
      settle: false,
    );
    await tester.pump();

    final picker = find.byType(VariablePickerButton);
    expect(picker, findsOneWidget);

    // It is bound to the watermark controller, not some other field's.
    final watermarkField = tester.widget<TextField>(
      find.ancestor(of: picker, matching: find.byType(TextField)),
    );
    expect(watermarkField.controller!.text, 'M42');

    // The vocabulary it offers is the WATERMARK's, not the sequencer's. Both
    // interpolators pass an unknown token through literally, so a sequencer
    // variable picked here would be burned verbatim into the broadcast JPEG.
    expect(
      tester.widget<VariablePickerButton>(picker).variables,
      same(watermarkVariableCatalog),
    );

    // Opening it lists the variables the watermark actually interpolates, and
    // only those. `find.text` on the exact placeholder, not textContaining:
    // the field's own helper text names ${integration.hms} too and stays on
    // screen behind the dialog, so a loose matcher passes without a dialog.
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(find.text(r'${integration.hms}'), findsOneWidget);
    expect(find.text(r'${frames}'), findsOneWidget);
    expect(find.text(r'${filter}'), findsNothing);
    expect(find.text(r'${moon.phase}'), findsNothing);
  });
}
