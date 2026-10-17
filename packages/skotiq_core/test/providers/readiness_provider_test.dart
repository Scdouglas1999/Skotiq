import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/plate_solver.dart';
import 'package:skotiq_core/src/models/readiness/readiness_models.dart';
import 'package:skotiq_core/src/providers/dark_library_provider.dart';
import 'package:skotiq_core/src/providers/equipment/camera_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/focuser_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/mount_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/profile_connection_status_provider.dart';
import 'package:skotiq_core/src/providers/plate_solver_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/readiness_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/database/daos/dark_library_dao.dart';
import '../harness/in_memory_database.dart';

// Test doubles
//
// Each input provider is overridden so the readiness provider can be exercised
// in isolation, without a Drift database or live device backends. The fake
// notifiers simply seed `state`; readiness only reads connection state and
// (for the focuser) the reported position.

/// Camera notifier seeded to a fixed snapshot. The production notifier reaches
/// out to `DeviceService`; readiness only consumes `connectionState`.
class _FakeCameraNotifier extends StateNotifier<CameraStateSnapshot>
    implements CameraStateNotifier {
  _FakeCameraNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMountNotifier extends StateNotifier<MountState>
    implements MountStateNotifier {
  _FakeMountNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFocuserNotifier extends StateNotifier<FocuserState>
    implements FocuserStateNotifier {
  _FakeFocuserNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Settings notifier resolving immediately to a fixed [AppSettingsState].
class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._value);

  final AppSettingsState _value;

  @override
  Future<AppSettingsState> build() async => _value;
}

const _connected = DeviceConnectionState.connected;
const _disconnected = DeviceConnectionState.disconnected;

/// A profile model with only the fields readiness cares about (existence).
const _sampleProfile = EquipmentProfileModel(id: 1, name: 'Test rig');

/// Settings that satisfy both location and output-path checks.
const _readySettings = AppSettingsState(
  latitude: 40.0,
  longitude: -74.0,
  imageOutputPath: r'C:\captures',
);

/// ASTAP detected with a catalog -> `astapReady == true`.
const _readyDetection = PlateSolverDetection(
  astapPath: r'C:\astap\astap.exe',
  catalogPath: r'C:\astap\catalog',
  catalogName: 'V17',
);

const _noSolverDetection = PlateSolverDetection();

/// astrometry.net installed, no ASTAP. `astapReady == false` but
/// `hasAnySolver == true` — a fully working solver setup that must read as
/// plate-solver READY (not the "no solver configured" caution).
const _astrometryOnlyDetection = PlateSolverDetection(
  astrometryPath: '/usr/bin/solve-field',
);

const _coveredStats = DarkLibraryStats(
  totalEntries: 3,
  darkCount: 2,
  biasCount: 0,
  masterCount: 1,
);

const _emptyStats = DarkLibraryStats(
  totalEntries: 0,
  darkCount: 0,
  biasCount: 0,
  masterCount: 0,
);

/// Builds a fully-overridden container. Any parameter left at its default
/// describes a happy-path, fully-ready setup. Individual tests flip the
/// signals they care about. When [plateSolverDetectionLoading] is true the
/// detection future never completes, exercising the loading branch.
ProviderContainer _container({
  bool hasProfile = true,
  DeviceConnectionState camera = _connected,
  DeviceConnectionState mount = _connected,
  AppSettingsState settings = _readySettings,
  PlateSolverDetection detection = _readyDetection,
  PlateSolverPreference solverPreference = const PlateSolverPreference(),
  bool plateSolverDetectionLoading = false,
  DarkLibraryStats darkStats = _coveredStats,
  DeviceConnectionState focuser = _connected,
  int? focuserPosition = 5000,
  List<String> offlineProfileDevices = const <String>[],
  // Default = a populated profile (camera, mount, focuser, guider) so the
  // happy path is a real pass, not the vacuous one an empty profile produced.
  List<ProfileDeviceSlot> assignedProfileSlots = const [
    ProfileDeviceSlot.camera,
    ProfileDeviceSlot.mount,
    ProfileDeviceSlot.focuser,
    ProfileDeviceSlot.guider,
  ],
}) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      equipmentProfileListProvider.overrideWithValue(
        hasProfile ? [_sampleProfile] : const [],
      ),
      activeEquipmentProfileProvider.overrideWithValue(
        hasProfile ? _sampleProfile : null,
      ),
      // Derived from the active profile + every per-device notifier in
      // production; overridden here so the report stays exercisable without a
      // Drift database (reading the real provider opens one).
      offlineProfileDeviceNamesProvider.overrideWithValue(
        offlineProfileDevices,
      ),
      assignedProfileDeviceSlotsProvider.overrideWithValue(
        assignedProfileSlots,
      ),
      cameraStateProvider.overrideWith(
        (ref) =>
            _FakeCameraNotifier(CameraStateSnapshot(connectionState: camera)),
      ),
      mountStateProvider.overrideWith(
        (ref) => _FakeMountNotifier(MountState(connectionState: mount)),
      ),
      focuserStateProvider.overrideWith(
        (ref) => _FakeFocuserNotifier(
          FocuserState(connectionState: focuser, position: focuserPosition),
        ),
      ),
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(settings),
      ),
      plateSolverDetectionProvider.overrideWith(
        (ref) => plateSolverDetectionLoading
            ? Completer<PlateSolverDetection>()
                  .future // never completes
            : Future.value(detection),
      ),
      plateSolverPreferenceProvider.overrideWith(
        (ref) => Future.value(solverPreference),
      ),
      darkLibraryStatsProvider.overrideWith((ref) => Future.value(darkStats)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Pumps async providers ([appSettingsProvider], [darkLibraryStatsProvider],
/// [plateSolverDetectionProvider], [plateSolverPreferenceProvider]) to their
/// resolved value before reading the
/// (synchronous) readiness report.
///
/// When [awaitPlateSolver] is false the plate-solver future is intentionally
/// left unresolved (it never completes in the loading test) so its
/// `valueOrNull` stays null — the fail-closed behaviour under test.
Future<ReadinessReport> _resolveReport(
  ProviderContainer container, {
  bool awaitPlateSolver = true,
}) async {
  await container.read(appSettingsProvider.future);
  await container.read(darkLibraryStatsProvider.future);
  await container.read(plateSolverPreferenceProvider.future);
  if (awaitPlateSolver) {
    await container.read(plateSolverDetectionProvider.future);
  }
  return container.read(readinessReportProvider);
}

void main() {
  group('readinessReportProvider', () {
    test('disconnected camera -> overall blocked (fail-closed)', () async {
      final container = _container(camera: _disconnected);
      final report = await _resolveReport(container);

      expect(report.overall, ReadinessLevel.blocked);
      final critical = report.itemFor(ReadinessItemId.criticalDevices);
      expect(critical, isNotNull);
      expect(critical!.level, ReadinessLevel.blocked);
      expect(
        critical.fixRoute,
        isNotNull,
        reason: 'a blocked critical-devices item must offer a remediation',
      );
      expect(container.read(readinessOverallProvider), ReadinessLevel.blocked);
    });

    test('no equipment profile -> overall blocked (fail-closed)', () async {
      final container = _container(hasProfile: false);
      final report = await _resolveReport(container);

      expect(report.overall, ReadinessLevel.blocked);
      expect(
        report.itemFor(ReadinessItemId.criticalDevices)!.level,
        ReadinessLevel.blocked,
      );
    });

    test('all signals satisfied -> overall ready', () async {
      final container = _container();
      final report = await _resolveReport(container);

      expect(report.overall, ReadinessLevel.ready);
      for (final item in report.items) {
        expect(
          item.level,
          ReadinessLevel.ready,
          reason: '${item.id.name} should be ready in the happy path',
        );
        expect(
          item.fixRoute,
          isNull,
          reason: 'ready items expose no remediation route',
        );
      }
      expect(container.read(readinessOverallProvider), ReadinessLevel.ready);
    });

    test('plate-solver detection in loading state -> plateSolver caution, '
        'overall caution (fail-closed, non-blocking)', () async {
      final container = _container(plateSolverDetectionLoading: true);
      final report = await _resolveReport(container, awaitPlateSolver: false);

      final solver = report.itemFor(ReadinessItemId.plateSolver);
      expect(solver, isNotNull);
      expect(
        solver!.level,
        ReadinessLevel.caution,
        reason: 'a loading detection must fail closed to not-ready',
      );
      // The plate-solver item is the only non-green signal, and it is a
      // caution (not blocked), so the whole report is caution — never green.
      expect(report.overall, ReadinessLevel.caution);
      expect(container.read(readinessOverallProvider), ReadinessLevel.caution);
    });

    test('plate-solver detection error -> plateSolver caution', () async {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          equipmentProfileListProvider.overrideWithValue([_sampleProfile]),
          offlineProfileDeviceNamesProvider.overrideWithValue(const <String>[]),
          cameraStateProvider.overrideWith(
            (ref) => _FakeCameraNotifier(
              const CameraStateSnapshot(connectionState: _connected),
            ),
          ),
          mountStateProvider.overrideWith(
            (ref) => _FakeMountNotifier(
              const MountState(connectionState: _connected),
            ),
          ),
          focuserStateProvider.overrideWith(
            (ref) => _FakeFocuserNotifier(
              const FocuserState(connectionState: _connected, position: 5000),
            ),
          ),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(_readySettings),
          ),
          plateSolverDetectionProvider.overrideWith(
            (ref) =>
                Future<PlateSolverDetection>.error(StateError('detect failed')),
          ),
          plateSolverPreferenceProvider.overrideWith(
            (ref) => Future.value(const PlateSolverPreference()),
          ),
          darkLibraryStatsProvider.overrideWith(
            (ref) => Future.value(_coveredStats),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      await container.read(darkLibraryStatsProvider.future);
      await container.read(plateSolverPreferenceProvider.future);
      // Drive the errored plate-solver future to completion without throwing
      // out of the test body.
      await expectLater(
        container.read(plateSolverDetectionProvider.future),
        throwsStateError,
      );

      final report = container.read(readinessReportProvider);
      expect(
        report.itemFor(ReadinessItemId.plateSolver)!.level,
        ReadinessLevel.caution,
      );
      expect(report.overall, ReadinessLevel.caution);
    });

    test('location unset (0.0/0.0 sentinel) -> location blocked', () async {
      final container = _container(
        settings: const AppSettingsState(
          latitude: 0.0,
          longitude: 0.0,
          imageOutputPath: r'C:\captures',
        ),
      );
      final report = await _resolveReport(container);

      expect(
        report.itemFor(ReadinessItemId.location)!.level,
        ReadinessLevel.blocked,
      );
      expect(report.overall, ReadinessLevel.blocked);
    });

    test('output path empty -> outputPath blocked', () async {
      final container = _container(
        settings: const AppSettingsState(
          latitude: 40.0,
          longitude: -74.0,
          imageOutputPath: '   ',
        ),
      );
      final report = await _resolveReport(container);

      expect(
        report.itemFor(ReadinessItemId.outputPath)!.level,
        ReadinessLevel.blocked,
      );
    });

    test(
      'disconnected mount -> criticalDevices caution (non-blocking)',
      () async {
        final container = _container(mount: _disconnected);
        final report = await _resolveReport(container);

        // Camera connected + mount disconnected => caution, not blocked.
        expect(
          report.itemFor(ReadinessItemId.criticalDevices)!.level,
          ReadinessLevel.caution,
        );
        // No blocking items elsewhere, so overall is caution.
        expect(report.overall, ReadinessLevel.caution);
      },
    );

    test('empty dark library -> darkLibrary caution', () async {
      final container = _container(darkStats: _emptyStats);
      final report = await _resolveReport(container);

      expect(
        report.itemFor(ReadinessItemId.darkLibrary)!.level,
        ReadinessLevel.caution,
      );
      expect(report.overall, ReadinessLevel.caution);
    });

    test('focuser connected but no position -> focusState caution', () async {
      final container = _container(focuserPosition: null);
      final report = await _resolveReport(container);

      expect(
        report.itemFor(ReadinessItemId.focusState)!.level,
        ReadinessLevel.caution,
      );
      expect(report.overall, ReadinessLevel.caution);
    });

    test('focuser disconnected -> focusState caution', () async {
      final container = _container(focuser: _disconnected);
      final report = await _resolveReport(container);

      expect(
        report.itemFor(ReadinessItemId.focusState)!.level,
        ReadinessLevel.caution,
      );
    });

    test('no solver detected -> plateSolver caution', () async {
      final container = _container(detection: _noSolverDetection);
      final report = await _resolveReport(container);

      expect(
        report.itemFor(ReadinessItemId.plateSolver)!.level,
        ReadinessLevel.caution,
      );
      expect(report.overall, ReadinessLevel.caution);
    });

    test(
      'astrometry.net-only solver in Auto mode -> plateSolver ready',
      () async {
        final container = _container(detection: _astrometryOnlyDetection);
        final report = await _resolveReport(container);

        // A working astrometry.net rig must not be flagged as "no solver".
        expect(
          report.itemFor(ReadinessItemId.plateSolver)!.level,
          ReadinessLevel.ready,
        );
        // Every other signal is happy in the default container, so the report
        // is fully ready.
        expect(report.overall, ReadinessLevel.ready);
      },
    );

    test(
      'selected ASTAP without a catalog is not masked by astrometry install',
      () async {
        final container = _container(
          detection: const PlateSolverDetection(
            astapPath: '/opt/astap/astap',
            astrometryPath: '/usr/bin/solve-field',
          ),
          solverPreference: const PlateSolverPreference(
            choice: PlateSolverChoice.astap,
          ),
        );
        final report = await _resolveReport(container);

        expect(
          report.itemFor(ReadinessItemId.plateSolver)!.level,
          ReadinessLevel.caution,
        );
        expect(report.overall, ReadinessLevel.caution);
      },
    );

    test('readinessOverallProvider mirrors report.overall', () async {
      final container = _container(camera: _disconnected);
      await _resolveReport(container);
      expect(
        container.read(readinessOverallProvider),
        container.read(readinessReportProvider).overall,
      );
    });

    // No-hardware campaign 2026-07-29: the profile's guider failed to connect
    // on every launch and the readiness rail read "Ready to image / 2 items to
    // review" where the 2 items were the plate solver and the dark library —
    // the failed guider was not one of them, and appeared nowhere else in the
    // product except a tooltip on a ~6 px dot.
    test('an offline profile device is named as a readiness item', () async {
      final container = _container(offlineProfileDevices: const ['Guider']);
      final report = await _resolveReport(container);

      final item = report.itemFor(ReadinessItemId.profileDevices);
      expect(item, isNotNull);
      expect(item!.level, ReadinessLevel.caution);
      expect(item.detail, contains('Guider'));
      expect(item.fixRoute, '/equipment');
      expect(
        report.cautionItems.map((i) => i.id),
        contains(ReadinessItemId.profileDevices),
      );
      expect(report.overall, ReadinessLevel.caution);
    });

    test('all profile devices connected -> profileDevices ready', () async {
      final container = _container();
      final report = await _resolveReport(container);

      expect(
        report.itemFor(ReadinessItemId.profileDevices)!.level,
        ReadinessLevel.ready,
      );
      expect(report.overall, ReadinessLevel.ready);
    });

    // An empty profile produces an empty offline-device list, which reads the
    // same as "every assigned device is connected" unless the rule also sees
    // the assignment SET. This asserts the provider wires that set through,
    // not just that the model rule exists.
    test('profile with zero assigned devices -> profileDevices caution, not a '
        'vacuous all-connected pass', () async {
      final container = _container(
        camera: _disconnected,
        mount: _disconnected,
        assignedProfileSlots: const <ProfileDeviceSlot>[],
      );
      final report = await _resolveReport(container);

      final item = report.itemFor(ReadinessItemId.profileDevices)!;
      expect(item.level, ReadinessLevel.caution);
      expect(item.detail, contains('No devices are assigned'));
      expect(
        item.detail,
        isNot(contains('is connected')),
        reason: 'must not claim connectivity over an empty assignment set',
      );
      expect(item.fixRoute, '/equipment');
    });

    test('camera/mount-only profile -> profileDevices ready without claiming '
        'every device is connected', () async {
      final container = _container(
        assignedProfileSlots: const [
          ProfileDeviceSlot.camera,
          ProfileDeviceSlot.mount,
        ],
      );
      final report = await _resolveReport(container);

      final item = report.itemFor(ReadinessItemId.profileDevices)!;
      expect(item.level, ReadinessLevel.ready);
      expect(item.detail, contains('no accessories'));
    });

    test(
      'no active profile -> profileDevices makes no assignment claim',
      () async {
        final container = _container(hasProfile: false);
        final report = await _resolveReport(container);

        final item = report.itemFor(ReadinessItemId.profileDevices)!;
        expect(item.detail, contains('No equipment profile is active'));
      },
    );
  });
}
