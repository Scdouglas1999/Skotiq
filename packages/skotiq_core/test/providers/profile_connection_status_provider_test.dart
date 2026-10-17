import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';

void main() {
  group('profileConnectionStatusProvider', () {
    late ProviderContainer container;
    late SkotiqDatabase database;

    setUp(() {
      // Equipment state observes settings/profile streams even when this test
      // assigns snapshots directly. Never open a shared on-disk user database.
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    EquipmentProfileModel profile({
      String? cameraId,
      String? mountId,
      String? focuserId,
      String? filterWheelId,
      String? guiderId,
      String? rotatorId,
    }) {
      return EquipmentProfileModel(
        id: 1,
        name: 'Test Profile',
        cameraId: cameraId,
        mountId: mountId,
        focuserId: focuserId,
        filterWheelId: filterWheelId,
        guiderId: guiderId,
        rotatorId: rotatorId,
      );
    }

    test('unassigned + nothing-connected profile has empty rollups', () {
      final status = container.read(profileConnectionStatusProvider(profile()));

      expect(status.coreTotalCount, 0);
      expect(status.coreConnectedCount, 0);
      expect(status.hasConnectedCore, isFalse);
      expect(status.hasDisconnectedCore, isFalse);
      expect(status.hasMismatch, isFalse);
      expect(status.mismatchedDeviceNames, isEmpty);
    });

    test('a connected matching device rolls up into the counts', () {
      container
          .read(cameraStateProvider.notifier)
          .state = const CameraStateSnapshot(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'native:zwo:asi2600:0',
      );

      final status = container.read(
        profileConnectionStatusProvider(
          profile(cameraId: 'native:zwo:asi2600:0'),
        ),
      );

      expect(status.coreTotalCount, 1);
      expect(status.coreConnectedCount, 1);
      expect(status.hasConnectedCore, isTrue);
      expect(status.hasDisconnectedCore, isFalse);
      expect(
        status[ProfileDeviceSlot.camera].profileState,
        DeviceConnectionState.connected,
      );
      expect(status.hasMismatch, isFalse);
    });

    test('PHD2 guider counts via canonical id (5/5 with all connected)', () {
      // Camera, mount, focuser, filter wheel, rotator connected with matching
      // ids; the guider is connected as the canonical 'phd2_guider' while the
      // profile recorded it as the bare 'phd2' alias. The canonical matcher
      // must collapse them so the guider counts — yielding 5/5 across the five
      // assigned core slots used here.
      container
          .read(cameraStateProvider.notifier)
          .state = const CameraStateSnapshot(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'native:zwo:asi2600:0',
      );
      container.read(mountStateProvider.notifier).state = const MountState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'ascom:EQMOD.Telescope',
      );
      container.read(focuserStateProvider.notifier).state = const FocuserState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'native:zwo_eaf:0',
      );
      container
          .read(filterWheelStateProvider.notifier)
          .state = const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'native:zwo_efw:0',
      );
      container.read(guiderStateProvider.notifier).state = const GuiderState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'phd2_guider',
      );

      final status = container.read(
        profileConnectionStatusProvider(
          profile(
            cameraId: 'native:zwo:asi2600:0',
            mountId: 'ascom:EQMOD.Telescope',
            focuserId: 'native:zwo_eaf:0',
            filterWheelId: 'native:zwo_efw:0',
            guiderId: 'phd2', // bare alias; must collapse to phd2_guider
          ),
        ),
      );

      expect(status.coreTotalCount, 5);
      expect(status.coreConnectedCount, 5);
      expect(status[ProfileDeviceSlot.guider].matchesProfile, isTrue);
      expect(
        status[ProfileDeviceSlot.guider].profileState,
        DeviceConnectionState.connected,
      );
      // The same PHD2 guider under different representations is NOT a mismatch.
      expect(status.hasMismatch, isFalse);
    });

    test('a different connected device is flagged as a mismatch', () {
      container
          .read(cameraStateProvider.notifier)
          .state = const CameraStateSnapshot(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'native:qhy:268m:0',
      );

      final status = container.read(
        profileConnectionStatusProvider(
          profile(cameraId: 'native:zwo:asi2600:0'),
        ),
      );

      // Banner rule: both ids non-empty and differ -> mismatch.
      expect(status.hasMismatch, isTrue);
      expect(status.mismatchedDeviceNames, ['Camera']);
      // And it does NOT count as connected for this profile.
      expect(status.coreConnectedCount, 0);
      expect(status.coreTotalCount, 1);
      expect(status.hasDisconnectedCore, isTrue);
    });

    test(
      'connected-but-unmatched still offers Connect All (disconnected core)',
      () {
        // Profile assigns a camera, but a *different* camera is connected.
        container
            .read(cameraStateProvider.notifier)
            .state = const CameraStateSnapshot(
          connectionState: DeviceConnectionState.connected,
          deviceId: 'native:qhy:268m:0',
        );

        final status = container.read(
          profileConnectionStatusProvider(
            profile(cameraId: 'native:zwo:asi2600:0'),
          ),
        );

        expect(status.hasConnectedCore, isFalse);
        expect(status.hasDisconnectedCore, isTrue);
      },
    );

    test('mismatch list preserves declaration order across slots', () {
      container.read(mountStateProvider.notifier).state = const MountState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'ascom:Other.Mount',
      );
      container
          .read(cameraStateProvider.notifier)
          .state = const CameraStateSnapshot(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'native:qhy:268m:0',
      );

      final status = container.read(
        profileConnectionStatusProvider(
          profile(
            cameraId: 'native:zwo:asi2600:0',
            mountId: 'ascom:EQMOD.Telescope',
          ),
        ),
      );

      // Camera precedes Mount in ProfileDeviceSlot declaration order.
      expect(status.mismatchedDeviceNames, ['Camera', 'Mount']);
    });

    test('an unassigned slot with a connected device is not a mismatch', () {
      // Connected camera, but the profile assigns no camera. The banner rule
      // requires BOTH ids non-empty, so this is not flagged.
      container
          .read(cameraStateProvider.notifier)
          .state = const CameraStateSnapshot(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'native:zwo:asi2600:0',
      );

      final status = container.read(profileConnectionStatusProvider(profile()));

      expect(status.hasMismatch, isFalse);
      expect(status.coreTotalCount, 0);
    });
  });
}
