import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import '../harness/in_memory_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'equipment profiles remain loading until both database streams resolve',
    () async {
      final profiles = Completer<List<db.EquipmentProfile>>();
      final active = Completer<db.EquipmentProfile?>();
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          allProfilesProvider.overrideWith(
            (_) => Stream.fromFuture(profiles.future),
          ),
          activeProfileProvider.overrideWith(
            (_) => Stream.fromFuture(active.future),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.listen(
        equipmentProfilesProvider,
        (_, __) {},
        fireImmediately: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(equipmentProfilesProvider).isLoading, isTrue);

      profiles.complete(const []);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(equipmentProfilesProvider).isLoading, isTrue);

      active.complete(null);
      final state = await container.read(equipmentProfilesProvider.future);
      expect(state.profiles, isEmpty);
    },
  );

  test(
    'database profile stream failures propagate as provider errors',
    () async {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          allProfilesProvider.overrideWith(
            (_) => Stream<List<db.EquipmentProfile>>.error(
              StateError('profile database unavailable'),
            ),
          ),
          activeProfileProvider.overrideWith((_) => Stream.value(null)),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(equipmentProfilesProvider.future),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('profile database unavailable'),
          ),
        ),
      );
      expect(container.read(equipmentProfilesProvider).hasError, isTrue);
    },
  );
}
