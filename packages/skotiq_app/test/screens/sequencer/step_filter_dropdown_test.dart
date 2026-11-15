// A step's filter dropdown shows the step's own filter: the slot its name
// means by the filter-name rule, or the name itself marked when the wheel has
// no such filter. It never shows another slot because of a stored index (an
// "R" step from an LRGB snippet once read "G" on a wheel without R).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _wheel = ['L', 'G', 'B', 'Dark', 'Ha 3nm', 'Ha 7nm', 'Baader OIII 7nm'];

Future<void> _show(WidgetTester tester, SequenceNode step) async {
  final root = InstructionSetNode(id: 'root', childIds: [step.id]);
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = Sequence.create(
    name: 'Filters',
    rootNodeId: root.id,
    nodes: {root.id: root, step.id: step.copyWith(parentId: root.id)},
  );
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith((_) => notifier),
      effectiveFiltersProvider.overrideWithValue(_wheel),
    ],
  );
  addTearDown(container.dispose);
  container.read(selectedNodeIdProvider.notifier).state = step.id;
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
      'a Change Filter step to a filter the wheel lacks shows its own '
      'name, not the slot at its old index', (tester) async {
    await _show(
      tester,
      FilterChangeNode(id: 'r', filterName: 'R', filterPosition: 1),
    );
    expect(find.text('R (not on the wheel)'), findsOneWidget);
    expect(find.text('G'), findsNothing);
    expect(
      find.text('Filter is not on the wheel or in the profile.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an exposure step shows the slot its name means', (tester) async {
    await _show(
      tester,
      ExposureNode(id: 'o', durationSecs: 60, filter: 'OIII', filterIndex: 0),
    );
    expect(find.text('Baader OIII 7nm'), findsOneWidget);
    expect(find.textContaining('not on the wheel'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a name two slots could be says so', (tester) async {
    await _show(
      tester,
      ExposureNode(id: 'h', durationSecs: 300, filter: 'Ha', filterIndex: 1),
    );
    expect(find.text('Ha (several slots)'), findsOneWidget);
    expect(
      find.text('Several slots are this filter. Pick the one to use.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 1));
  });
}
