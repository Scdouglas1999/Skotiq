// Imaging → Capture: the save folder and the file-name pattern are routinely
// longer than their fields, which cut them short with an ellipsis. The whole
// value has to be reachable, so each field offers it on hover, and a folder
// is cut from the front so the part that tells folders apart stays visible.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/capture_panel.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const _folder = r'C:\Users\observer\Pictures\Skotiq\2026-10-17\NGC7380';
const _pattern = r'$TARGET_$FILTER_$EXPOSURE_$FRAMENR';

void main() {
  testWidgets('the save folder and the name pattern carry their full value',
      (tester) async {
    await pumpAppScreen(
      tester,
      const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 244,
          height: 900,
          child: CapturePanel(colors: SkotiqColors.dark),
        ),
      ),
      size: const Size(600, 900),
      settle: false,
      extraOverrides: [
        namingPatternProvider.overrideWithValue(
          const NamingPattern(pattern: _pattern, baseDir: _folder),
        ),
      ],
    );
    await tester.pump();

    for (final value in <String>[_folder, _pattern]) {
      final field = find.byWidgetPredicate(
        (widget) => widget is ReadOnlyField && widget.value == value,
      );
      expect(field, findsOneWidget);
      final tooltip = tester.widget<SkotiqTooltip>(
        find.descendant(of: field, matching: find.byType(SkotiqTooltip)),
      );
      expect(tooltip.message, value);
    }
  });

  testWidgets('a folder too long for its field shows its end, not its start',
      (tester) async {
    await pumpAppScreen(
      tester,
      const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 244,
          height: 900,
          child: CapturePanel(colors: SkotiqColors.dark),
        ),
      ),
      size: const Size(600, 900),
      settle: false,
      extraOverrides: [
        namingPatternProvider.overrideWithValue(
          const NamingPattern(pattern: _pattern, baseDir: _folder),
        ),
      ],
    );
    await tester.pump();

    final shown = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byWidgetPredicate(
              (widget) => widget is ReadOnlyField && widget.value == _folder,
            ),
            matching: find.byType(Text),
          ),
        )
        .single
        .data!;
    expect(shown, startsWith('…'));
    expect(shown, endsWith(r'\NGC7380'));
  });
}
