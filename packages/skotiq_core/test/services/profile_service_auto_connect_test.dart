import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;

/// Contract coverage for [ProfileService.autoConnectOnStartup] — the single
/// core the desktop [StartupAutoConnectLauncher] and the headless
/// `headlessAutoConnectBootstrap` both drive.
///
/// The contract under test:
///   * No-op when the setting is off, and no-op when there is no startup
///     profile (fresh install) — never activate, never connect.
///   * The startup profile is activated with a STRICT native write-through
///     BEFORE any device connect. If that write-through fails, NOTHING is
///     connected and the error propagates ("activation failure -> connect
///     nothing").
///   * Every configured device slot (including switch + safety monitor) is
///     handed to the connector, and per-device failures are aggregated into a
///     [ProfileAutoConnectException] after the whole sweep instead of aborting
///     on the first failure.
class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockDeviceService extends Mock implements DeviceService {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _AutoConnectOn extends AutoConnectSettingsNotifier {
  @override
  Future<bool> build() async => true;
}

class _AutoConnectOff extends AutoConnectSettingsNotifier {
  @override
  Future<bool> build() async => false;
}

/// No-op logger so the strict write-through's ERROR log never reaches the
/// native logging bridge (unavailable in a pure Dart unit test).
class _SilentLogger extends LoggingService {
  @override
  void debug(String message, {String? source, Map<String, Object?>? fields}) {}
  @override
  void info(String message, {String? source, Map<String, Object?>? fields}) {}
  @override
  void warning(
    String message, {
    String? source,
    Map<String, Object?>? fields,
  }) {}
  @override
  void error(String message, {String? source, Map<String, Object?>? fields}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
    registerFallbackValue(
      const remote_profile.EquipmentProfile(id: '0', name: 'fallback'),
    );
    registerFallbackValue(const EquipmentProfileModel(name: 'fallback'));
  });

  late SkotiqDatabase db;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer buildContainer({
    required SkotiqBackend backend,
    required DeviceService deviceService,
    required bool autoConnectEnabled,
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        loggingServiceProvider.overrideWithValue(_SilentLogger()),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        deviceServiceProvider.overrideWithValue(deviceService),
        autoConnectSettingsProvider.overrideWith(
          autoConnectEnabled ? _AutoConnectOn.new : _AutoConnectOff.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  _MockFfiBackend healthyBackend() {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.saveProfile(any())).thenAnswer((_) async {});
    when(() => backend.loadProfile(any())).thenAnswer((_) async {});
    return backend;
  }

  test('does nothing when the auto-connect setting is off', () async {
    final backend = healthyBackend();
    final ds = _MockDeviceService();
    final container = buildContainer(
      backend: backend,
      deviceService: ds,
      autoConnectEnabled: false,
    );

    final dao = container.read(equipmentProfilesDaoProvider);
    await dao.createProfile(
      const EquipmentProfileModel(
        name: 'Rig',
        cameraId: 'ascom:camera:1',
      ).toCompanion(),
    );

    await container.read(profileServiceProvider).autoConnectOnStartup();

    // Never activates and never connects when disabled.
    verifyNever(() => backend.saveProfile(any()));
    verifyNever(() => ds.connectAllFromProfile(any()));
  });

  test(
    'does nothing when there is no startup profile (fresh install)',
    () async {
      final backend = healthyBackend();
      final ds = _MockDeviceService();
      final container = buildContainer(
        backend: backend,
        deviceService: ds,
        autoConnectEnabled: true,
      );

      // No profiles created at all.
      await container.read(profileServiceProvider).autoConnectOnStartup();

      verifyNever(() => backend.saveProfile(any()));
      verifyNever(() => ds.connectAllFromProfile(any()));
    },
  );

  test('activation failure connects nothing and surfaces the error', () async {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    // Strict native write-through fails at the save step.
    when(
      () => backend.saveProfile(any()),
    ).thenThrow(Exception('native profile store offline'));
    when(() => backend.loadProfile(any())).thenAnswer((_) async {});

    final ds = _MockDeviceService();
    final container = buildContainer(
      backend: backend,
      deviceService: ds,
      autoConnectEnabled: true,
    );

    final dao = container.read(equipmentProfilesDaoProvider);
    await dao.createProfile(
      const EquipmentProfileModel(
        name: 'Rig',
        cameraId: 'ascom:camera:1',
      ).toCompanion(),
    );

    // The failure propagates...
    await expectLater(
      container.read(profileServiceProvider).autoConnectOnStartup(),
      throwsA(isA<Exception>()),
    );

    // ...and NOT a single device was connected.
    verifyNever(() => ds.connectAllFromProfile(any()));
  });

  test('attempts every slot (incl. switch + safety monitor) and aggregates '
      'partial failures after the full sweep', () async {
    final backend = healthyBackend();
    final ds = _MockDeviceService();
    // Camera + mount connect; switch + safety monitor fail. The stream never
    // errors — a single bad device must not abort the sweep.
    when(() => ds.connectAllFromProfile(any())).thenAnswer(
      (_) => Stream<DeviceConnectProgress>.fromIterable(const [
        DeviceConnectProgress(
          deviceType: 'camera',
          deviceId: 'ascom:camera:1',
          status: DeviceConnectProgressStatus.connected,
        ),
        DeviceConnectProgress(
          deviceType: 'mount',
          deviceId: 'ascom:mount:1',
          status: DeviceConnectProgressStatus.connected,
        ),
        DeviceConnectProgress(
          deviceType: 'switch',
          deviceId: 'ascom:switch:1',
          status: DeviceConnectProgressStatus.failed,
          errorMessage: 'switch offline',
        ),
        DeviceConnectProgress(
          deviceType: 'safety monitor',
          deviceId: 'ascom:safety:1',
          status: DeviceConnectProgressStatus.failed,
          errorMessage: 'safety monitor offline',
        ),
      ]),
    );

    final container = buildContainer(
      backend: backend,
      deviceService: ds,
      autoConnectEnabled: true,
    );

    final dao = container.read(equipmentProfilesDaoProvider);
    await dao.createProfile(
      const EquipmentProfileModel(
        name: 'Rig',
        cameraId: 'ascom:camera:1',
        mountId: 'ascom:mount:1',
        switchId: 'ascom:switch:1',
        safetyMonitorId: 'ascom:safety:1',
      ).toCompanion(),
    );

    Object? caught;
    try {
      await container.read(profileServiceProvider).autoConnectOnStartup();
    } catch (error) {
      caught = error;
    }

    // Both failures aggregated into a single post-sweep exception.
    expect(caught, isA<ProfileAutoConnectException>());
    final ex = caught! as ProfileAutoConnectException;
    expect(ex.profileName, 'Rig');
    expect(ex.failures, hasLength(2));
    expect(ex.failures.join('; '), contains('switch'));
    expect(ex.failures.join('; '), contains('safety monitor'));

    // Activation happened exactly once, before the connect sweep.
    verify(() => backend.saveProfile(any())).called(1);

    // The full profile (including the switch + safety-monitor slots) was
    // handed to the connector.
    final captured = verify(
      () => ds.connectAllFromProfile(captureAny()),
    ).captured;
    final passed = captured.single as EquipmentProfileModel;
    expect(passed.switchId, 'ascom:switch:1');
    expect(passed.safetyMonitorId, 'ascom:safety:1');
  });
}
