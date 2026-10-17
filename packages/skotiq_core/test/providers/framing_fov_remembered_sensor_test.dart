// Framing must work with the rig unplugged.
//
// `framingFOVProvider` only ever learned the sensor's pixel dimensions from a
// live `getCameraStatus` call, so with a fully configured profile — focal
// length, aperture, pixel size, a camera assigned — Framing still reported
// `Camera Not Configured` and refused both the FOV overlay and the mosaic
// planner until the camera was powered up and connected. Framing and mosaic
// planning are the two things you do indoors, ahead of a session.
//
// Sensor size is a fixed property of the camera body, so once the app has read
// it off the live device it never needs the device again.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../mocks/mock_backend.dart';
import '../harness/in_memory_database.dart';

const _status = CameraStatus(
  connected: true,
  state: CameraState.idle,
  coolerOn: false,
  gain: 100,
  offset: 10,
  binX: 1,
  binY: 1,
  sensorWidth: 1920,
  sensorHeight: 1080,
  pixelSizeX: 3.76,
  pixelSizeY: 3.76,
  maxAdu: 65535,
  canCool: true,
  canSetGain: true,
  canSetOffset: true,
);

const _profile = EquipmentProfileModel(
  id: 1,
  name: 'My First Rig',
  isActive: true,
  cameraId: 'sim_camera_1',
  focalLength: 530,
  aperture: 106,
);

void main() {
  setUpAll(registerMocktailFallbackValues);

  ProviderContainer buildContainer({
    required MockBackend backend,
    required bool connected,
    Override? databaseOverride,
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseOverride ?? inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _FixedBackend(ref, backend)),
        activeEquipmentProfileProvider.overrideWithValue(_profile),
        cameraStateProvider.overrideWith((ref) {
          final camera = CameraStateNotifier(ref)
            ..setConnecting('sim_camera_1', 'Simulated Camera');
          if (connected) camera.setConnected();
          return camera;
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'a camera seen once keeps Framing working after it is disconnected',
    () async {
      final backend = MockBackend();
      when(
        () => backend.getCameraStatus(any()),
      ).thenAnswer((_) async => _status);

      // ONE database instance shared by both containers, so the second run is
      // the same install on a later evening with the rig packed away.
      // `inMemoryDatabaseOverride()` builds a fresh database per container,
      // which would make this test pass for the wrong reason (or rather, fail
      // for one).
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final database = databaseProvider.overrideWithValue(db);

      final connectedRun = buildContainer(
        backend: backend,
        connected: true,
        databaseOverride: database,
      );
      final live = await connectedRun.read(framingFOVProvider.future);
      expect(live.isReady, isTrue, reason: 'precondition: connected FOV works');
      expect(live.equipment!.pixelsX, 1920);

      // Now the camera is gone: never queried, never even reachable.
      final offlineBackend = MockBackend();
      when(
        () => offlineBackend.getCameraStatus(any()),
      ).thenThrow(StateError('camera is not connected'));

      final offlineRun = buildContainer(
        backend: offlineBackend,
        connected: false,
        databaseOverride: database,
      );
      final offline = await offlineRun.read(framingFOVProvider.future);

      expect(
        offline.status,
        EquipmentStatus.ready,
        reason:
            'the sensor size was already known; framing must not need the '
            'rig powered up',
      );
      expect(offline.equipment!.pixelsX, 1920);
      expect(offline.equipment!.pixelsY, 1080);
      expect(offline.equipment!.pixelSizeMicrons, 3.76);
      // 1920 * 3.76 / 1000
      expect(offline.equipment!.sensorWidthMm, closeTo(7.2192, 1e-6));
      expect(
        offline.message,
        contains('remembered'),
        reason: 'the user has to be told these are last-seen values',
      );
      verifyNever(() => offlineBackend.getCameraStatus(any()));
    },
  );

  test('a camera never seen connected still reports no specs', () async {
    final backend = MockBackend();
    when(
      () => backend.getCameraStatus(any()),
    ).thenThrow(StateError('camera is not connected'));

    final container = buildContainer(backend: backend, connected: false);
    final result = await container.read(framingFOVProvider.future);

    expect(
      result.status,
      EquipmentStatus.noCameraSpecs,
      reason:
          'nothing is known about this sensor, and a guessed FOV is worse '
          'than none',
    );
  });

  test('a known camera model works before it is ever connected', () async {
    // The tier below "remembered": a camera the app has never seen, but whose
    // manufacturer publishes its geometry. Framing used to refuse this
    // outright, which is what made the owner's Plan screen call an
    // ASI1600MM-Cool's specs unknown on a fresh install.
    final backend = MockBackend();
    when(
      () => backend.getCameraStatus(any()),
    ).thenThrow(StateError('camera is not connected'));

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _FixedBackend(ref, backend)),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 2,
            name: 'Owner rig',
            isActive: true,
            cameraId: 'ASI1600MM-Cool',
            cameraName: 'ASI1600MM-Cool',
            focalLength: 530,
            aperture: 106,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(framingFOVProvider.future);
    expect(result.status, EquipmentStatus.ready);
    // ZWO's ASI1600 manual: 4656 x 3520 at 3.8 um.
    expect(result.equipment!.pixelsX, 4656);
    expect(result.equipment!.pixelsY, 3520);
    expect(result.equipment!.pixelSizeMicrons, 3.8);
    expect(
      result.message,
      'Sensor size from the published specification for ZWO ASI1600MM. '
      'Connect the camera once to use its own reading instead.',
      reason:
          'a published figure and a reading off the camera are different '
          'claims, so the card must not present one as the other',
    );
  });

  test('fetching camera capabilities remembers the sensor', () async {
    final backend = MockBackend();
    when(() => backend.getCameraCapabilities(any())).thenAnswer(
      (_) async => const CameraCapabilities(
        maxWidth: 6248,
        maxHeight: 4176,
        bitDepth: 16,
        pixelSizeX: 3.76,
        pixelSizeY: 3.76,
        sensorType: 'Monochrome',
      ),
    );

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _FixedBackend(ref, backend)),
      ],
    );
    addTearDown(container.dispose);

    await container.read(cameraCapabilitiesProvider('imx455').future);

    final remembered = await container
        .read(settingsDaoProvider)
        .getRememberedSensorSpec('imx455');
    expect(
      remembered,
      isNotNull,
      reason:
          'the connect path is where the app learns the sensor size, so the '
          'user must not have to visit a particular screen for it to stick',
    );
    expect(remembered!.sensorWidth, 6248);
    expect(remembered.sensorHeight, 4176);
    expect(remembered.pixelSizeX, 3.76);
  });
}

/// Keeps the provider graph on one backend for the test's life.
class _FixedBackend extends BackendNotifier {
  _FixedBackend(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
