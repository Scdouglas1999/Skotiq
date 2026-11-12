// The one command every palette, menu and drop zone inserts a new step with.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

void main() {
  late ProviderContainer container;
  CurrentSequenceNotifier editor() =>
      container.read(currentSequenceProvider.notifier);
  Sequence sequence() => container.read(currentSequenceProvider)!;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  test('a step and the children it comes with are one undo step', () {
    editor().createSequence();
    final recovery = RecoveryNode(id: 'recovery');
    final autofocus = AutofocusNode(id: 'af');

    expect(editor().insertNewNode(recovery, children: [autofocus]), isTrue);
    expect(sequence().nodes['recovery']!.childIds, ['af']);
    expect(sequence().nodes['af']!.parentId, 'recovery');

    editor().undo();
    expect(sequence().nodes.containsKey('recovery'), isFalse);
    expect(sequence().nodes.containsKey('af'), isFalse);
  });

  test('with no sequence open, one is started for the step', () {
    expect(container.read(currentSequenceProvider), isNull);
    expect(
      editor().insertNewNode(DelayNode(id: 'delay'), parentId: 'stale'),
      isTrue,
    );
    final root = sequence().rootNode!;
    expect(root.childIds, ['delay']);
  });

  test('nothing changes while a run owns the tree', () {
    editor().createSequence();
    final before = sequence();
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.running);

    expect(editor().insertNewNode(DelayNode(id: 'delay')), isFalse);
    expect(sequence(), same(before));
  });

  test('a snippet with no sequence open starts one', () {
    editor().insertSnippet(
      TemplateSnippet(
        id: 'snippet',
        name: 'Delay',
        description: '',
        category: SnippetCategory.custom,
        iconName: 'timer',
        nodeData: const [
          {'nodeType': 'Delay', 'seconds': 3.0},
        ],
        createdAt: DateTime.utc(2026),
      ),
    );
    final root = sequence().rootNode!;
    expect(root.childIds, hasLength(1));
    expect(sequence().nodes[root.childIds.single], isA<DelayNode>());
  });
}
