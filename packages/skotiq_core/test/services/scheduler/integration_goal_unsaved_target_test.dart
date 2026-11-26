import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/services.dart';
import 'package:drift/native.dart';
import 'package:skotiq_core/src/database/database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

// "Image tonight" on a catalog suggestion asked a linked host for the goals of
// target 0 (a suggestion that was never saved has no row id). The host refuses
// an id below 1, so the plan failed with "Value must be >= 1.0" for every
// suggestion on a phone.
SkotiqDatabase _db() => SkotiqDatabase.forTesting(NativeDatabase.memory());

void main() {
  test('an unsaved target has no goals and the host is not asked', () async {
    final remote = _MockNetworkBackend();
    final service = IntegrationGoalService(_db(), remote: remote);

    expect(await service.progressForTarget(0), isEmpty);
    verifyNever(
      () => remote.getIntegrationGoals(targetId: any(named: 'targetId')),
    );
  });

  test('a saved target still asks the host', () async {
    final remote = _MockNetworkBackend();
    when(
      () => remote.getIntegrationGoals(targetId: 7),
    ).thenAnswer((_) async => const []);
    final service = IntegrationGoalService(_db(), remote: remote);

    expect(await service.listForTarget(7), isEmpty);
    verify(() => remote.getIntegrationGoals(targetId: 7)).called(1);
  });
}
