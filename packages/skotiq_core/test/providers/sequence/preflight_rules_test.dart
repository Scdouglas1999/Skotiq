import 'package:drift/drift.dart' show QueryExecutor, Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/dark_library_dao.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/polar_alignment_history_dao.dart';
import 'package:skotiq_core/src/database/daos/targets_dao.dart';
import 'package:skotiq_core/src/database/database.dart'
    hide Sequence, SequenceNode;
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart'
    show FrameType;
import 'package:skotiq_core/src/models/polar_alignment_config.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment/camera_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/filter_wheel_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/focuser_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/guider_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/mount_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/rotator_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment_health_provider.dart';
import 'package:skotiq_core/src/providers/polar_alignment_provider.dart';
import 'package:skotiq_core/src/providers/preflight_providers.dart';
import 'package:skotiq_core/src/providers/sequence/rules/preflight_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/equipment_health_service.dart';
import 'package:skotiq_core/src/services/time_sync_service.dart';

// Test scaffolding.

class _StubCameraNotifier extends CameraStateNotifier {
  _StubCameraNotifier(super.ref, CameraStateSnapshot initial) {
    state = initial;
  }
}

class _StubMountNotifier extends MountStateNotifier {
  _StubMountNotifier(super.ref, MountState initial) {
    state = initial;
  }
}

class _StubFocuserNotifier extends FocuserStateNotifier {
  _StubFocuserNotifier(super.ref, FocuserState initial) {
    state = initial;
  }
}

class _StubFilterWheelNotifier extends FilterWheelStateNotifier {
  _StubFilterWheelNotifier(super.ref, FilterWheelState initial) {
    state = initial;
  }
}

class _StubGuiderNotifier extends GuiderStateNotifier {
  _StubGuiderNotifier(super.ref, GuiderState initial) {
    state = initial;
  }
}

class _StubRotatorNotifier extends RotatorStateNotifier {
  _StubRotatorNotifier(super.ref, RotatorState initial) {
    state = initial;
  }
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;
  @override
  Future<AppSettingsState> build() async => _initial;
}

class _FakeTimeProbe implements TimeSyncProbe {
  _FakeTimeProbe(this._offsetSecs, {this.shouldThrow = false});
  final double _offsetSecs;
  final bool shouldThrow;
  @override
  Future<TimeSyncResult> queryOffset() async {
    if (shouldThrow) throw Exception('network unavailable');
    return TimeSyncResult(
      offsetSeconds: _offsetSecs,
      server: 'test.pool.ntp',
      roundTrip: const Duration(milliseconds: 30),
    );
  }
}

T _withRef<T>(ProviderContainer container, T Function(Ref ref) body) {
  final probe = Provider<T>((ref) => body(ref));
  return container.read(probe);
}

Sequence _sequenceWith(List<SequenceNode> children) {
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{root.id: root};
  final ids = <String>[];
  for (final child in children) {
    final placed = child.copyWith(parentId: root.id);
    nodes[placed.id] = placed;
    ids.add(placed.id);
  }
  nodes[root.id] = root.copyWith(childIds: ids);
  return Sequence.create(name: 'T', nodes: nodes, rootNodeId: root.id);
}

