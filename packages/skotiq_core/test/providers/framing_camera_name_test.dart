// With the camera unplugged and no camera name in the profile, Framing names
// the camera from its id the way the rest of the app does: `native:zwo:0` is
// "ZWO #1", not "NATIVE #0".

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';

import '../mocks/mock_backend.dart';

const _cameraId = 'native:zwo:0';

const _status = CameraStatus(
  connected: true,
  state: CameraState.idle,
  coolerOn: false,
  gain: 100,
  offset: 10,
  binX: 1,
  binY: 1,
  sensorWidth: 4144,
  sensorHeight: 2822,
  pixelSizeX: 4.63,
  pixelSizeY: 4.63,
  maxAdu: 65535,
  canCool: true,
  canSetGain: true,
  canSetOffset: true,
);

const _profile = EquipmentProfileModel(
  id: 1,
  name: 'Rig',
  isActive: true,
  cameraId: _cameraId,
  focalLength: 530,
  aperture: 106,
);

void main() {
  setUpAll(registerMocktailFallbackValues);

  test(
    'an unplugged camera is named from its id like everywhere else',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      ProviderContainer container({required bool connected}) {
        final backend = MockBackend();
        if (connected) {
          when(
            () => backend.getCameraStatus(any()),
          ).thenAnswer((_) async => _status);
        } else {
          when(
            () => backend.getCameraStatus(any()),
          ).thenThrow(StateError('camera is not connected'));
        }
        final c = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            backendProvider.overrideWith((ref) => _FixedBackend(ref, backend)),
            activeEquipmentProfileProvider.overrideWithValue(_profile),
            cameraStateProvider.overrideWith((ref) {
              final camera = CameraStateNotifier(ref)
                ..setConnecting(_cameraId, 'ZWO ASI294MM Pro');
              if (connected) camera.setConnected();
              return camera;
            }),
          ],
        );
        addTearDown(c.dispose);
        return c;
      }

      // Seen once while connected, so the sensor size is remembered.
      final live = await container(
        connected: true,
      ).read(framingFOVProvider.future);
      expect(live.isReady, isTrue, reason: 'precondition');

      final offline = await container(
        connected: false,
      ).read(framingFOVProvider.future);
      expect(offline.isReady, isTrue, reason: 'precondition');
      expect(offline.equipment!.cameraName, formatDeviceId(_cameraId));
      expect(offline.equipment!.cameraName, 'ZWO #1');
    },
  );
}

class _FixedBackend extends BackendNotifier {
  _FixedBackend(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
