/// A guider that DIED keeps its reason.
///
/// The built-in guider's task can fail asynchronously ("Calibration star match
/// failed"). That path emits a guiding `Disconnected` event, which lands in
/// `setDisconnected()`; rebuilding the state object from scratch there wipes
/// the `lastError` the accompanying device-error event just set, leaving the
/// imaging Guiding panel with nothing and falling back to "No guider
/// connected" — pointing the operator at cables for a calibration problem.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';

void main() {
  group('GuiderStateNotifier error retention', () {
    late ProviderContainer container;

    setUp(() => container = ProviderContainer());
    tearDown(() => container.dispose());

    test('setDisconnected keeps lastError so the UI can name the failure', () {
      final notifier = container.read(guiderStateProvider.notifier);
      notifier.setConnecting('native:builtin_guider:multi_star');
      notifier.setConnected();
      notifier.setError(Exception('Guiding stopped: calibration failed'));

      expect(container.read(guiderStateProvider).lastError, isNotNull);

      notifier.setDisconnected();

      final state = container.read(guiderStateProvider);
      expect(
        state.connectionState,
        DeviceConnectionState.disconnected,
        reason: 'still a disconnect',
      );
      expect(
        state.lastError,
        isNotNull,
        reason: 'the reason must survive the disconnect that follows a failure',
      );
      expect(state.lastError!.message, contains('calibration failed'));
    });

    test('a clean reconnect clears the stale error', () {
      final notifier = container.read(guiderStateProvider.notifier);
      notifier.setError(Exception('old failure'));
      notifier.setDisconnected();
      expect(container.read(guiderStateProvider).lastError, isNotNull);

      notifier.setConnecting('native:builtin_guider:multi_star');
      notifier.setConnected();

      expect(container.read(guiderStateProvider).lastError, isNull);
    });
  });
}
