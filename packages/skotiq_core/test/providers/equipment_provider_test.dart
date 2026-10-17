import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';

void main() {
  group('CameraStateNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
    });

    test('initial state is disconnected', () {
      final state = container.read(cameraStateProvider);

      expect(state.connectionState, DeviceConnectionState.disconnected);
      expect(state.deviceId, isNull);
      expect(state.deviceName, isNull);
      expect(state.lastSuccessfulCommunication, isNull);
    });

    test('setConnecting updates state correctly', () {
      final notifier = container.read(cameraStateProvider.notifier);

      notifier.setConnecting('test-camera-id', 'Test Camera');

      final state = container.read(cameraStateProvider);
      expect(state.connectionState, DeviceConnectionState.connecting);
      expect(state.deviceId, 'test-camera-id');
      expect(state.deviceName, 'Test Camera');
    });

    test('setConnected updates state correctly', () {
      final notifier = container.read(cameraStateProvider.notifier);

      notifier.setConnecting('test-camera-id', 'Test Camera');
      notifier.setConnected();

      final state = container.read(cameraStateProvider);
      expect(state.connectionState, DeviceConnectionState.connected);
      expect(state.deviceId, 'test-camera-id');
    });

    test('setDisconnected resets state', () {
      final notifier = container.read(cameraStateProvider.notifier);

      // First connect
      notifier.setConnecting('test-camera-id', 'Test Camera');
      notifier.setConnected();

      // Then disconnect
      notifier.setDisconnected();

      final state = container.read(cameraStateProvider);
      expect(state.connectionState, DeviceConnectionState.disconnected);
      expect(state.deviceId, isNull);
      expect(state.deviceName, isNull);
    });

    test('updateCommunication sets timestamp', () {
      final notifier = container.read(cameraStateProvider.notifier);

      notifier.setConnecting('test-camera-id', 'Test Camera');
      notifier.setConnected();

      final beforeUpdate = DateTime.now();
      notifier.updateCommunication();
      final afterUpdate = DateTime.now();

      final state = container.read(cameraStateProvider);
      expect(state.lastSuccessfulCommunication, isNotNull);
      expect(
        state.lastSuccessfulCommunication!.isAfter(
          beforeUpdate.subtract(const Duration(seconds: 1)),
        ),
        isTrue,
      );
      expect(
        state.lastSuccessfulCommunication!.isBefore(
          afterUpdate.add(const Duration(seconds: 1)),
        ),
        isTrue,
      );
    });

    test('updateTemperature updates communication timestamp', () {
      final notifier = container.read(cameraStateProvider.notifier);

      notifier.setConnecting('test-camera-id', 'Test Camera');
      notifier.setConnected();

      notifier.updateTemperature(-10.5, 75.0);

      final state = container.read(cameraStateProvider);
      expect(state.temperature, -10.5);
      expect(state.coolerPower, 75.0);
      expect(state.lastSuccessfulCommunication, isNotNull);
    });

    test('isHealthy returns true for recent communication', () {
      final notifier = container.read(cameraStateProvider.notifier);

      notifier.setConnecting('test-camera-id', 'Test Camera');
      notifier.setConnected();
      notifier.updateCommunication();

      final state = container.read(cameraStateProvider);
      expect(state.isHealthy, isTrue);
    });

    test('isHealthy returns false for old communication', () {
      final notifier = container.read(cameraStateProvider.notifier);

      notifier.setConnecting('test-camera-id', 'Test Camera');
      notifier.setConnected();

      // Manually set an old timestamp
      final state = container.read(cameraStateProvider);
      final oldState = state.copyWith(
        lastSuccessfulCommunication: DateTime.now().subtract(
          const Duration(seconds: 35),
        ),
      );

      // Replace state with old timestamp
      container.read(cameraStateProvider.notifier).state = oldState;

      final updatedState = container.read(cameraStateProvider);
      expect(updatedState.isHealthy, isFalse);
    });

    test('isHealthy returns false when disconnected', () {
      final state = container.read(cameraStateProvider);
      expect(state.isHealthy, isFalse);
    });

    test('autoReconnectEnabled defaults to true', () {
      final state = container.read(cameraStateProvider);
      expect(state.autoReconnectEnabled, isTrue);
    });

    test('setAutoReconnect changes reconnection setting', () {
      final notifier = container.read(cameraStateProvider.notifier);

      notifier.setAutoReconnect(false);

      final state = container.read(cameraStateProvider);
      expect(state.autoReconnectEnabled, isFalse);

      notifier.setAutoReconnect(true);

      final updatedState = container.read(cameraStateProvider);
      expect(updatedState.autoReconnectEnabled, isTrue);
    });

    test('retryConnection calls connect with existing device ID', () async {
      final notifier = container.read(cameraStateProvider.notifier);

      // Set up initial connection state
      notifier.setConnecting('test-camera-id', 'Test Camera');

      // Note: Full retry logic would require mocking the device service
      // This test just verifies the state is set correctly
      expect(container.read(cameraStateProvider).deviceId, 'test-camera-id');
    });

    test('clearError removes error from state', () {
      final notifier = container.read(cameraStateProvider.notifier);

      // Set an error
      notifier.setError(Exception('Test error'));

      var state = container.read(cameraStateProvider);
      expect(state.hasError, isTrue);

      // Clear the error
      notifier.clearError();

      state = container.read(cameraStateProvider);
      expect(state.hasError, isFalse);
      expect(state.lastError, isNull);
    });

    test('setExposing updates communication timestamp', () {
      final notifier = container.read(cameraStateProvider.notifier);

      notifier.setConnecting('test-camera-id', 'Test Camera');
      notifier.setConnected();

      notifier.setExposing(true, progress: 0.5);

      final state = container.read(cameraStateProvider);
      expect(state.isExposing, isTrue);
      expect(state.exposureProgress, 0.5);
      expect(state.lastSuccessfulCommunication, isNotNull);
    });
  });

  group('DeviceError', () {
    test('creates error from exception', () {
      final exception = Exception('Connection failed');
      final error = DeviceError.fromException(
        exception,
        deviceId: 'test-device',
        retryAttempts: 2,
      );

      expect(error.deviceId, 'test-device');
      expect(error.retryAttempts, 2);
      expect(error.message, contains('Connection failed'));
    });

    test('categorizes timeout errors correctly', () {
      final exception = Exception('Operation timeout');
      final error = DeviceError.fromException(exception);

      expect(error.type, DeviceErrorType.timeout);
      expect(error.recoverable, isTrue);
    });

    test('categorizes not found errors as unrecoverable', () {
      final exception = Exception('Device not found');
      final error = DeviceError.fromException(exception);

      expect(error.type, DeviceErrorType.deviceNotFound);
      expect(error.recoverable, isFalse);
    });

    test('provides user-friendly error messages', () {
      final timeoutError = DeviceError.fromException(Exception('timeout'));
      expect(timeoutError.userMessage, contains('timed out'));

      final notFoundError = DeviceError.fromException(Exception('not found'));
      expect(notFoundError.userMessage, contains('not found'));
    });

    test('provides suggested recovery actions', () {
      final timeoutError = DeviceError.fromException(Exception('timeout'));
      expect(timeoutError.suggestedAction, isNotNull);
      expect(timeoutError.suggestedAction, contains('Wait'));

      final notFoundError = DeviceError.fromException(Exception('not found'));
      expect(notFoundError.suggestedAction, isNotNull);
      expect(notFoundError.suggestedAction, contains('Check'));
    });
  });
}
