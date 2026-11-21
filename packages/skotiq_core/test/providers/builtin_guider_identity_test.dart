import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/providers/remote_sync_handler.dart';

void main() {
  test(
    'a guiding Connected event does not rename a built-in guider to PHD2',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(guiderStateProvider.notifier)
          .setConnecting(
            'native:builtin_guider:multi_star',
            'Built-in Multi-Star Guider',
          );
      container.read(guiderStateProvider.notifier).setConnected();

      for (final type in ['Connected', 'GuidingStarted', 'GuidingStopped']) {
        applyHostLocalSyncEvent(
          container,
          SkotiqEvent(
            timestamp: 0,
            severity: EventSeverity.info,
            category: EventCategory.guiding,
            eventType: type,
            data: const {},
          ),
        );
      }

      final state = container.read(guiderStateProvider);
      expect(state.deviceId, 'native:builtin_guider:multi_star');
      expect(state.deviceName, 'Built-in Multi-Star Guider');
    },
  );

  test('a guider host mutation does not rename a built-in guider to PHD2', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(guiderStateProvider.notifier)
        .setConnecting(
          'native:builtin_guider:multi_star',
          'Built-in Multi-Star Guider',
        );
    container.read(guiderStateProvider.notifier).setConnected();

    applyHostLocalSyncEvent(
      container,
      buildHostMutationEvent(
        entityType: HostMutationEntity.guider,
        action: HostMutationAction.connected,
      ),
    );

    expect(
      container.read(guiderStateProvider).deviceId,
      'native:builtin_guider:multi_star',
    );
  });

  test('a guiding Connected event with an empty slot becomes PHD2', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    applyHostLocalSyncEvent(
      container,
      const SkotiqEvent(
        timestamp: 0,
        severity: EventSeverity.info,
        category: EventCategory.guiding,
        eventType: 'Connected',
        data: {},
      ),
    );

    final state = container.read(guiderStateProvider);
    expect(state.deviceId, 'phd2_guider');
    expect(state.connectionState, DeviceConnectionState.connected);
  });
}
