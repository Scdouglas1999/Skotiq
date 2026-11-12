// The plan open in the editor was gone after every restart: an update or a
// reboot of the rig left an empty Builder, and the owner's all-night plan had
// to be put back by hand. (Before that, only an unsaved plan survived, and
// only a crash: qa-night N04.) The open plan is now kept, saved or not.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';
import 'package:skotiq_core/src/services/open_plan_service.dart';
import 'package:skotiq_core/src/services/sequence_file_service.dart';
import 'package:skotiq_core/src/services/sequence_repository.dart';

import '../harness/in_memory_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A second launch on the first one's database.
  ProviderContainer nextLaunch(ProviderContainer first) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(first.read(databaseProvider)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  ProviderContainer firstLaunch() {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> keep(ProviderContainer container) => container
      .read(settingsDaoProvider)
      .setSetting(kOpenPlanKey, openPlanJson(container.read) ?? '');

  test('an unsaved plan comes back unsaved after a restart', () async {
    final first = firstLaunch();
    final editor = first.read(currentSequenceProvider.notifier);
    editor.createSequence(name: 'M34 tonight');
    editor.addNode(ExposureNode(durationSecs: 20, count: 40));
    expect(editor.isDirty, isTrue);
    await keep(first);

    final second = nextLaunch(first);
    final restored = await restoreOpenPlan(second.read);

    expect(restored?.sequence.name, 'M34 tonight');
    expect(restored?.unsaved, isTrue);
    final sequence = second.read(currentSequenceProvider)!;
    expect(sequence.nodes.values.whereType<ExposureNode>(), hasLength(1));
    expect(second.read(currentSequenceProvider.notifier).isDirty, isTrue);
  });

  test('a saved plan comes back as the saved plan, not as a draft', () async {
    final first = firstLaunch();
    final editor = first.read(currentSequenceProvider.notifier);
    editor.createSequence(name: 'Heart core all night');
    editor.addNode(ExposureNode(durationSecs: 300, count: 60));
    final id = await first
        .read(sequenceRepositoryProvider)
        .saveSequence(first.read(currentSequenceProvider)!);
    final open = first.read(currentSequenceProvider)!;
    editor.applyPersistedSave(
      savedFrom: open,
      databaseId: id,
      name: open.name,
      description: open.description,
      isTemplate: false,
    );
    expect(editor.isDirty, isFalse);
    await keep(first);

    final second = nextLaunch(first);
    final restored = await restoreOpenPlan(second.read);

    expect(restored?.unsaved, isFalse);
    final sequence = second.read(currentSequenceProvider)!;
    expect(sequence.name, 'Heart core all night');
    expect(sequence.databaseId, id);
    expect(second.read(currentSequenceProvider.notifier).isDirty, isFalse);
  });

  test(
    'a saved plan deleted from the library since comes back unsaved',
    () async {
      final first = firstLaunch();
      final editor = first.read(currentSequenceProvider.notifier);
      editor.createSequence(name: 'Deleted since');
      final document = jsonEncode({
        'sequence': first
            .read(sequenceFileServiceProvider)
            .sequenceToMap(first.read(currentSequenceProvider)!),
        'databaseId': 4711,
        'isDirty': false,
      });
      await first.read(settingsDaoProvider).setSetting(kOpenPlanKey, document);

      final second = nextLaunch(first);
      final restored = await restoreOpenPlan(second.read);

      expect(restored?.unsaved, isTrue);
      expect(second.read(currentSequenceProvider)?.name, 'Deleted since');
      expect(second.read(currentSequenceProvider)?.databaseId, isNull);
    },
  );

  test('an empty editor keeps nothing, and nothing comes back', () async {
    final first = firstLaunch();
    expect(openPlanJson(first.read), isNull);
    expect(await restoreOpenPlan(first.read), isNull);
    expect(first.read(currentSequenceProvider), isNull);
  });

  test('a plan already in the editor is left alone', () async {
    final first = firstLaunch();
    first.read(currentSequenceProvider.notifier).createSequence(name: 'Kept');
    await keep(first);

    final second = nextLaunch(first);
    second
        .read(currentSequenceProvider.notifier)
        .createSequence(name: 'Loaded by the checkpoint prompt');
    expect(await restoreOpenPlan(second.read), isNull);
    expect(
      second.read(currentSequenceProvider)?.name,
      'Loaded by the checkpoint prompt',
    );
  });

  test('a draft left by a build that kept only unsaved plans is restored '
      'once', () async {
    final first = firstLaunch();
    final editor = first.read(currentSequenceProvider.notifier);
    editor.createSequence(name: 'Old draft');
    final dao = first.read(settingsDaoProvider);
    await dao.setSetting(
      kLegacyEditorDraftKey,
      jsonEncode(
        first
            .read(sequenceFileServiceProvider)
            .sequenceToMap(first.read(currentSequenceProvider)!),
      ),
    );

    final second = nextLaunch(first);
    final restored = await restoreOpenPlan(second.read);
    expect(restored?.sequence.name, 'Old draft');
    expect(restored?.unsaved, isTrue);
    expect(await dao.getSetting(kLegacyEditorDraftKey), isEmpty);
  });

  group('keeping', () {
    test('nothing is written before the restore has been decided, so an '
        'editor still empty at launch does not erase the kept plan', () async {
      final first = firstLaunch();
      first.read(currentSequenceProvider.notifier).createSequence(name: 'Kept');
      await keep(first);
      final dao = first.read(settingsDaoProvider);
      final kept = await dao.getSetting(kOpenPlanKey);

      final second = nextLaunch(first);
      second.listen(openPlanLifecycleProvider, (_, _) {});
      await Future<void>.delayed(
        kOpenPlanDebounce + const Duration(milliseconds: 200),
      );
      expect(await dao.getSetting(kOpenPlanKey), kept);

      await restoreOpenPlan(second.read);
      expect(second.read(currentSequenceProvider)?.name, 'Kept');
    });

    test('an opened plan is written, and a closed one is cleared', () async {
      final container = firstLaunch();
      container.listen(openPlanLifecycleProvider, (_, _) {});
      await restoreOpenPlan(container.read);
      final dao = container.read(settingsDaoProvider);
      final editor = container.read(currentSequenceProvider.notifier);
      const settle = Duration(milliseconds: 1300);

      editor.createSequence(name: 'Tonight');
      editor.addNode(ExposureNode(durationSecs: 20, count: 40));
      await Future<void>.delayed(settle);
      final written = await dao.getSetting(kOpenPlanKey);
      expect(written, isNotEmpty);
      expect((jsonDecode(written!) as Map<String, dynamic>)['isDirty'], isTrue);

      editor.clearSequence(discardUnsaved: true);
      await Future<void>.delayed(settle);
      expect(await dao.getSetting(kOpenPlanKey), isEmpty);
    });
  });
}
