import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('explicit save re-anchors the open document and clears dirty state', () {
    final notifier = CurrentSequenceNotifier();
    final sequence = Sequence.create(
      name: 'Original',
      description: 'Before save',
      isTemplate: true,
    );
    notifier.loadSequence(sequence);
    notifier.setName('Dirty edit');
    expect(notifier.isDirty, isTrue);

    notifier.applyPersistedSave(
      expectedSequenceId: sequence.id,
      databaseId: 42,
      name: 'Saved copy',
      description: 'After save',
      isTemplate: false,
    );

    expect(notifier.state?.databaseId, 42);
    expect(notifier.state?.name, 'Saved copy');
    expect(notifier.state?.description, 'After save');
    expect(notifier.state?.isTemplate, isFalse);
    expect(notifier.isDirty, isFalse);
  });

  test('delayed save cannot re-anchor a different open document', () {
    final notifier = CurrentSequenceNotifier();
    final first = Sequence.create(name: 'First');
    final second = Sequence.create(name: 'Second');
    notifier.loadSequence(second);

    notifier.applyPersistedSave(
      expectedSequenceId: first.id,
      databaseId: 99,
      name: 'Wrong',
      description: '',
      isTemplate: false,
    );

    expect(notifier.state?.id, second.id);
    expect(notifier.state?.databaseId, isNull);
    expect(notifier.state?.name, 'Second');
  });

  test('file export marks the exact exported snapshot clean', () {
    final notifier = CurrentSequenceNotifier();
    notifier.loadSequence(Sequence.create(name: 'Export me'));
    notifier.setDescription('Ready to export');
    final exported = notifier.state!;

    expect(notifier.markSavedIfCurrent(exported), isTrue);
    expect(notifier.isDirty, isFalse);
  });

  test('delayed file export cannot clear newer edits', () {
    final notifier = CurrentSequenceNotifier();
    notifier.loadSequence(Sequence.create(name: 'Export me'));
    notifier.setDescription('Snapshot sent to save dialog');
    final exported = notifier.state!;

    notifier.setDescription('New edit while picker was open');

    expect(notifier.markSavedIfCurrent(exported), isFalse);
    expect(notifier.state?.description, 'New edit while picker was open');
    expect(notifier.isDirty, isTrue);
  });
}
