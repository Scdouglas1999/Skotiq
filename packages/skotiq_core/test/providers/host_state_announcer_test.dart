// A framing target picked on the host is announced to linked clients from
// the framing state, so it is told once whichever path set it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a framing target set on the host is announced to clients once',
    () async {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      final announced = <SkotiqEvent>[];
      container.read(hostMutationEventHubProvider).wsBroadcast = announced.add;
      container.read(hostStateAnnouncerProvider);

      container
          .read(framingProvider.notifier)
          .setTargetCoordinates(5.5880, -5.3911, name: 'M42');
      // A change that keeps the target (rotation) is not announced.
      container.read(framingProvider.notifier).setRotation(30);
      await Future<void>.delayed(Duration.zero);

      final event = announced.single;
      expect(event.data['entityType'], HostMutationEntity.framing);
      expect(event.data['action'], HostMutationAction.updated);
      expect(event.data['name'], 'M42');
      expect(event.data['ra'], closeTo(5.5880, 1e-9));
      expect(event.data['dec'], closeTo(-5.3911, 1e-9));
    },
  );
}
