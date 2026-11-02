// The Builder's unsaved plan was lost when the app died (qa-night N04: an
// 18-node plan gone after a crash). It is now kept while unsaved and put back
// at the next launch.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';
import 'package:skotiq_core/src/services/editor_draft_service.dart';

import '../harness/in_memory_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an unsaved plan is kept, and comes back unsaved after a restart',
      () async {
    final first = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(first.dispose);
    final editor = first.read(currentSequenceProvider.notifier);
    editor.createSequence(name: 'M34 tonight');
    editor.addNode(ExposureNode(durationSecs: 20, count: 40));
    expect(editor.isDirty, isTrue);

    final draft = editorDraftJson(first.read);
    expect(draft, isNotNull);
    final dao = first.read(settingsDaoProvider);
    await dao.setSetting(kEditorDraftKey, draft!);

    // The next launch: the same database, an empty Builder.
    final second = ProviderContainer(overrides: [
      settingsDaoProvider.overrideWithValue(dao),
    ]);
    addTearDown(second.dispose);
    final restored = await restoreEditorDraft(second.read);
    expect(restored?.name, 'M34 tonight');
    final sequence = second.read(currentSequenceProvider)!;
    expect(sequence.nodes.values.whereType<ExposureNode>(), hasLength(1));
    expect(second.read(currentSequenceProvider.notifier).isDirty, isTrue);
  });

  test('a saved or empty Builder keeps no draft', () {
    final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    expect(editorDraftJson(container.read), isNull);
    final editor = container.read(currentSequenceProvider.notifier);
    editor.createSequence(name: 'Saved plan');
    editor.markSaved();
    expect(editorDraftJson(container.read), isNull);
  });
}
