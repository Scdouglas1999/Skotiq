import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart'
    as device_types;
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/equipment/camera_state_provider.dart';
import 'package:skotiq_core/src/providers/imaging_provider.dart';
import 'package:skotiq_core/src/services/camera_temperature_poller.dart';

import '../mocks/mock_backend.dart';

/// Builds a fully-populated [CameraStatus] varying only the cooling-relevant
/// telemetry under test. Everything else mirrors a typical cooled camera so
/// the poller exercises the same code path it would in production.
CameraStatus _coolingStatus({
  double? sensorTemp,
  double? targetTemp,
  double? coolerPower,
  bool? coolerOn,
}) {
  return CameraStatus(
    connected: true,
    state: device_types.CameraState.idle,
    sensorTemp: sensorTemp,
    coolerPower: coolerPower,
    targetTemp: targetTemp,
    coolerOn: coolerOn ?? (coolerPower ?? 0.0) > 0.0,
    gain: 100,
    offset: 50,
    binX: 1,
    binY: 1,
    sensorWidth: 4656,
    sensorHeight: 3520,
    pixelSizeX: 3.76,
    pixelSizeY: 3.76,
    maxAdu: 65535,
    canCool: true,
    canSetGain: true,
    canSetOffset: true,
  );
}

void main() {
  const deviceId = TestFixtures.cameraId;

  late MockBackend mockBackend;
  late ProviderContainer container;
  late CameraTemperaturePoller poller;

  setUpAll(registerMocktailFallbackValues);

  setUp(() {
    mockBackend = MockBackend();
    container = ProviderContainer();
    poller = CameraTemperaturePoller(
      ref: container.read(_refProbeProvider),
      backend: mockBackend,
      // Long interval: each test drives a single immediate poll on start().
      interval: const Duration(hours: 1),
    );
  });

  tearDown(() {
    poller.dispose();
    container.dispose();
  });

  /// Stubs the backend to return [status], starts the poller, and waits for
  /// the immediate-on-start poll to complete and publish to providers.
  Future<void> pollOnce(CameraStatus status) async {
    when(
      () => mockBackend.getCameraStatus(deviceId),
    ).thenAnswer((_) async => status);
    poller.start(deviceId);
    // Let the awaited getCameraStatus future and subsequent provider writes
    // settle. Two zero-delay turns covers the async gap in _poll.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'publishes a cooling snapshot at-target when within tolerance',
    () async {
      await pollOnce(
        _coolingStatus(sensorTemp: -9.7, targetTemp: -10.0, coolerPower: 42.0),
      );

      final cooling = container.read(coolingStatusProvider);
      expect(cooling.isCooling, isTrue);
      expect(cooling.isAtTarget, isTrue);
      expect(cooling.coolerPower, 42.0);
      expect(cooling.currentTemp, -9.7);
      expect(cooling.targetTemp, -10.0);
    },
  );

  test('cooling but not at-target when reading is outside tolerance', () async {
    await pollOnce(
      _coolingStatus(sensorTemp: 5.0, targetTemp: -10.0, coolerPower: 95.0),
    );

    final cooling = container.read(coolingStatusProvider);
    expect(cooling.isCooling, isTrue);
    expect(cooling.isAtTarget, isFalse);
    expect(cooling.coolerPower, 95.0);
  });

  test('cooler power of zero reports not cooling and not at-target', () async {
    await pollOnce(
      _coolingStatus(sensorTemp: -10.0, targetTemp: -10.0, coolerPower: 0.0),
    );

    final cooling = container.read(coolingStatusProvider);
    expect(cooling.isCooling, isFalse);
    expect(cooling.isAtTarget, isFalse);
    expect(cooling.coolerPower, 0.0);
  });

  test('authoritative cooler-on remains cooling at zero duty cycle', () async {
    await pollOnce(
      _coolingStatus(
        sensorTemp: -10.0,
        targetTemp: -10.0,
        coolerPower: 0.0,
        coolerOn: true,
      ),
    );

    final cooling = container.read(coolingStatusProvider);
    expect(cooling.isCooling, isTrue);
    expect(cooling.isAtTarget, isTrue);
  });

  test(
    'missing power does not turn off an authoritative active cooler',
    () async {
      await pollOnce(
        _coolingStatus(
          sensorTemp: -10.0,
          targetTemp: null,
          coolerPower: null,
          coolerOn: true,
        ),
      );

      final cooling = container.read(coolingStatusProvider);
      expect(cooling.isCooling, isTrue);
      expect(cooling.isAtTarget, isTrue);
      expect(container.read(cameraStateProvider).coolerPower, isNull);
    },
  );

  test('null sensor temperature leaves cooling status untouched', () async {
    // Pre-seed a known cooling snapshot, then poll with no live reading.
    container.read(coolingStatusProvider.notifier).state = const CoolingStatus(
      currentTemp: -10.0,
      targetTemp: -10.0,
      coolerPower: 50.0,
      isCooling: true,
      isAtTarget: true,
    );

    await pollOnce(
      _coolingStatus(sensorTemp: null, targetTemp: -10.0, coolerPower: 50.0),
    );

    // With no live temperature the poller must not fabricate a fresh state;
    // the previously-published snapshot is preserved untouched.
    final cooling = container.read(coolingStatusProvider);
    expect(cooling.isCooling, isTrue);
    expect(cooling.isAtTarget, isTrue);
    expect(cooling.coolerPower, 50.0);
  });
}

/// Exposes the container's [Ref] to construct the poller, which requires a
/// [Ref] for provider reads/writes. A plain `Provider` that returns its own
/// `ref` is the canonical way to obtain one in a test.
final _refProbeProvider = Provider<Ref>((ref) => ref);
