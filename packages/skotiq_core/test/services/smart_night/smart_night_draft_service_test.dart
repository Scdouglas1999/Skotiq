import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/models/planning/target_suggestion.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/smart_night/smart_night_draft_service.dart';
import 'package:skotiq_core/src/services/smart_night_service.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show TargetVisibilityInfo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.SkotiqDatabase database;
  late DateTime now;
  late SmartNightDraftService service;

  setUp(() {
    database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    now = DateTime.utc(2026, 5, 22, 3);
    service = SmartNightDraftService(
      settingsDao: database.settingsDao,
      now: () => now,
    );
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'savePending overwrites one draft per profile per astronomical day',
    () async {
      await service.savePending(
        profileId: 'rig-a',
        astronomicalDay: DateTime.utc(2026, 5, 21),
        plan: testSmartNightPlan('M51'),
      );
      await service.savePending(
        profileId: 'rig-a',
        astronomicalDay: DateTime.utc(2026, 5, 21),
        plan: testSmartNightPlan('M101'),
      );

      final draft = await service.loadPending(
        profileId: 'rig-a',
        astronomicalDay: DateTime.utc(2026, 5, 21),
      );

      expect(draft, isNotNull);
      expect(draft!.status, SmartNightDraftStatus.pending);
      expect(draft.plan.plannedTargets.single.suggestion.targetName, 'M101');
      expect(await service.loadAll(), hasLength(1));
    },
  );

  test('markStarted hides the draft from pending lookups', () async {
    final draft = await service.savePending(
      profileId: 'rig-a',
      astronomicalDay: DateTime.utc(2026, 5, 21),
      plan: testSmartNightPlan('M51'),
    );

    await service.markStarted(draft.id);

    expect(
      await service.loadPending(
        profileId: 'rig-a',
        astronomicalDay: DateTime.utc(2026, 5, 21),
      ),
      isNull,
    );
    expect(
      (await service.loadById(draft.id))!.status,
      SmartNightDraftStatus.started,
    );
  });

  test('cleanupExpiredPending removes stale pending drafts only', () async {
    final stale = await service.savePending(
      profileId: 'rig-a',
      astronomicalDay: DateTime.utc(2026, 5, 20),
      plan: testSmartNightPlan('M51'),
    );
    now = now.add(const Duration(hours: 25));
    final fresh = await service.savePending(
      profileId: 'rig-b',
      astronomicalDay: DateTime.utc(2026, 5, 21),
      plan: testSmartNightPlan('M101'),
    );
    await service.markStarted(fresh.id);

    await service.cleanupExpiredPending();

    expect(await service.loadById(stale.id), isNull);
    expect(
      (await service.loadById(fresh.id))!.status,
      SmartNightDraftStatus.started,
    );
  });
}

SmartNightPlan testSmartNightPlan(String targetName) {
  final root = InstructionSetNode(id: 'root', name: 'Root', childIds: const []);
  return SmartNightPlan(
    sequence: Sequence(
      id: 'seq-$targetName',
      name: 'Smart Night $targetName',
      nodes: {'root': root},
      rootNodeId: 'root',
      createdAt: DateTime.utc(2026, 5, 22),
      modifiedAt: DateTime.utc(2026, 5, 22),
    ),
    plannedTargets: [
      SmartNightPlannedTarget(
        suggestion: TargetSuggestion(
          targetId: 1,
          targetName: targetName,
          raHours: 13.5,
          decDegrees: 47.2,
          totalScore: 90,
          visibility: const TargetVisibilityInfo(
            currentAltitude: 60,
            currentAzimuth: 180,
            airmass: 1.2,
            moonDistance: 90,
          ),
        ),
        windowStart: DateTime.utc(2026, 5, 22, 2),
        windowEnd: DateTime.utc(2026, 5, 22, 5),
        filterPlans: const [
          SmartNightFilterPlan(filterName: 'L', count: 10, durationSecs: 60),
        ],
        integrationSecs: 600,
        rationale: 'High altitude',
      ),
    ],
    totalIntegrationSecs: 600,
    estimatedWallClockSecs: 900,
    warnings: const [],
    strategy: SmartNightStrategy.autoLrgb,
    settings: const SmartNightSettings(),
    context: SmartNightContext(
      windowStart: DateTime.utc(2026, 5, 22, 2),
      windowEnd: DateTime.utc(2026, 5, 22, 5),
    ),
  );
}
