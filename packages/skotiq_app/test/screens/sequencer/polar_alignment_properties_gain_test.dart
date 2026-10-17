// A Polar Alignment node carries `gain`/`offset` as nullable overrides: null
// rides to `PolarAlignConfig.gain = None` and the alignment exposures then run
// at whatever gain the camera already holds. The number field can only show a
// number, so it shows 0 — and 0 is also a legal gain. Without a word under the
// field the panel states a gain the node does not carry.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

ProviderContainer _seed(PolarAlignmentNode polar) {
  final root = InstructionSetNode(id: 'root', childIds: [polar.id]);
  final sequence = Sequence.create(
    name: 'Polar Alignment Properties Test',
    rootNodeId: root.id,
    nodes: {
      root.id: root,
      polar.id: polar.copyWith(parentId: root.id),
    },
  );
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = sequence;
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    currentSequenceProvider.overrideWith((_) => notifier),
  ]);
  addTearDown(container.dispose);
  container.read(selectedNodeIdProvider.notifier).state = polar.id;
  return container;
}

Future<void> _pumpPanel(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 880,
            height: 2400,
            child: NodePropertiesPanel(colors: SkotiqColors.dark),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
      'an unset polar-alignment gain/offset says the camera keeps its '
      'own, rather than claiming 0', (tester) async {
    final container = _seed(PolarAlignmentNode(id: 'polar'));
    await _pumpPanel(tester, container);

    expect(
      find.text('Unset — the camera keeps its current gain'),
      findsOneWidget,
    );
    expect(
      find.text('Unset — the camera keeps its current offset'),
      findsOneWidget,
    );
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an explicit gain/offset drops the unset notice', (tester) async {
    final container =
        _seed(PolarAlignmentNode(id: 'polar', gain: 0, offset: 0));
    await _pumpPanel(tester, container);

    // Zero is a legal, deliberate gain — the field must not then read as unset.
    expect(
      find.text('Unset — the camera keeps its current gain'),
      findsNothing,
    );
    expect(
      find.text('Unset — the camera keeps its current offset'),
      findsNothing,
    );
    // Drain live validation's 500 ms debounce so the binding does not fail
    // the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });
}
