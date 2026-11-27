// A step field takes one range in every editor that sets it: a value
// the inline popover or a Start Guiding step accepts survives a commit in the
// inspector instead of being clamped to a narrower range there.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_property_widgets.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<HarnessHandle> pumpNode(
    WidgetTester tester,
    SequenceNode node,
  ) async {
    final sequence = Sequence.create(
      name: 'Ranges',
      rootNodeId: node.id,
      nodes: {node.id: node},
    );
    final handle = await pumpAppScreen(
      tester,
      const SizedBox(
        width: 420,
        height: 1400,
        child: NodePropertiesPanel(colors: SkotiqColors.dark),
      ),
      size: const Size(900, 1400),
    );
    handle.container
        .read(currentSequenceProvider.notifier)
        .loadSequence(sequence, discardUnsaved: true);
    handle.container.read(selectedNodeIdProvider.notifier).state = node.id;
    await tester.pumpAndSettle();
    return handle;
  }

  Future<void> commit(WidgetTester tester, String label, String text) async {
    final field = find.descendant(
      of: find.widgetWithText(NodePropertyField, label).first,
      matching: find.byType(TextField),
    );
    await tester.enterText(field, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  T stored<T extends SequenceNode>(HarnessHandle handle, String id) =>
      handle.container.read(currentSequenceProvider)!.nodes[id]! as T;

  testWidgets(
      'a two-hour delay, which the inline popover takes, is kept by the inspector',
      (
    tester,
  ) async {
    final node = DelayNode(seconds: 60);
    final handle = await pumpNode(tester, node);

    await commit(tester, 'Duration', '7200');

    expect(stored<DelayNode>(handle, node.id).seconds, 7200);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'a Dither step takes a zero amount and the Start Guiding '
      'settle range', (tester) async {
    final node = DitherNode();
    final handle = await pumpNode(tester, node);

    await commit(tester, 'Dither amount', '0');
    await commit(tester, 'Settle threshold', '10');
    await commit(tester, 'Settle time', '1');

    final dither = stored<DitherNode>(handle, node.id);
    expect(dither.pixels, 0);
    expect(dither.settlePixels, 10);
    expect(dither.settleTime, 1);
    await tester.pump(const Duration(seconds: 1));
  });
}
