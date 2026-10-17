/// SCI-40: pre-flight demanded darks at the cooling SETPOINT for a camera with
/// no cooler.
///
/// The simulated (and any uncooled) camera sits at ambient and reports it
/// everywhere in the app; the profile's -10 C setpoint is a number nothing will
/// ever honour. Darks captured to satisfy that requirement could never match a
/// light frame, so the warning sent the operator off to spend an hour producing
/// calibration data that was useless by construction.
library;

import 'package:drift/drift.dart' show QueryExecutor, Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/dark_library_dao.dart';
import 'package:skotiq_core/src/database/database.dart'
    hide Sequence, SequenceNode;
import 'package:skotiq_core/src/models/backend/device_capabilities.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/capability_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment/camera_state_provider.dart';
import 'package:skotiq_core/src/providers/sequence/rules/preflight_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

class _StubCamera extends CameraStateNotifier {
  _StubCamera(super.ref, CameraStateSnapshot initial) {
    state = initial;
  }
}

class _FakeAppSettings extends AppSettingsNotifier {
  _FakeAppSettings(this._initial);
  final AppSettingsState _initial;
  @override
  Future<AppSettingsState> build() async => _initial;
}

T _withRef<T>(ProviderContainer c, T Function(Ref ref) body) =>
    c.read(Provider<T>((ref) => body(ref)));

const _deviceId = 'sim-camera-1';

CameraCapabilities _capabilities({required bool canSetCcdTemperature}) =>
    CameraCapabilities(
      maxWidth: 100,
      maxHeight: 100,
      bitDepth: 16,
      canSetCcdTemperature: canSetCcdTemperature,
    );

Future<ProviderContainer> _container({
  required bool canSetCcdTemperature,
  double? darkTemperature,
}) async {
  final QueryExecutor exec = NativeDatabase.memory();
  final db = SkotiqDatabase.forTesting(exec);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      appSettingsProvider.overrideWith(
        () => _FakeAppSettings(
          const AppSettingsState(
            defaultGain: 100,
            defaultOffset: 10,
            darkLibraryMinCoverage: 10,
          ),
        ),
      ),
      cameraStateProvider.overrideWith(
        (ref) => _StubCamera(
          ref,
          const CameraStateSnapshot(
            connectionState: DeviceConnectionState.connected,
            deviceId: _deviceId,
            // The uncooled rig from the report: sitting at +20 C with the
            // profile's -10 C setpoint still on the state object.
            targetTemp: -10.0,
            temperature: 20.0,
          ),
        ),
      ),
      cameraCapabilitiesProvider(_deviceId).overrideWith(
        (ref) async =>
            _capabilities(canSetCcdTemperature: canSetCcdTemperature),
      ),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });
  await container.read(appSettingsProvider.future);
  if (darkTemperature != null) {
    await DarkLibraryDao(db).addEntry(
      DarkLibraryCompanion.insert(
        filePath: '/tmp/master_dark.fits',
        exposureTime: 180,
        frameType: const Value('dark'),
        temperature: Value(darkTemperature),
        gain: const Value(100),
        offset: const Value(10),
        binX: const Value(1),
        binY: const Value(1),
        width: const Value(100),
        height: const Value(100),
        masterDarkPath: const Value('/tmp/master_dark.fits'),
        masterFrameCount: const Value(10),
      ),
    );
  }
  return container;
}

Sequence _lightSequence() {
  final exposure = ExposureNode(
    durationSecs: 180,
    count: 5,
    gain: 100,
    offset: 10,
  );
  final root = InstructionSetNode(name: 'Root', childIds: [exposure.id]);
  return Sequence.create(
    name: 'T',
    nodes: {
      root.id: root,
      exposure.id: exposure.copyWith(parentId: root.id),
    },
    rootNodeId: root.id,
  );
}

void main() {
  final rule = DarkLibraryCoverageRule();

  test(
    'an uncooled camera is checked against its real sensor temperature',
    () async {
      final container = await _container(
        canSetCcdTemperature: false,
        darkTemperature: 20.0,
      );
      final issues = await _withRef(
        container,
        (ref) => rule.validate(_lightSequence(), ValidationContext(ref)),
      );
      expect(
        issues,
        isEmpty,
        reason:
            'the master dark at the sensor temperature the lights are taken at '
            'IS the matching dark',
      );
    },
  );

  test(
    'the missing-dark line quotes the sensor temperature, not the setpoint',
    () async {
      final container = await _container(canSetCcdTemperature: false);
      final issues = await _withRef(
        container,
        (ref) => rule.validate(_lightSequence(), ValidationContext(ref)),
      );
      expect(issues, isNotEmpty);
      expect(issues.first.description, contains('temp=20.0C'));
      expect(issues.first.description, isNot(contains('temp=-10.0C')));
      expect(issues.first.description, contains('no cooler'));
    },
  );

  // The hint must name a destination that exists. The primary navigation is
  // Dashboard / Equipment / Imaging / Sequencer / Guiding / Weather /
  // Plan Tonight / Analytics — there is no "Calibration" entry, and the dark
  // library lives at Settings > Equipment > Dark Library.
  test('the missing-dark hint names a destination that exists', () async {
    final container = await _container(canSetCcdTemperature: false);
    final issues = await _withRef(
      container,
      (ref) => rule.validate(_lightSequence(), ValidationContext(ref)),
    );
    expect(issues, isNotEmpty);
    for (final issue in issues) {
      final hint = issue.resolutionHint ?? '';
      expect(
        hint,
        isNot(contains('Calibration →')),
        reason: 'there is no Calibration screen to open',
      );
      if (hint.contains('Dark Library')) {
        expect(hint, contains('Settings →'));
      }
    }
  });

  test('a cooled camera still uses its setpoint', () async {
    final container = await _container(
      canSetCcdTemperature: true,
      darkTemperature: -10.0,
    );
    final issues = await _withRef(
      container,
      (ref) => rule.validate(_lightSequence(), ValidationContext(ref)),
    );
    expect(issues, isEmpty);
  });
}
