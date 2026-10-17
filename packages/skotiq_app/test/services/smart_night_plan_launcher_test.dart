import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/services/smart_night_plan_launcher.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockSequenceExecutor extends Mock implements SequenceExecutor {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('launch loads plan, starts executor, then marks draft started',
      () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final executor = _MockSequenceExecutor();
    when(executor.start).thenAnswer((_) async {});

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sequenceExecutorProvider.overrideWithValue(executor),
      ],
    );
    addTearDown(container.dispose);

    final plan = _plan('M51');
    final draft = await SmartNightDraftService(
      settingsDao: db.settingsDao,
    ).savePending(
      profileId: 'profile-1',
      astronomicalDay: DateTime(2026, 5, 22),
      plan: plan,
    );

    await const SmartNightPlanLauncher().launch(
      read: container.read,
      plan: plan,
      draftId: draft.id,
    );

    expect(container.read(currentSequenceProvider)?.name, 'Smart Night M51');
    verify(executor.start).called(1);

    final updated = await SmartNightDraftService(
      settingsDao: db.settingsDao,
    ).loadById(draft.id);
    expect(updated?.status, SmartNightDraftStatus.started);
  });

  test('launch leaves draft pending when executor start fails', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final executor = _MockSequenceExecutor();
    when(executor.start).thenThrow(Exception('backend unavailable'));

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sequenceExecutorProvider.overrideWithValue(executor),
      ],
    );
    addTearDown(container.dispose);

    final plan = _plan('M31');
    final draft = await SmartNightDraftService(
      settingsDao: db.settingsDao,
    ).savePending(
      profileId: 'profile-1',
      astronomicalDay: DateTime(2026, 5, 22),
      plan: plan,
    );

    await expectLater(
      const SmartNightPlanLauncher().launch(
        read: container.read,
        plan: plan,
        draftId: draft.id,
      ),
      throwsA(isA<Exception>()),
    );

    expect(container.read(currentSequenceProvider)?.name, 'Smart Night M31');
    final updated = await SmartNightDraftService(
      settingsDao: db.settingsDao,
    ).loadById(draft.id);
    expect(updated?.status, SmartNightDraftStatus.pending);
  });
}

SmartNightPlan _plan(String targetName) {
  final root = InstructionSetNode(
    id: 'root',
    name: 'Smart Night Root',
    childIds: const ['target'],
  );
  final target = TargetHeaderNode(
    id: 'target',
    name: targetName,
    targetName: targetName,
    raHours: 13.5,
    decDegrees: 47.2,
    parentId: 'root',
  );
  final sequence = Sequence.create(
    id: 'smart-night-$targetName',
    name: 'Smart Night $targetName',
    rootNodeId: root.id,
    nodes: {
      root.id: root,
      target.id: target,
    },
  );
  final context = SmartNightContext(
    windowStart: DateTime(2026, 5, 22, 21),
    windowEnd: DateTime(2026, 5, 23, 5),
  );
  return SmartNightPlan(
    sequence: sequence,
    plannedTargets: const [],
    totalIntegrationSecs: 0,
    estimatedWallClockSecs: 0,
    warnings: const [],
    strategy: SmartNightStrategy.autoLrgb,
    settings: const SmartNightSettings(),
    context: context,
  );
}
