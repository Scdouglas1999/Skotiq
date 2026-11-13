import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;

class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// A profile with every field set to something other than its default.
const _full = EquipmentProfileModel(
  name: 'Observatory rig',
  description: 'main scope',
  cameraId: 'ascom:camera:1',
  mountId: 'ascom:mount:1',
  focuserId: 'ascom:focuser:1',
  filterWheelId: 'ascom:wheel:1',
  guiderId: 'phd2:guider',
  guideCameraId: 'zwo:guide:1',
  guideFocalLength: 120,
  rotatorId: 'ascom:rotator:1',
  domeId: 'ascom:dome:1',
  weatherId: 'ascom:weather:1',
  safetyMonitorId: 'ascom:safety:1',
  switchId: 'ascom:switch:1',
  coverCalibratorId: 'ascom:flat:1',
  cameraName: 'ASI2600',
  mountName: 'EQ6',
  focuserName: 'EAF',
  filterWheelName: 'EFW',
  guiderName: 'PHD2',
  guideCameraName: 'ASI120',
  rotatorName: 'Falcon',
  safetyMonitorName: 'CloudWatcher',
  switchName: 'Pegasus UPB',
  telescopeName: 'Esprit 100',
  telescopeFocalLength: 550,
  telescopeAperture: 100,
  focalLength: 440,
  aperture: 100,
  focalRatio: 4.4,
  defaultGain: 100,
  defaultOffset: 30,
  defaultBinX: 2,
  defaultBinY: 2,
  defaultCoolingTemp: -10,
  coolOnConnect: true,
  defaultCenteringExposure: 3.5,
  filterNames: ['L', 'R', 'G', 'B'],
  filterFocusOffsets: {'L': 0, 'R': 12},
  meridianFlipOverrides: '{"minutesAfter":5}',
  profileIcon: '\u{1F52D}',
  profileColor: 0xFF3366FF,
  sortOrder: 4,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(
      const remote_profile.EquipmentProfile(id: '0', name: 'fallback'),
    );
  });

  group('on this host', () {
    late SkotiqDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final backend = _MockFfiBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(() => backend.saveProfile(any())).thenAnswer((_) async {});
      when(() => backend.loadProfile(any())).thenAnswer((_) async {});
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('a saved profile keeps every column the table has', () async {
      final notifier = container.read(equipmentProfilesProvider.notifier);
      await container.read(equipmentProfilesProvider.future);

      final id = await notifier.saveProfile(_full);
      final row = (await db.equipmentProfilesDao.getProfileById(id))!;

      // Columns a save does not write: the store sets them.
      final storeOwned = {
        db.equipmentProfiles.id.name,
        db.equipmentProfiles.isDefault.name,
        db.equipmentProfiles.isActive.name,
        db.equipmentProfiles.sortOrder.name,
        db.equipmentProfiles.createdAt.name,
        db.equipmentProfiles.updatedAt.name,
      };
      final written = _full.toCompanion().toColumns(false);
      final readBack = EquipmentProfileModel.fromDatabase(
        row,
      ).toCompanion().toColumns(false);
      for (final column in db.equipmentProfiles.$columns) {
        if (storeOwned.contains(column.name)) continue;
        expect(
          written.containsKey(column.name),
          isTrue,
          reason: 'the profile model does not write ${column.name}',
        );
        expect(
          readBack[column.name],
          written[column.name],
          reason: '${column.name} did not survive the save',
        );
      }
    });

    test('a save changes only the fields the caller changed', () async {
      final notifier = container.read(equipmentProfilesProvider.notifier);
      await container.read(equipmentProfilesProvider.future);
      final id = await notifier.saveProfile(_full);
      final loaded = (await container.read(
        equipmentProfilesProvider.future,
      )).profiles.singleWhere((profile) => profile.id == id);

      // Another screen writes a field this caller's copy also holds.
      await db.equipmentProfilesDao.updateProfileColumns(id, {
        db.equipmentProfiles.meridianFlipOverrides.name: const Variable(
          '{"minutesAfter":9}',
        ),
      });

      await notifier.saveProfile(loaded.copyWith(defaultGain: 200));

      final row = (await db.equipmentProfilesDao.getProfileById(id))!;
      expect(row.defaultGain, 200);
      expect(row.meridianFlipOverrides, '{"minutesAfter":9}');
      expect(row.telescopeName, 'Esprit 100');
    });

    test('a save that turns Default off clears the startup profile', () async {
      final notifier = container.read(equipmentProfilesProvider.notifier);
      await container.read(equipmentProfilesProvider.future);
      final id = await notifier.saveProfile(_full);
      final loaded = (await container.read(
        equipmentProfilesProvider.future,
      )).profiles.singleWhere((profile) => profile.id == id);
      expect(loaded.isDefault, isTrue, reason: 'the first profile is default');

      await notifier.saveProfile(loaded.copyWith(isDefault: false));

      expect(await db.equipmentProfilesDao.getDefaultProfile(), isNull);
    });
  });

  group('on a linked host', () {
    test('a save that turns Default off clears the host\'s startup '
        'profile', () async {
      const hosted = remote_profile.EquipmentProfile(
        id: '7',
        name: 'Remote Rig',
        isActive: true,
        isDefault: true,
      );
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(() => backend.getProfiles()).thenAnswer((_) async => [hosted]);
      when(() => backend.getActiveProfile()).thenAnswer((_) async => hosted);
      when(
        () => backend.saveProfileFields(any(), fields: any(named: 'fields')),
      ).thenAnswer((_) async {});
      when(() => backend.lastSavedProfileId).thenReturn('7');
      when(() => backend.clearDefaultProfileRemote()).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(
            SkotiqDatabase.forTesting(NativeDatabase.memory()),
          ),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      final loaded = (await container.read(
        equipmentProfilesProvider.future,
      )).profiles.single;
      await container
          .read(equipmentProfilesProvider.notifier)
          .saveProfile(loaded.copyWith(isDefault: false));

      verify(() => backend.clearDefaultProfileRemote()).called(1);
      verifyNever(() => backend.setDefaultProfileRemote(any()));
    });
  });
}
