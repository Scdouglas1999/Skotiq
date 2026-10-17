import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('campaign rollups resolve targets from the imaging host', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final backend = _MockNetworkBackend();
    when(() => backend.getAllTargets()).thenAnswer(
      (_) async => [
        {
          'id': 7,
          'name': 'North America Nebula',
          'catalogId': 'NGC 7000',
          'ra': 20.98,
          'dec': 44.33,
        },
      ],
    );
    when(() => backend.getSessionsForTarget(7)).thenAnswer((_) async => []);
    when(() => backend.getImagesForTarget(7)).thenAnswer((_) async => []);
    when(
      () => backend.getIntegrationGoals(targetId: 7),
    ).thenAnswer((_) async => []);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final single = await container.read(campaignRollupProvider(7).future);
    final all = await container.read(campaignRollupAllTargetsProvider.future);

    expect(single.targetId, 7);
    expect(single.targetName, 'North America Nebula');
    expect(all.keys, [7]);
    expect(all[7]!.targetName, 'North America Nebula');
    expect(await db.targetsDao.getAllTargets(), isEmpty);
    verify(() => backend.getAllTargets()).called(1);
    verify(() => backend.getSessionsForTarget(7)).called(2);
    verify(() => backend.getImagesForTarget(7)).called(2);
    verify(() => backend.getIntegrationGoals(targetId: 7)).called(2);
  });
}
