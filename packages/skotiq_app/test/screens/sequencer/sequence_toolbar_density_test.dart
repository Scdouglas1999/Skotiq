// The canvas bar's density control at its two inline tiers: the labelled
// SegmentedControl on a wide bar and the three glyph buttons on a medium one,
// plus the persisted write a tap produces.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('labelled tier shows the segmented density control and writes',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SequenceToolbar(colors: SkotiqColors.of(context)),
      ),
      size: const Size(1400, 800),
      settle: false,
    );
    await tester.pump();

    final control = find.byType(SegmentedControl);
    expect(control, findsOneWidget);
    for (final mode in SequencerDensity.values) {
      expect(
        find.descendant(of: control, matching: find.text(mode.label)),
        findsOneWidget,
      );
    }

    await tester.tap(
      find.descendant(of: control, matching: find.text('Compact')),
    );
    await tester.pump();
    await tester.pump();

    expect(
      await SettingsDao(handle.database).getSetting('sequencer_density_v1'),
      'compact',
    );
    // Live validation debounces 500 ms; drain it so teardown sees no timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('glyph tier shows three density buttons and writes',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SequenceToolbar(colors: SkotiqColors.of(context)),
      ),
      // The glyph band is [inlineToggles, labelledToggles); its edges move
      // with the platform's button extent (28 desktop / 48 touch floor), so
      // 1100 px is inside for both.
      size: const Size(1100, 800),
      settle: false,
    );
    await tester.pump();

    expect(find.byType(SegmentedControl), findsNothing);
    for (final mode in SequencerDensity.values) {
      expect(
        find.byWidgetPredicate(
          (w) => w is SkotiqIconButton && w.tooltip == '${mode.label} density',
        ),
        findsOneWidget,
      );
    }

    await tester.tap(find.byWidgetPredicate(
      (w) => w is SkotiqIconButton && w.tooltip == 'Comfortable density',
    ));
    await tester.pump();
    await tester.pump();

    expect(
      await SettingsDao(handle.database).getSetting('sequencer_density_v1'),
      'comfortable',
    );
    await tester.pump(const Duration(seconds: 1));
  });
}
