import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';
import 'canvas_bar_menu.dart';

void main() {
  testWidgets('sequencer drift settings persist across closing and reopening',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SequenceToolbar(colors: SkotiqColors.of(context)),
      ),
      size: const Size(1600, 900),
    );
    addTearDown(handle.database.close);

    await tapCanvasBarAction(tester, 'Recenter after drift…');
    await tester.pumpAndSettle();
    expect(find.text('RECENTER AFTER DRIFT'), findsOneWidget);
    expect(find.textContaining('Applies to the next run'), findsOneWidget);
    final input = find.descendant(
      of: find.byKey(const ValueKey('frame-watch-drift-limit')),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(input).controller!.text, '60');
    expect(
        handle.container
            .read(frameWatchSettingsProvider)
            .requireValue
            .recenterEnabled,
        isTrue);

    await tester.enterText(input, '45');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('frame-watch-recenter-enabled')));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    final settings =
        handle.container.read(frameWatchSettingsProvider).requireValue;
    expect(settings.driftLimitArcsec, 45);
    expect(settings.recenterEnabled, isFalse);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    handle.container.invalidate(frameWatchSettingsProvider);
    await tapCanvasBarAction(tester, 'Recenter after drift…');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, '45');
    expect(
        handle.container
            .read(frameWatchSettingsProvider)
            .requireValue
            .recenterEnabled,
        isFalse);
    expect(tester.takeException(), isNull);
  });
}
