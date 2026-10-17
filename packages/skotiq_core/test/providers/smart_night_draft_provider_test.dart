import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/smart_night_draft_provider.dart';
import 'package:skotiq_core/src/services/smart_night/smart_night_draft_service.dart';
import '../services/smart_night/smart_night_draft_service_test.dart'
    show testSmartNightPlan;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pending draft provider reads the shared draft service', () async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final service = container.read(smartNightDraftServiceProvider);
    await service.savePending(
      profileId: 'rig-a',
      astronomicalDay: DateTime.utc(2026, 5, 21),
      plan: testSmartNightPlan('M51'),
    );

    final draft = await container.read(
      pendingSmartNightDraftProvider(
        SmartNightDraftLookup(
          profileId: 'rig-a',
          astronomicalDay: DateTime.utc(2026, 5, 21),
        ),
      ).future,
    );

    expect(draft, isA<SmartNightDraft>());
    expect(draft!.plan.plannedTargets.single.suggestion.targetName, 'M51');
  });
}
