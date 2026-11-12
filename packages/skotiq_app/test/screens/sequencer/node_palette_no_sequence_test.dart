// With no sequence open (a linked client showing "No sequence"), the
// palette's add did nothing: the editor drops a node that has no sequence to
// go into. It now starts a sequence for the node, as "Add a target" does.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_palette.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('adding a node with no sequence open starts one with the node',
      (tester) async {
    final notifier = CurrentSequenceNotifier();
    final handle = await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => NodePalette(
          colors: SkotiqColors.of(context),
          isMobileSheet: true,
        ),
      ),
      size: const Size(390, 844),
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => notifier),
      ],
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(handle.container.read(currentSequenceProvider), isNull);

    await tester.tap(find.text('Take exposures').first);
    await tester.pump();

    final sequence = handle.container.read(currentSequenceProvider);
    expect(sequence, isNotNull, reason: 'the tap must start a sequence');
    expect(
      sequence!.nodes.values.whereType<ExposureNode>(),
      hasLength(1),
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the desktop add button is a labeled button that adds the node',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final notifier = CurrentSequenceNotifier();
    final handle = await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => NodePalette(colors: SkotiqColors.of(context)),
      ),
      size: const Size(1400, 900),
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => notifier),
      ],
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));

    final add = find.bySemanticsLabel('Add Take exposures to the sequence');
    expect(add, findsOneWidget);
    tester.semantics.tap(
      find.semantics.byLabel('Add Take exposures to the sequence'),
    );
    await tester.pump();

    final sequence = handle.container.read(currentSequenceProvider);
    expect(sequence?.nodes.values.whereType<ExposureNode>(), hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    semantics.dispose();
  });
}
