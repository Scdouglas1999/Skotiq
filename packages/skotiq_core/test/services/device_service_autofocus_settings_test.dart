import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/device_service.dart';

void main() {
  test(
    'autofocus applies active-filter overrides and restores designated filter',
    () async {
      final backend = _AutofocusCaptureBackend();
      final settings = AppSettingsState(
        useFilterFocusOffsets: false,
        afExposureTime: 4,
        afBinning: 1,
        afAutofocusFilterName: 'L',
        afFilterSettingsJson: AutofocusSettings.encodeFilterSettingsJson({
          'R': const FilterAutofocusConfig(
            afExposureTime: 7.5,
            afFilterName: 'L',
            binning: 2,
            gain: 110,
            offset: 25,
          ),
        }),
      );
      final container = _buildContainer(backend, settings);
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      _seedConnectedEquipment(container);

      final result = await container
          .read(deviceServiceProvider)
          .runAutofocus(exposureTime: 1, stepSize: 1, stepsOut: 1);

      expect(result.bestPosition, 12345);
      expect(backend.events, ['filter:0', 'autofocus', 'filter:1']);
      expect(backend.exposureTime, 7.5);
      expect(backend.binning, 2);
      expect(backend.gain, 110);
      expect(backend.offset, 25);
      expect(container.read(filterWheelStateProvider).currentFilterName, 'R');
    },
  );

  test(
    'missing configured autofocus filter fails before hardware starts',
    () async {
      final backend = _AutofocusCaptureBackend();
      final container = _buildContainer(
        backend,
        const AppSettingsState(
          useFilterFocusOffsets: false,
          afAutofocusFilterName: 'Missing',
        ),
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      _seedConnectedEquipment(container);

      await expectLater(
        container
            .read(deviceServiceProvider)
            .runAutofocus(exposureTime: 1, stepSize: 1, stepsOut: 1),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('not present in the connected wheel'),
          ),
        ),
      );
      expect(backend.events, isEmpty);
    },
  );

  test(
    'manual panel values override basics but retain advanced settings',
    () async {
      final backend = _AutofocusCaptureBackend();
      final container = _buildContainer(
        backend,
        AppSettingsState(
          useFilterFocusOffsets: false,
          afCurveFitting: 'Parabolic',
          afNumberOfAttempts: 3,
          afFilterSettingsJson: AutofocusSettings.encodeFilterSettingsJson({
            'R': const FilterAutofocusConfig(gain: 90, offset: 12),
          }),
        ),
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      _seedConnectedEquipment(container);

      await container
          .read(deviceServiceProvider)
          .runAutofocus(
            exposureTime: 2.5,
            stepSize: 77,
            stepsOut: 6,
            method: 'Star HFR',
            binning: 4,
            useSettingsDefaults: false,
          );

      expect(backend.exposureTime, 2.5);
      expect(backend.stepSize, 77);
      expect(backend.binning, 4);
      expect(backend.curveFitting, 'Parabolic');
      expect(backend.numberOfAttempts, 3);
      expect(backend.gain, 90);
      expect(backend.offset, 12);
    },
  );

  test('moving filter-wheel sentinel has no current filter name', () {
    const state = FilterWheelState(
      currentPosition: -1,
      filterNames: ['L', 'R'],
    );
    expect(state.currentFilterName, isNull);
  });
}

ProviderContainer _buildContainer(
  SkotiqBackend backend,
  AppSettingsState settings,
) {
  return ProviderContainer(
    overrides: [
      backendProvider.overrideWith((ref) => _TestBackendNotifier(ref, backend)),
      appSettingsProvider.overrideWith(() => _FixedSettingsNotifier(settings)),
      activeEquipmentProfileProvider.overrideWithValue(null),
    ],
  );
}

void _seedConnectedEquipment(ProviderContainer container) {
  container
      .read(cameraStateProvider.notifier)
      .setConnecting('camera-1', 'Camera');
  container.read(cameraStateProvider.notifier).setConnected();

  container
      .read(focuserStateProvider.notifier)
      .setConnecting('focuser-1', 'Focuser');
  container.read(focuserStateProvider.notifier).setConnected();
  container.read(focuserStateProvider.notifier).updatePosition(12000);

  container
      .read(filterWheelStateProvider.notifier)
      .setConnecting('wheel-1', 'Wheel');
  container
      .read(filterWheelStateProvider.notifier)
      .setConnected(filterNames: ['L', 'R']);
  container.read(filterWheelStateProvider.notifier).updatePosition(1);
}

class _FixedSettingsNotifier extends AppSettingsNotifier {
  _FixedSettingsNotifier(this.settings);

  final AppSettingsState settings;

  @override
  Future<AppSettingsState> build() async => settings;
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _AutofocusCaptureBackend extends DisconnectedBackend {
  final List<String> events = [];
  int filterPosition = 1;
  double? exposureTime;
  int? stepSize;
  int? binning;
  int? gain;
  int? offset;
  String? curveFitting;
  int? numberOfAttempts;

  @override
  Future<void> filterWheelSetPosition(String deviceId, int position) async {
    events.add('filter:$position');
    filterPosition = position;
  }

  @override
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async {
    return FilterWheelStatus(
      connected: true,
      position: filterPosition,
      moving: false,
      filterCount: 2,
      filterNames: const ['L', 'R'],
    );
  }

  @override
  Future<AutofocusResult> autofocusStart({
    required String deviceId,
    required String cameraId,
    required double exposureTime,
    required int stepSize,
    required int stepsOut,
    String method = 'VCurve',
    int binning = 1,
    int? gain,
    int? offset,
    String curveFitting = 'Hyperbolic',
    int numberOfAttempts = 1,
    int exposuresPerPoint = 1,
    double rSquaredThreshold = 0.7,
    double outerCropRatio = 1.0,
    double innerCropRatio = 0.0,
    int useBrightestNStars = 0,
    int focuserSettleTimeMs = 500,
    String backlashCompMethod = 'Overshoot',
    int backlashIn = 350,
    int backlashOut = 0,
    int? measuredBacklashIn,
  }) async {
    events.add('autofocus');
    this.exposureTime = exposureTime;
    this.stepSize = stepSize;
    this.binning = binning;
    this.gain = gain;
    this.offset = offset;
    this.curveFitting = curveFitting;
    this.numberOfAttempts = numberOfAttempts;
    return const AutofocusResult(
      bestPosition: 12345,
      bestHfr: 1.8,
      focusData: [],
      method: 'Hyperbolic',
      timestamp: 1,
      curveFitQuality: 0.95,
      backlashApplied: true,
    );
  }
}