Future<ProviderContainer> _buildContainer({
  required AppSettingsState settings,
  CameraStateSnapshot? camera,
  FocuserState? focuser,
  FilterWheelState? filterWheel,
  List<DeviceHealthSnapshot> deviceHealth = const [],
  OpticalTrainBaseline? baseline,
  OpticalTrainBaseline? current,
  TimeSyncProbe? timeProbe,
  Future<void> Function(SkotiqDatabase db)? seed,
  List<Target>? hostTargets,
  List<CapturedImage>? hostImages,
}) async {
  final QueryExecutor exec = NativeDatabase.memory();
  final db = SkotiqDatabase.forTesting(exec);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      cameraStateProvider.overrideWith(
        (ref) =>
            _StubCameraNotifier(ref, camera ?? const CameraStateSnapshot()),
      ),
      mountStateProvider.overrideWith(
        (ref) => _StubMountNotifier(
          ref,
          const MountState(connectionState: DeviceConnectionState.connected),
        ),
      ),
      focuserStateProvider.overrideWith(
        (ref) => _StubFocuserNotifier(ref, focuser ?? const FocuserState()),
      ),
      filterWheelStateProvider.overrideWith(
        (ref) => _StubFilterWheelNotifier(
          ref,
          filterWheel ?? const FilterWheelState(),
        ),
      ),
      guiderStateProvider.overrideWith(
        (ref) => _StubGuiderNotifier(ref, const GuiderState()),
      ),
      rotatorStateProvider.overrideWith(
        (ref) => _StubRotatorNotifier(ref, const RotatorState()),
      ),
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(settings),
      ),
      deviceHealthSnapshotsProvider.overrideWith((_) => deviceHealth),
      if (baseline != null)
        opticalTrainBaselineProvider.overrideWith((_) => baseline),
      if (current != null)
        opticalTrainCurrentSnapshotProvider.overrideWith((_) => current),
      if (timeProbe != null) timeSyncProbeProvider.overrideWithValue(timeProbe),
      if (hostTargets != null)
        allDbTargetsProvider.overrideWith((ref) => Stream.value(hostTargets)),
      if (hostImages != null)
        allDbImagesProvider.overrideWith((ref) => Stream.value(hostImages)),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });
  await container.read(appSettingsProvider.future);
  if (seed != null) {
    await seed(db);
  }
  return container;
}

Future<void> _insertDark(
  SkotiqDatabase db, {
  required double exposureTime,
  int gain = 100,
  int offset = 10,
  int binX = 1,
  int binY = 1,
  double? temperature,
  String? masterDarkPath,
}) async {
  final dao = DarkLibraryDao(db);
  await dao.addEntry(
    DarkLibraryCompanion.insert(
      filePath:
          '/tmp/dark_${DateTime.now().microsecondsSinceEpoch}_${exposureTime.toInt()}.fits',
      exposureTime: exposureTime,
      frameType: const Value('dark'),
      temperature: Value(temperature),
      gain: Value(gain),
      offset: Value(offset),
      binX: Value(binX),
      binY: Value(binY),
      width: const Value(100),
      height: const Value(100),
      masterDarkPath: Value(masterDarkPath),
      masterFrameCount: Value(masterDarkPath != null ? 10 : null),
    ),
  );
}

Future<int> _insertTarget(
  SkotiqDatabase db, {
  required String name,
  String? catalogId,
  double ra = 10,
  double dec = 40,
}) {
  return TargetsDao(db).createTarget(
    TargetsCompanion.insert(
      name: name,
      catalogId: Value(catalogId),
      ra: ra,
      dec: dec,
    ),
  );
}

Future<void> _insertLightFrame(
  SkotiqDatabase db, {
  required int targetId,
  required bool isAccepted,
  String filter = 'L',
  String? rejectionReason,
}) {
  return ImagesDao(db).createImage(
    CapturedImagesCompanion.insert(
      filePath:
          '/tmp/light_${DateTime.now().microsecondsSinceEpoch}_$targetId.fits',
      fileName: 'light.fits',
      targetId: Value(targetId),
      frameType: const Value('light'),
      exposureDuration: 120,
      filter: Value(filter),
      isAccepted: Value(isAccepted),
      rejectionReason: Value(rejectionReason),
      capturedAt: DateTime.now(),
    ),
  );
}

ExposureNode _exposure({
  double durationSecs = 180,
  int count = 5,
  int gain = 100,
  int offset = 10,
  BinningMode binning = BinningMode.one,
  FrameType frameType = FrameType.light,
}) {
  return ExposureNode(
    durationSecs: durationSecs,
    count: count,
    gain: gain,
    offset: offset,
    binning: binning,
    frameType: frameType,
  );
}

