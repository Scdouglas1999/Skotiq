import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

class _SeededCameraNotifier extends CameraStateNotifier {
  _SeededCameraNotifier(super.ref, CameraStateSnapshot initial) : super() {
    state = initial;
  }
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// The rig's camera: an ASI1600MM-Cool at driver gain 76, whose driver
/// reports a 65520 full scale while its frames top out at 65504. Its
/// conversion gain measured from 28 twilight-flat pairs is 0.1231 e⁻/ADU.
const _rigCamera = 'ASI1600MM-Cool';
const _rigGain = 76;
const _rigMaxAdu = 65520;
const _measuredEPerAdu = 0.1231;
const _realMaxPixel = 65504;

CameraSensorEntry get _asi1600 =>
    CameraSensorDatabase.curated.lookup(_rigCamera)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveScienceCameraValues', () {
    test('the ASI1600 at gain 76 gets its gain-76 e-/ADU, not the gain-0 '
        'full-well conversion', () {
      final values = resolveScienceCameraValues(
        cameraName: _rigCamera,
        driverGain: _rigGain,
        maxAdu: _rigMaxAdu,
        adcBitDepth: 12,
        entry: _asi1600,
      );
      // Within 6% of the flat-pair measurement; full well / full scale
      // (20000 / 65535 = 0.305) is 2.5x off.
      expect(values.electronsPerAdu, closeTo(_measuredEPerAdu, 0.0074));
      // Between the chart's gain-0 (3.6 e-) and unity-gain (1.7 e-) figures,
      // not the gain-300 1.2 e-.
      expect(values.readNoiseE, inInclusiveRange(1.9, 2.4));
      expect(values.source, contains('interpolated from the published'));
    });

    test('saturation sits below the highest value the sensor produces', () {
      final values = resolveScienceCameraValues(
        cameraName: _rigCamera,
        driverGain: _rigGain,
        maxAdu: _rigMaxAdu,
        adcBitDepth: 12,
        entry: _asi1600,
      );
      expect(values.saturationAdu, lessThan(_realMaxPixel));
      expect(values.saturationAdu, greaterThan(_realMaxPixel - 64));
    });

    test('a flat-pair measurement at the gain in use wins over the chart', () {
      const measurement = ScienceGainMeasurement(
        cameraName: _rigCamera,
        driverGain: _rigGain,
        electronsPerAdu: _measuredEPerAdu,
        pairCount: 28,
      );
      final values = resolveScienceCameraValues(
        cameraName: _rigCamera,
        driverGain: _rigGain,
        maxAdu: _rigMaxAdu,
        adcBitDepth: 12,
        entry: _asi1600,
        measurement: measurement,
      );
      expect(values.electronsPerAdu, _measuredEPerAdu);
      expect(values.source, contains('measured from 28 flat pairs'));

      final otherGain = resolveScienceCameraValues(
        cameraName: _rigCamera,
        driverGain: 139,
        maxAdu: _rigMaxAdu,
        adcBitDepth: 12,
        entry: _asi1600,
        measurement: measurement,
      );
      // Unity gain on the chart: 1.0 e- per 12-bit count, 1/16 per container
      // count.
      expect(otherGain.electronsPerAdu, closeTo(1.0 * 4095 / 65520, 1e-6));
    });

    test('a camera with no gain chart keeps the configured values', () {
      final values = resolveScienceCameraValues(
        cameraName: 'Mystery Cam',
        driverGain: 100,
        maxAdu: 65535,
        adcBitDepth: 16,
        entry: null,
      );
      expect(values.electronsPerAdu, isNull);
      expect(values.readNoiseE, isNull);
      expect(values.source, contains('no published gain chart'));
      expect(values.saturationAdu, 65533);
    });

    test('a read-noise figure quoted at another gain is not used', () {
      final asi6200 = CameraSensorDatabase.curated.lookup('ASI6200MM Pro')!;
      final values = resolveScienceCameraValues(
        cameraName: 'ASI6200MM Pro',
        driverGain: 0,
        maxAdu: 65535,
        adcBitDepth: 16,
        entry: asi6200,
      );
      expect(values.readNoiseE, isNull);
      expect(values.source, contains('no published figure at gain 0'));
    });
  });

  for (final stateGain in <int?>[76, null]) {
    test(
      'auto-config resolves gain 76 when camera state gain is $stateGain',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        await SettingsDao(database).setSettings({
          ScienceCameraAutoConfig.gainKey: '0.0625',
          ScienceCameraAutoConfig.readNoiseKey: '1.70',
        });
        final backend = _MockBackend();
        when(() => backend.getCameraStatus('asi')).thenAnswer(
          (_) async => CameraStatus.fromJson({
            'connected': true,
            'gain': 76,
            'canSetGain': true,
            'maxAdu': _rigMaxAdu,
          }),
        );
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            loggingServiceProvider.overrideWithValue(LoggingService()),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            cameraStateProvider.overrideWith(
              (ref) => _SeededCameraNotifier(
                ref,
                CameraStateSnapshot(
                  connectionState: DeviceConnectionState.connected,
                  deviceId: 'asi',
                  deviceName: _rigCamera,
                  gain: stateGain,
                ),
              ),
            ),
            cameraCapabilitiesProvider.overrideWith(
              (ref, deviceId) async => const CameraCapabilities(
                maxWidth: 4656,
                maxHeight: 3520,
                bitDepth: 12,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final service = container.read(scienceCameraAutoConfigProvider);
        // Let the provider's own startup pass run first so it cannot retire ours.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await service.maybeSync(reason: 'test', force: true);

        final settings = await SettingsDao(database).getAllSettings();
        final gain = double.parse(settings[ScienceCameraAutoConfig.gainKey]!);
        expect(gain, closeTo(_measuredEPerAdu, 0.0074));
        expect(
          int.parse(settings[ScienceCameraAutoConfig.saturationKey]!),
          lessThan(_realMaxPixel),
        );
        expect(
          double.parse(settings[ScienceCameraAutoConfig.readNoiseKey]!),
          inInclusiveRange(1.9, 2.4),
        );
        expect(
          settings[ScienceCameraAutoConfig.autoSourceKey],
          contains('at gain 76'),
        );
      },
    );
  }
}
