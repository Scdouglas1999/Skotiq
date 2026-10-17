import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'disconnected UI-only weather state never requests rig-safing',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(weatherSafetyProvider);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(backendProvider), isA<DisconnectedBackend>());
      expect(state.status, WeatherSafetyStatus.unsafe);
      expect(state.dataSource, SafetyDataSource.unavailable);
      expect(state.actions.shouldPause, isFalse);
      expect(state.actions.shouldPark, isFalse);
      expect(state.actions.shouldCloseDome, isFalse);
      expect(state.failModeWarning, contains('Connect to an imaging host'));
      expect(container.read(uiNotificationProvider), isEmpty);
    },
  );
}