AppSettingsState _settings({
  PreflightStrictness strictness = PreflightStrictness.normal,
  int polarAgeDays = 7,
  int darkMinCoverage = 10,
  double opticalDriftThreshold = 8.0,
}) {
  return AppSettingsState(
    preflightStrictness: strictness,
    polarAlignmentMaxAgeDays: polarAgeDays,
    darkLibraryMinCoverage: darkMinCoverage,
    opticalTrainDriftThreshold: opticalDriftThreshold,
    defaultGain: 100,
    defaultOffset: 10,
  );
}

PolarAlignmentError _alignErr() => PolarAlignmentError(
  azimuthError: 0.5,
  altitudeError: 0.4,
  totalError: 0.64,
  currentRa: 0,
  currentDec: 0,
  targetRa: 0,
  targetDec: 0,
  timestamp: DateTime.now(),
);

// Tests.

void main() {
  group('DarkLibraryCoverageRule', () {
    test('warns when no matching darks exist', () async {
      final container = await _buildContainer(
        settings: _settings(),
        camera: const CameraStateSnapshot(targetTemp: -10.0),
      );
      final rule = DarkLibraryCoverageRule();
      final s = _sequenceWith([_exposure()]);
      final issues = await _withRef(container, (ref) async {
        return rule.validate(s, ValidationContext(ref));
      });
      expect(issues, isNotEmpty);
      expect(issues.first.title, 'Missing Dark Frames');
      expect(issues.first.severity, ValidationSeverity.warning);
      expect(issues.first.category, ValidationCategory.darkLibrary);
    });

    test('clean when a master dark exists for the combination', () async {
      final container = await _buildContainer(
        settings: _settings(),
        camera: const CameraStateSnapshot(targetTemp: -10.0),
        seed: (db) async {
          await _insertDark(
            db,
            exposureTime: 180,
            gain: 100,
            offset: 10,
            binX: 1,
            binY: 1,
            temperature: -10.0,
            masterDarkPath: '/tmp/master_dark.fits',
          );
        },
      );
      final rule = DarkLibraryCoverageRule();
      final s = _sequenceWith([_exposure()]);
      final issues = await _withRef(container, (ref) async {
        return rule.validate(s, ValidationContext(ref));
      });
      expect(issues, isEmpty);
    });

    // Audit 2026-08-03: the rule stamped the camera's LIVE setpoint onto every
    // requirement, so a sequence whose Cool Camera node cools to +15 C was
    // checked (and offered "Capture missing darks") against darks at the
    // camera default of -10 C — a temperature the run never reaches.
    test('uses the setpoint the sequence cools to, not the live one', () async {
      final container = await _buildContainer(
        settings: _settings(),
        camera: const CameraStateSnapshot(targetTemp: -10.0),
        seed: (db) async {
          await _insertDark(
            db,
            exposureTime: 180,
            gain: 100,
            offset: 10,
            binX: 1,
            binY: 1,
            temperature: -10.0,
            masterDarkPath: '/tmp/master_dark_minus10.fits',
          );
        },
      );
      final rule = DarkLibraryCoverageRule();
      final s = _sequenceWith([CoolCameraNode(targetTemp: 15.0), _exposure()]);
      final issues = await _withRef(container, (ref) async {
        return rule.validate(s, ValidationContext(ref));
      });

      expect(issues, isNotEmpty);
      expect(issues.first.title, 'Missing Dark Frames');
      expect(issues.first.description, contains('temp=15.0C'));
      expect(
        issues.first.description,
        contains('Temperatures are the setpoints this sequence cools to.'),
      );
    });

    test('clean when the library holds darks at the cooled setpoint', () async {
      final container = await _buildContainer(
        settings: _settings(),
        camera: const CameraStateSnapshot(targetTemp: -10.0),
        seed: (db) async {
          await _insertDark(
            db,
            exposureTime: 180,
            gain: 100,
            offset: 10,
            binX: 1,
            binY: 1,
            temperature: 15.0,
            masterDarkPath: '/tmp/master_dark_plus15.fits',
          );
        },
      );
      final rule = DarkLibraryCoverageRule();
      final s = _sequenceWith([CoolCameraNode(targetTemp: 15.0), _exposure()]);
      final issues = await _withRef(container, (ref) async {
        return rule.validate(s, ValidationContext(ref));
      });

      expect(issues, isEmpty);
    });

    test('warns when raw coverage is below quorum', () async {
      final container = await _buildContainer(
        settings: _settings(darkMinCoverage: 10),
        camera: const CameraStateSnapshot(targetTemp: -10.0),
        seed: (db) async {
          for (var i = 0; i < 3; i++) {
            await _insertDark(db, exposureTime: 180, temperature: -10.0);
          }
        },
      );
      final rule = DarkLibraryCoverageRule();
      final s = _sequenceWith([_exposure()]);
      final issues = await _withRef(container, (ref) async {
        return rule.validate(s, ValidationContext(ref));
      });
      expect(issues.any((i) => i.title == 'Low Dark Library Coverage'), isTrue);
    });

    test('strict mode escalates missing darks to error', () async {
      final container = await _buildContainer(
        settings: _settings(strictness: PreflightStrictness.strict),
        camera: const CameraStateSnapshot(targetTemp: -10.0),
      );
      final rule = DarkLibraryCoverageRule();
      final s = _sequenceWith([_exposure()]);
      final issues = await _withRef(container, (ref) async {
        return rule.validate(s, ValidationContext(ref));
      });
      expect(issues.first.severity, ValidationSeverity.error);
    });

    test('lax mode degrades missing darks to info', () async {
      final container = await _buildContainer(
        settings: _settings(strictness: PreflightStrictness.lax),
        camera: const CameraStateSnapshot(targetTemp: -10.0),
      );
      final rule = DarkLibraryCoverageRule();
      final s = _sequenceWith([_exposure()]);
      final issues = await _withRef(container, (ref) async {
        return rule.validate(s, ValidationContext(ref));
      });
      expect(issues.first.severity, ValidationSeverity.info);
    });
  });

  group('HistoryDrivenQualityRule', () {
    test(
      'uses host-backed target and image streams without local DAO',
      () async {
        final targetRow = Target(
          id: 99,
          name: 'M51',
          catalogId: 'M51',
          ra: 13.5,
          dec: 47.2,
          minAltitude: 30,
          priority: 5,
          totalPlannedSubs: 0,
          capturedSubs: 0,
          totalIntegrationSecs: 0,
          goalIntegrationSecs: 0,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          isFavorite: false,
        );
        final frames = <CapturedImage>[
          for (var i = 0; i < 10; i++)
            CapturedImage(
              id: i,
              filePath: '/tmp/m51_$i.fits',
              fileName: 'm51_$i.fits',
              fileFormat: 'fits',
              targetId: 99,
              frameType: 'light',
              exposureDuration: 120,
              binX: 1,
              binY: 1,
              filter: 'L',
              isPlateSolved: false,
              capturedAt: DateTime.now(),
              createdAt: DateTime.now(),
              isAccepted: i >= 5,
              rejectionReason: i < 5 ? 'cloud rejection' : null,
            ),
        ];

        final container = await _buildContainer(
          settings: _settings(),
          hostTargets: [targetRow],
          hostImages: frames,
        );

        final target = TargetHeaderNode(
          id: 'target-m51',
          targetName: 'M51',
          raHours: 13.5,
          decDegrees: 47.2,
          childIds: const ['exp-l'],
        );
        final sequence = Sequence.create(
          name: 'T',
          nodes: {
            target.id: target,
            'exp-l': ExposureNode(
              id: 'exp-l',
              parentId: target.id,
              filter: 'L',
            ),
          },
        );

        final issues = await _withRef(container, (ref) {
          return HistoryDrivenQualityRule().validate(
            sequence,
            ValidationContext(ref),
          );
        });

        expect(issues, hasLength(1));
        expect(issues.single.title, 'High Previous Rejection Rate');
      },
    );

    test('warns when prior light-frame rejection rate is high', () async {
      final container = await _buildContainer(
        settings: _settings(),
        seed: (db) async {
          final targetId = await _insertTarget(db, name: 'M51');
          for (var i = 0; i < 5; i++) {
            await _insertLightFrame(
              db,
              targetId: targetId,
              isAccepted: false,
              rejectionReason: 'cloud rejection',
            );
          }
          for (var i = 0; i < 5; i++) {
            await _insertLightFrame(db, targetId: targetId, isAccepted: true);
          }
        },
      );
      final target = TargetHeaderNode(
        id: 'target-m51',
        targetName: 'M51',
        raHours: 13.5,
        decDegrees: 47.2,
        childIds: const ['exp-l'],
      );
      final sequence = Sequence.create(
        name: 'T',
        nodes: {
          target.id: target,
          'exp-l': ExposureNode(id: 'exp-l', parentId: target.id, filter: 'L'),
        },
      );

      final issues = await _withRef(container, (ref) {
        return HistoryDrivenQualityRule().validate(
          sequence,
          ValidationContext(ref),
        );
      });

      expect(issues, hasLength(1));
      expect(issues.single.title, 'High Previous Rejection Rate');
      expect(issues.single.severity, ValidationSeverity.warning);
      expect(issues.single.affectedNodeId, 'target-m51');
      expect(issues.single.description, contains('5 rejected'));
    });

    test('warns specifically for prior HFR and focus rejections', () async {
      final container = await _buildContainer(
        settings: _settings(),
        seed: (db) async {
          final targetId = await _insertTarget(db, name: 'NGC 7000');
          for (var i = 0; i < 3; i++) {
            await _insertLightFrame(
              db,
              targetId: targetId,
              isAccepted: false,
              filter: 'Ha',
              rejectionReason: 'HFR above threshold',
            );
          }
          for (var i = 0; i < 5; i++) {
            await _insertLightFrame(
              db,
              targetId: targetId,
              isAccepted: true,
              filter: 'Ha',
            );
          }
        },
      );
      final target = TargetHeaderNode(
        id: 'target-ngc7000',
        targetName: 'NGC 7000',
        raHours: 20.9,
        decDegrees: 44.3,
        childIds: const ['exp-ha'],
      );
      final sequence = Sequence.create(
        name: 'T',
        nodes: {
          target.id: target,
          'exp-ha': ExposureNode(
            id: 'exp-ha',
            parentId: target.id,
            filter: 'Ha',
          ),
        },
      );

      final issues = await _withRef(container, (ref) {
        return HistoryDrivenQualityRule().validate(
          sequence,
          ValidationContext(ref),
        );
      });

      expect(
        issues.map((issue) => issue.title),
        contains('Previous HFR Rejections'),
      );
    });

    test('ignores low sample sizes and unrelated planned filters', () async {
      final container = await _buildContainer(
        settings: _settings(),
        seed: (db) async {
          final targetId = await _insertTarget(db, name: 'M31');
          for (var i = 0; i < 7; i++) {
            await _insertLightFrame(
              db,
              targetId: targetId,
              isAccepted: false,
              filter: 'L',
              rejectionReason: 'HFR above threshold',
            );
          }
          for (var i = 0; i < 10; i++) {
            await _insertLightFrame(
              db,
              targetId: targetId,
              isAccepted: false,
              filter: 'Ha',
              rejectionReason: 'HFR above threshold',
            );
          }
        },
      );
      final target = TargetHeaderNode(
        id: 'target-m31',
        targetName: 'M31',
        raHours: 0.7,
        decDegrees: 41.3,
        childIds: const ['exp-l'],
      );
      final sequence = Sequence.create(
        name: 'T',
        nodes: {
          target.id: target,
          'exp-l': ExposureNode(id: 'exp-l', parentId: target.id, filter: 'L'),
        },
      );

      final issues = await _withRef(container, (ref) {
        return HistoryDrivenQualityRule().validate(
          sequence,
          ValidationContext(ref),
        );
      });

      expect(issues, isEmpty);
    });

    test('returns clean when target cannot be resolved', () async {
      final container = await _buildContainer(settings: _settings());
      final sequence = _sequenceWith([
        TargetHeaderNode(
          targetName: 'Unknown Target',
          raHours: 1,
          decDegrees: 2,
        ),
      ]);

      final issues = await _withRef(container, (ref) {
        return HistoryDrivenQualityRule().validate(
          sequence,
          ValidationContext(ref),
        );
      });

      expect(issues, isEmpty);
    });
  });

  group('UsbStabilityRule', () {
    test('warns when a device has > 3 disconnects in 24h', () async {
      final container = await _buildContainer(
        settings: _settings(),
        deviceHealth: const [
          DeviceHealthSnapshot(
            deviceId: 'camera',
            lastSuccessfulTimestampMs: 0,
            isHealthy: true,
            disconnectCountLast24h: 5,
          ),
        ],
      );
      final rule = UsbStabilityRule();
      final issues = _withRef(
        container,
        (ref) =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues, hasLength(1));
      expect(issues.first.severity, ValidationSeverity.warning);
      expect(issues.first.title, 'USB Stability Concern');
    });

    test('clean when disconnect count is below threshold', () async {
      final container = await _buildContainer(
        settings: _settings(),
        deviceHealth: const [
          DeviceHealthSnapshot(
            deviceId: 'camera',
            lastSuccessfulTimestampMs: 0,
            isHealthy: true,
            disconnectCountLast24h: 1,
          ),
        ],
      );
      final rule = UsbStabilityRule();
      final issues = _withRef(
        container,
        (ref) =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues, isEmpty);
    });
  });

  group('FocuserRangeRule', () {
    test('warns when focuser is near inner stop', () async {
      final container = await _buildContainer(
        settings: _settings(),
        focuser: const FocuserState(
          connectionState: DeviceConnectionState.connected,
          position: 50,
          maxPosition: 100000,
        ),
      );
      final rule = FocuserRangeRule();
      final issues = _withRef(
        container,
        (ref) => rule.validate(
          _sequenceWith([AutofocusNode()]),
          ValidationContext(ref),
        ),
      );
      expect(issues.first.title, 'Focuser Near Inner Travel Limit');
    });

    test('warns when focuser is near outer stop', () async {
      final container = await _buildContainer(
        settings: _settings(),
        focuser: const FocuserState(
          connectionState: DeviceConnectionState.connected,
          position: 99950,
          maxPosition: 100000,
        ),
      );
      final rule = FocuserRangeRule();
      final issues = _withRef(
        container,
        (ref) => rule.validate(
          _sequenceWith([AutofocusNode()]),
          ValidationContext(ref),
        ),
      );
      expect(issues.first.title, 'Focuser Near Outer Travel Limit');
    });

    test('clean when focuser is in the middle of travel', () async {
      final container = await _buildContainer(
        settings: _settings(),
        focuser: const FocuserState(
          connectionState: DeviceConnectionState.connected,
          position: 50000,
          maxPosition: 100000,
        ),
      );
      final rule = FocuserRangeRule();
      final issues = _withRef(
        container,
        (ref) => rule.validate(
          _sequenceWith([AutofocusNode()]),
          ValidationContext(ref),
        ),
      );
      expect(issues, isEmpty);
    });
  });

  group('PolarAlignmentFreshnessRule', () {
    test(
      'last-alignment lookup delegates to the host-aware provider',
      () async {
        final completedAt = DateTime.utc(2026, 7, 13);
        final hostEntry = PolarAlignmentHistoryEntry(
          id: 42,
          initialAzimuthError: 30,
          initialAltitudeError: 20,
          initialTotalError: 36,
          finalAzimuthError: 2,
          finalAltitudeError: 1,
          finalTotalError: 2.2,
          startedAt: completedAt.subtract(const Duration(minutes: 5)),
          completedAt: completedAt,
          autoCompleted: true,
          isNorth: true,
          configJson: '{}',
        );
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWith(
              (ref) => throw StateError('controller database was accessed'),
            ),
            lastPolarAlignmentProvider.overrideWith(
              (ref, profileId) async => hostEntry,
            ),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(
          lastPolarAlignmentAnywhereProvider.future,
        );

        expect(result, same(hostEntry));
      },
    );

    test(
      'zero-day setting disables both stale and missing-alignment notices',
      () async {
        final container = await _buildContainer(
          settings: _settings(polarAgeDays: 0),
        );
        final rule = PolarAlignmentFreshnessRule();
        await container.read(lastPolarAlignmentAnywhereProvider.future);

        final issues = _withRef(
          container,
          (ref) => rule.validate(
            _sequenceWith([SlewNode(useTargetCoords: true)]),
            ValidationContext(ref),
          ),
        );

        expect(issues, isEmpty);
      },
    );

    test('warns when last alignment exceeds the configured age', () async {
      final container = await _buildContainer(
        settings: _settings(polarAgeDays: 7),
        seed: (db) async {
          final dao = PolarAlignmentHistoryDao(db);
          await dao.insertResult(
            PolarAlignmentResult(
              initialError: _alignErr(),
              finalError: _alignErr(),
              startedAt: DateTime.now().subtract(const Duration(days: 14)),
              completedAt: DateTime.now().subtract(const Duration(days: 14)),
              config: const PolarAlignmentConfig(),
              autoCompleted: true,
              equipmentProfileId: null,
            ),
          );
        },
      );
      final rule = PolarAlignmentFreshnessRule();
      await container.read(lastPolarAlignmentAnywhereProvider.future);
      final issues = _withRef(
        container,
        (ref) => rule.validate(
          _sequenceWith([SlewNode(useTargetCoords: true)]),
          ValidationContext(ref),
        ),
      );
      expect(issues.first.title, 'Polar Alignment Is Stale');
    });

    test('clean when last alignment is recent', () async {
      final container = await _buildContainer(
        settings: _settings(polarAgeDays: 7),
        seed: (db) async {
          final dao = PolarAlignmentHistoryDao(db);
          await dao.insertResult(
            PolarAlignmentResult(
              initialError: _alignErr(),
              finalError: _alignErr(),
              startedAt: DateTime.now().subtract(const Duration(days: 1)),
              completedAt: DateTime.now().subtract(const Duration(days: 1)),
              config: const PolarAlignmentConfig(),
              autoCompleted: true,
              equipmentProfileId: null,
            ),
          );
        },
      );
      final rule = PolarAlignmentFreshnessRule();
      await container.read(lastPolarAlignmentAnywhereProvider.future);
      final issues = _withRef(
        container,
        (ref) => rule.validate(
          _sequenceWith([SlewNode(useTargetCoords: true)]),
          ValidationContext(ref),
        ),
      );
      expect(issues, isEmpty);
    });
  });

  group('TimeSyncRule', () {
    test('clean when drift is below 2 seconds', () async {
      final container = await _buildContainer(
        settings: _settings(),
        timeProbe: _FakeTimeProbe(0.5),
      );
      final rule = TimeSyncRule();
      final issues = await _withRef(
        container,
        (ref) async =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues, isEmpty);
    });

    test('warns at 5s drift in normal mode', () async {
      final container = await _buildContainer(
        settings: _settings(),
        timeProbe: _FakeTimeProbe(5.0),
      );
      final rule = TimeSyncRule();
      final issues = await _withRef(
        container,
        (ref) async =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues.first.severity, ValidationSeverity.warning);
    });

    test('errors at 45s drift regardless of strictness', () async {
      final container = await _buildContainer(
        settings: _settings(strictness: PreflightStrictness.lax),
        timeProbe: _FakeTimeProbe(45.0),
      );
      final rule = TimeSyncRule();
      final issues = await _withRef(
        container,
        (ref) async =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues.first.severity, ValidationSeverity.error);
      expect(issues.first.title, contains('Drift > 30'));
    });

    test('surfaces network failure as info severity', () async {
      final container = await _buildContainer(
        settings: _settings(),
        timeProbe: _FakeTimeProbe(0.0, shouldThrow: true),
      );
      final rule = TimeSyncRule();
      final issues = await _withRef(
        container,
        (ref) async =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues.first.severity, ValidationSeverity.info);
      expect(issues.first.title, 'Time Sync Check Unavailable');
    });
  });

  group('CoolerDeltaRule', () {
    test('warns when target temp is deeper than TEC headroom', () async {
      final container = await _buildContainer(
        settings: _settings(),
        camera: const CameraStateSnapshot(
          connectionState: DeviceConnectionState.connected,
          temperature: 28.0,
          targetTemp: -10.0,
        ),
      );
      final rule = CoolerDeltaRule();
      final issues = _withRef(
        container,
        (ref) =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues.first.title, 'Cooler May Not Reach Setpoint');
    });

    test('clean when delta is realistic', () async {
      final container = await _buildContainer(
        settings: _settings(),
        camera: const CameraStateSnapshot(
          connectionState: DeviceConnectionState.connected,
          temperature: 10.0,
          targetTemp: -10.0,
        ),
      );
      final rule = CoolerDeltaRule();
      final issues = _withRef(
        container,
        (ref) =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues, isEmpty);
    });
  });

  group('FilterWheelHomingRule', () {
    test('warns when filter wheel has no current position', () async {
      final container = await _buildContainer(
        settings: _settings(),
        filterWheel: const FilterWheelState(
          connectionState: DeviceConnectionState.connected,
          filterNames: ['L', 'R', 'G', 'B'],
          currentPosition: null,
        ),
      );
      final rule = FilterWheelHomingRule();
      final issues = _withRef(
        container,
        (ref) => rule.validate(
          _sequenceWith([FilterChangeNode(filterName: 'L')]),
          ValidationContext(ref),
        ),
      );
      expect(issues.first.title, 'Filter Wheel Not Homed');
    });

    test('clean when filter wheel reports a position', () async {
      final container = await _buildContainer(
        settings: _settings(),
        filterWheel: const FilterWheelState(
          connectionState: DeviceConnectionState.connected,
          filterNames: ['L'],
          currentPosition: 0,
        ),
      );
      final rule = FilterWheelHomingRule();
      final issues = _withRef(
        container,
        (ref) => rule.validate(
          _sequenceWith([FilterChangeNode(filterName: 'L')]),
          ValidationContext(ref),
        ),
      );
      expect(issues, isEmpty);
    });
  });

  group('OpticalTrainPreflightRule', () {
    test('warns when drift exceeds the threshold', () async {
      final container = await _buildContainer(
        settings: _settings(opticalDriftThreshold: 5.0),
        baseline: OpticalTrainBaseline(
          tiltScore: 5.0,
          collimationScore: 5.0,
          capturedAt: DateTime(2026, 1, 1),
        ),
        current: OpticalTrainBaseline(
          tiltScore: 25.0,
          collimationScore: 5.0,
          capturedAt: DateTime(2026, 1, 2),
        ),
      );
      final rule = OpticalTrainPreflightRule();
      final issues = _withRef(
        container,
        (ref) =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues.first.title, 'Optical Train Has Shifted');
    });

    test('info when no baseline is recorded', () async {
      final container = await _buildContainer(
        settings: _settings(),
        current: OpticalTrainBaseline(
          tiltScore: 5.0,
          collimationScore: 5.0,
          capturedAt: DateTime(2026, 1, 1),
        ),
      );
      final rule = OpticalTrainPreflightRule();
      final issues = _withRef(
        container,
        (ref) =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues.first.severity, ValidationSeverity.info);
      expect(issues.first.title, contains('Baseline'));
    });

    test('clean when drift is within threshold', () async {
      final container = await _buildContainer(
        settings: _settings(opticalDriftThreshold: 50.0),
        baseline: OpticalTrainBaseline(
          tiltScore: 5.0,
          collimationScore: 5.0,
          capturedAt: DateTime(2026, 1, 1),
        ),
        current: OpticalTrainBaseline(
          tiltScore: 6.0,
          collimationScore: 6.0,
          capturedAt: DateTime(2026, 1, 2),
        ),
      );
      final rule = OpticalTrainPreflightRule();
      final issues = _withRef(
        container,
        (ref) =>
            rule.validate(_sequenceWith([_exposure()]), ValidationContext(ref)),
      );
      expect(issues, isEmpty);
    });
  });
}
