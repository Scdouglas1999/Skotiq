// PUT /api/sequencer/editor-sequence: a remote client writes its open plan
// into the host's editor, the last writer wins, the host operator is told when
// their unsaved edits are replaced, and a run's plan is never changed.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

Sequence _plan(String name, {int count = 5}) {
  const rootId = 'root';
  const exposureId = 'expose';
  return Sequence.create(
    id: 'seq-$name',
    name: name,
    nodes: {
      rootId: InstructionSetNode(
        id: rootId,
        name: 'Sequence',
        childIds: const [exposureId],
      ),
      exposureId: ExposureNode(
        id: exposureId,
        parentId: rootId,
        durationSecs: 10,
        count: count,
        frameType: FrameType.light,
      ),
    },
    rootNodeId: rootId,
  );
}

Request _put(Map<String, dynamic> body) => Request(
  'PUT',
  Uri.parse('http://localhost/api/sequencer/editor-sequence'),
  body: jsonEncode(body),
);

void main() {
  test('the client plan replaces the host editor and keeps its database id '
      'and unsaved flag', () async {
    final container = createHeadlessTestContainer();
    addTearDown(container.dispose);
    final handlers = SequencerHandlers(container);
    final files = container.read(sequenceFileServiceProvider);

    final response = await translateHandlerErrors(
      handlers.handleSequencerPutEditorSequence(
        _put({
          'open': true,
          'sequence': files.sequenceToMap(_plan('QA M45 pair')),
          'databaseId': 4,
          'isDirty': true,
        }),
      ),
    );

    expect(response.statusCode, 200);
    final open = container.read(currentSequenceProvider);
    expect(open?.name, 'QA M45 pair');
    expect(open?.databaseId, 4);
    expect(container.read(currentSequenceProvider.notifier).isDirty, isTrue);
    expect(container.read(uiNotificationProvider), isEmpty);
  });

  test(
    'replacing unsaved edits made on the host tells the host operator',
    () async {
      final container = createHeadlessTestContainer();
      addTearDown(container.dispose);
      final handlers = SequencerHandlers(container);
      final files = container.read(sequenceFileServiceProvider);
      final editor = container.read(currentSequenceProvider.notifier);
      editor.loadSequence(_plan('Host draft'));
      editor.setName('Host draft, edited');
      expect(editor.isDirty, isTrue);

      await handlers.handleSequencerPutEditorSequence(
        _put({
          'sequence': files.sequenceToMap(_plan('Client plan')),
          'isDirty': false,
        }),
      );

      expect(container.read(currentSequenceProvider)?.name, 'Client plan');
      final notes = container.read(uiNotificationProvider);
      expect(notes, hasLength(1));
      expect(notes.single.title, 'Plan changed remotely');

      // The client writing again over its own previous version is not news.
      await handlers.handleSequencerPutEditorSequence(
        _put({
          'sequence': files.sequenceToMap(_plan('Client plan', count: 8)),
          'isDirty': true,
        }),
      );
      expect(container.read(uiNotificationProvider), hasLength(1));
    },
  );

  test('a run holding the editor refuses the write with 409', () async {
    final container = createHeadlessTestContainer();
    addTearDown(container.dispose);
    final handlers = SequencerHandlers(container);
    final files = container.read(sequenceFileServiceProvider);
    container
        .read(currentSequenceProvider.notifier)
        .loadSequence(_plan('Running plan'));
    container.read(runRecordProvider.notifier).setLifecycle(SequenceExecutionState.running);

    final response = await handlers.handleSequencerPutEditorSequence(
      _put({'sequence': files.sequenceToMap(_plan('Client plan'))}),
    );

    expect(response.statusCode, 409);
    expect(
      jsonDecode(await response.readAsString())['error'],
      'sequence_editor_locked',
    );
    expect(container.read(currentSequenceProvider)?.name, 'Running plan');
  });
}
