import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/session_optimizer_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/sensor_specs/camera_sensor_specs.dart';
import 'package:skotiq_core/src/services/smart_night/hardware_specs_service.dart';

final _initialSettingsProvider = Provider<AppSettingsState>(
  (_) => throw UnimplementedError('Override in test'),
);

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async {
    return ref.read(_initialSettingsProvider);
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'remote Smart Night context uses host settings and host guide history',
    () async {
      final backend = _MockNetworkBackend();
      when(
        backend.getScienceSettings,
      ).thenAnswer((_) async => {'science.camera.read_noise_e': '1.1'});
      when(backend.getSmartNightSettings).thenAnswer(
        (_) async => {
          'smart_night.camera.full_well_e': '51000',
          'smart_night.camera.qe_peak': '0.88',
          'smart_night.glover_k_factor': '14',
          HardwareSpecsService.cameraOverridesSettingKey: '''
[
  {
    "model": "Remote Custom Camera",
    "aliases": ["RemoteCam"],
    "pixelSizeMicrons": 4.2,
    "qePeak": 0.7,
    "defaultGain": 10,
    "gainPoints": [
      {"gain": 10, "readNoiseE": 2.0, "fullWellE": 42000}
    ]
  }
]
''',
        },
      );
      when(
        () => backend.fetchGuideRmsHistory(mountId: 'remote-mount', limit: 20),
      ).thenAnswer(
        (_) async => RemotePage(
          items: [
            RemoteGuideRmsHistoryEntry(
              id: 1,
              mountId: 'remote-mount',
              totalRmsArcsec: 0.8,
              sampleCount: 100,
              recordedAt: DateTime.now().subtract(const Duration(days: 2)),
            ),
            RemoteGuideRmsHistoryEntry(
              id: 2,
              mountId: 'remote-mount',
              totalRmsArcsec: 1.2,
              sampleCount: 80,
              recordedAt: DateTime.now().subtract(const Duration(days: 40)),
            ),
          ],
          total: 2,
        ),
      );

      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
          _initialSettingsProvider.overrideWithValue(
            const AppSettingsState(
              smartNightSubExposureFloorSecs: 30,
              smartNightSubExposureCeilingSecs: 300,
              smartNightTargetSnr: 35,
            ),
          ),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(
              name: 'Remote rig',
              cameraName: 'RemoteCam',
              mountId: 'remote-mount',
              focalLength: 500,
              aperture: 100,
              defaultGain: 10,
              filterNames: ['L'],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final context = await container.read(
        smartNightExposureContextProvider.future,
      );

      expect(context, isNotNull);
      // The host's camera override names this camera at this gain, so it wins
      // over `science.camera.read_noise_e`: that key is auto-written FROM the
      // sensor-spec chain unless the user freezes it, and reading it back as
      // an override would be circular. The next test freezes it.
      expect(context!.camera.readNoiseE, 2.0);
      expect(context.camera.fullWellE, 42000);
      expect(context.camera.qePeak, 0.7);
      expect(context.pixelSizeMicrons, 4.2);
      // The global `smart_night.camera.*` keys the host also returns are
      // outranked by the per-camera override for the same reason.
      expect(context.gloverKFactor, 14);
      expect(context.guideSampleCount, 2);
      expect(context.guideRmsArcsec, closeTo(0.9333, 0.0001));
      verify(backend.getScienceSettings).called(1);
      verify(backend.getSmartNightSettings).called(1);
      verify(
        () => backend.fetchGuideRmsHistory(mountId: 'remote-mount', limit: 20),
      ).called(1);
    },
  );

  test(
    'Smart Night exposure context uses dedicated Smart Night settings',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      await db.settingsDao.setSettings({
        'smart_night.sub_ceiling_seconds': '111',
        'smart_night.sub_floor_seconds': '22',
        'smart_night.camera.full_well_e': '50000',
        'smart_night.camera.qe_peak': '0.85',
        'science.camera.read_noise_e': '1.4',
      });

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
          _initialSettingsProvider.overrideWithValue(
            const AppSettingsState(
              bortleClass: 8,
              adaptiveExposureTargetSnr: 7,
              smartNightSubExposureFloorSecs: 45,
              smartNightSubExposureCeilingSecs: 420,
              smartNightTargetSnr: 42,
            ),
          ),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(
              name: 'Shared exposure rig',
              focalLength: 384,
              aperture: 80,
              filterNames: ['L', 'Ha'],
            ),
          ),
        ],
      );

      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      final context = await container.read(
        smartNightExposureContextProvider.future,
      );

      expect(context, isNotNull);
      expect(context!.floorSeconds, 45);
      expect(context.userCapSeconds, 420);
      expect(context.targetSnr, 42);
    },
  );

  test(
    'Smart Night exposure context includes weighted recent guide RMS',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      await db.settingsDao.setSettings({
        'smart_night.camera.full_well_e': '50000',
        'smart_night.camera.qe_peak': '0.85',
        'science.camera.read_noise_e': '1.4',
      });
      final now = DateTime.now();
      await db.guideRmsHistoryDao.insertSample(
        GuideRmsHistoryCompanion.insert(
          sessionId: 'recent-1',
          mountId: 'mount-a',
          totalRmsArcsec: 1.0,
          sampleCount: 100,
          exposureSeconds: const Value(2.0),
          recordedAt: now.subtract(const Duration(days: 2)),
        ),
      );
      await db.guideRmsHistoryDao.insertSample(
        GuideRmsHistoryCompanion.insert(
          sessionId: 'recent-2',
          mountId: 'mount-a',
          totalRmsArcsec: 1.0,
          sampleCount: 120,
          exposureSeconds: const Value(2.0),
          recordedAt: now.subtract(const Duration(days: 10)),
        ),
      );
      await db.guideRmsHistoryDao.insertSample(
        GuideRmsHistoryCompanion.insert(
          sessionId: 'older',
          mountId: 'mount-a',
          totalRmsArcsec: 3.0,
          sampleCount: 80,
          exposureSeconds: const Value(2.0),
          recordedAt: now.subtract(const Duration(days: 45)),
        ),
      );

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
          _initialSettingsProvider.overrideWithValue(const AppSettingsState()),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(
              name: 'Guided rig',
              mountId: 'mount-a',
              focalLength: 600,
              aperture: 80,
              filterNames: ['L'],
            ),
          ),
        ],
      );

      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      final context = await container.read(
        smartNightExposureContextProvider.future,
      );

      expect(context, isNotNull);
      expect(context!.guideSampleCount, 3);
      expect(context.guideRmsArcsec, closeTo(1.4, 0.0001));
    },
  );

  test(
    'Smart Night exposure context uses camera hardware specs by profile',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
          _initialSettingsProvider.overrideWithValue(const AppSettingsState()),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(
              name: 'Known camera rig',
              cameraName: 'ASI2600MM',
              focalLength: 530,
              aperture: 106,
              defaultGain: 100,
              filterNames: ['L'],
            ),
          ),
        ],
      );

      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      final context = await container.read(
        smartNightExposureContextProvider.future,
      );

      expect(context, isNotNull);
      // ZWO's ASI2600 manual (Rev 1.3) publishes read noise as a 1.0-3.3e
      // range with no per-gain attribution, full well as 50ke, and the mono
      // QE peak as 91%. The high end of the read-noise range is the figure
      // that does not flatter the camera, so that is what planning uses; the
      // superseded built-in catalog claimed an unsourced 1.5e / 18,700e at
      // gain 100.
      expect(context!.camera.readNoiseE, closeTo(3.3, 0.001));
      expect(context.camera.fullWellE, closeTo(50000, 0.001));
      expect(context.camera.qePeak, closeTo(0.91, 0.001));
      expect(context.pixelSizeMicrons, closeTo(3.76, 0.001));
      expect(context.caveats, isEmpty);
    },
  );

  test('a frozen science read noise wins over the published figure', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    // `science.camera.read_noise_e` is auto-written from the sensor-spec
    // chain, so it only counts as the user's own value once they have frozen
    // it by editing the field.
    await db.settingsDao.setSettings({
      'science.camera.auto_managed': 'false',
      'science.camera.read_noise_e': '1.15',
    });

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
        _initialSettingsProvider.overrideWithValue(const AppSettingsState()),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            name: 'Measured rig',
            cameraName: 'ASI2600MM Pro',
            focalLength: 530,
            aperture: 106,
            defaultGain: 100,
            filterNames: ['L'],
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final context = await container.read(
      smartNightExposureContextProvider.future,
    );
    expect(context!.camera.readNoiseE, closeTo(1.15, 0.001));
    // Everything else still comes from the published specification.
    expect(context.camera.fullWellE, closeTo(50000, 0.001));
  });

  test('an unknown camera caveats every field and names the camera', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
        _initialSettingsProvider.overrideWithValue(const AppSettingsState()),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            name: 'Mystery rig',
            cameraName: 'Acme SkyCam 9000',
            focalLength: 500,
            aperture: 100,
            filterNames: ['L'],
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final context = await container.read(
      smartNightExposureContextProvider.future,
    );
    expect(context, isNotNull);
    expect(context!.caveats, hasLength(4));
    expect(context.caveats.every(isSensorSpecCaveat), isTrue);
    for (final caveat in context.caveats) {
      expect(caveat, contains('Acme SkyCam 9000'));
    }
    // The conservative stand-ins, each announced by its caveat.
    expect(context.pixelSizeMicrons, 3.76);
    expect(context.camera.readNoiseE, 3.5);
    expect(context.camera.fullWellE, 18000);
    expect(context.camera.qePeak, 0.65);
  });

  test('a correction saved after the first read reaches the planner', () async {
    // The chain is only useful if it notices. A one-shot settings read left
    // the Plan screen warning about a camera whose specs the user had just
    // typed into the dialog, because the settings map behind the chain was
    // already cached.
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
        _initialSettingsProvider.overrideWithValue(const AppSettingsState()),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            name: 'Mystery rig',
            cameraName: 'Acme SkyCam 9000',
            focalLength: 500,
            aperture: 100,
            defaultGain: 120,
            filterNames: ['L'],
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    // A live listener, as a screen watching the provider would be: without
    // one Riverpod has no reason to keep the settings stream subscribed.
    final subscription = container.listen(
      smartNightExposureContextProvider,
      (_, __) {},
    );
    addTearDown(subscription.close);

    final before = await container.read(
      smartNightExposureContextProvider.future,
    );
    expect(before!.caveats, hasLength(4), reason: 'precondition: unknown');

    await db.settingsDao.setSetting(
      HardwareSpecsService.cameraOverridesSettingKey,
      '[{"model":"Acme SkyCam 9000","aliases":[],"pixelSizeMicrons":4.63,'
      '"qePeak":0.75,"defaultGain":120,"gainPoints":'
      '[{"gain":120,"readNoiseE":2.1,"fullWellE":42000.0}],'
      '"sensorWidthPx":4144,"sensorHeightPx":2822}]',
    );

    // No invalidation anywhere: the write reaches the planner through the
    // settings table's own stream, which takes a few event-loop turns.
    var after = before;
    for (
      var attempt = 0;
      attempt < 100 && after.caveats.isNotEmpty;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      after = (await container.read(smartNightExposureContextProvider.future))!;
    }
    expect(after.caveats, isEmpty);
    expect(after.pixelSizeMicrons, 4.63);
    expect(after.camera.readNoiseE, 2.1);
    expect(after.camera.fullWellE, 42000);
    expect(after.camera.qePeak, 0.75);
  });

  test('a malformed override blob is reported, not silently ignored', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    await db.settingsDao.setSetting(
      HardwareSpecsService.cameraOverridesSettingKey,
      '{not json at all',
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
        _initialSettingsProvider.overrideWithValue(const AppSettingsState()),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            name: 'Corrupt override rig',
            cameraName: 'ASI1600MM-Cool',
            focalLength: 500,
            aperture: 100,
            defaultGain: 139,
            filterNames: ['L'],
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final context = await container.read(
      smartNightExposureContextProvider.future,
    );
    expect(context!.caveats, [unreadableSensorOverridesCaveat]);
    // The published figures still get used underneath.
    expect(context.pixelSizeMicrons, 3.8);
    expect(context.camera.readNoiseE, 1.2);
  });

  test(
    'Smart Night exposure context uses user camera hardware overrides',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      await db.settingsDao.setSetting(
        HardwareSpecsService.cameraOverridesSettingKey,
        '''
[
  {
    "model": "Mystery Camera 42",
    "aliases": ["MysteryCam"],
    "pixelSizeMicrons": 4.63,
    "qePeak": 0.72,
    "defaultGain": 10,
    "gainPoints": [
      {"gain": 10, "readNoiseE": 2.1, "fullWellE": 42000}
    ]
  }
]
''',
      );

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
          _initialSettingsProvider.overrideWithValue(const AppSettingsState()),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(
              name: 'Override camera rig',
              cameraName: 'MysteryCam',
              focalLength: 500,
              aperture: 90,
              defaultGain: 10,
              filterNames: ['L'],
            ),
          ),
        ],
      );

      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      final context = await container.read(
        smartNightExposureContextProvider.future,
      );

      expect(context, isNotNull);
      expect(context!.camera.readNoiseE, closeTo(2.1, 0.001));
      expect(context.camera.fullWellE, closeTo(42000, 0.001));
      expect(context.camera.qePeak, closeTo(0.72, 0.001));
      expect(context.pixelSizeMicrons, closeTo(4.63, 0.001));
    },
  );
}
