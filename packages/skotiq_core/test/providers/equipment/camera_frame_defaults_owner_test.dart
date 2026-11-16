// The device layer is told the active profile's gain, offset and read mode
// for the connected camera, so a frame that names none (a run's centering
// and autofocus frames) is taken at the profile's values, never at what a
// manual frame left on the camera.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

const _camera = 'native:zwo:1';

const _gainCamera = CameraCapabilities(
  maxWidth: 4656,
  maxHeight: 3520,
  bitDepth: 12,
  canSetGain: true,
  canSetOffset: true,
);

void main() {
  late List<(String, CameraFrameDefaults)> stated;
  late StateController<EquipmentProfileModel?> profile;

  ProviderContainer connect(CameraCapabilities? capabilities) {
    final container = ProviderContainer(
      overrides: [
        activeEquipmentProfileProvider.overrideWith(
          (ref) => ref.watch(_profile),
        ),
        cameraCapabilitiesProvider(
          _camera,
        ).overrideWith((ref) async => capabilities),
      ],
    );
    addTearDown(container.dispose);
    profile = container.read(_profile.notifier);
    container.read(
      Provider((ref) {
        final owner = CameraFrameDefaultsOwner(
          ref: ref,
          state: (id, defaults) => stated.add((id, defaults)),
        );
        ref.onDispose(owner.dispose);
        return owner;
      }),
    );
    container.read(cameraStateProvider.notifier)
      ..setConnecting(_camera, 'ZWO ASI1600MM Pro')
      ..setConnected();
    return container;
  }

  Future<void> settle(ProviderContainer container) async {
    await container.read(cameraCapabilitiesProvider(_camera).future);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() => stated = []);

  test(
    'a gain camera is stated the profile gain, offset and read mode',
    () async {
      final container = connect(_gainCamera);
      await settle(container);
      expect(stated.last, (
        _camera,
        (gain: 139, offset: 21, readoutMode: 'Normal'),
      ));
    },
  );

  test('a profile edit is stated again at once', () async {
    final container = connect(_gainCamera);
    await settle(container);
    profile.state = profile.state!.copyWith(defaultGain: 76, defaultOffset: 15);
    await Future<void>.delayed(Duration.zero);
    container.read(cameraFrameDefaultsProvider);
    expect(stated.last, (
      _camera,
      (gain: 76, offset: 15, readoutMode: 'Normal'),
    ));
  });

  test('a DSLR keeps its ISO and is stated no offset', () async {
    final container = connect(
      const CameraCapabilities(
        maxWidth: 5472,
        maxHeight: 3648,
        bitDepth: 14,
        canSetGain: true,
        isoSpeeds: [100, 200, 400, 800, 1600],
      ),
    );
    await settle(container);
    expect(stated.last.$2, (gain: null, offset: null, readoutMode: 'Normal'));
  });

  test('a fixed-gain camera is stated neither gain nor offset', () async {
    final container = connect(
      const CameraCapabilities(
        maxWidth: 1920,
        maxHeight: 1080,
        bitDepth: 16,
        canSetGain: false,
        canSetOffset: false,
      ),
    );
    await settle(container);
    expect(stated.last.$2, (gain: null, offset: null, readoutMode: 'Normal'));
  });

  test('unknown capabilities state no gain or offset', () async {
    final container = connect(null);
    await settle(container);
    expect(stated.last.$2, (gain: null, offset: null, readoutMode: 'Normal'));
  });

  test('nothing is stated with no camera connected', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(cameraFrameDefaultsProvider), isNull);
  });
}

final _profile = StateProvider<EquipmentProfileModel?>(
  (ref) => const EquipmentProfileModel(
    id: 10,
    name: '10" Newt',
    defaultGain: 139,
    defaultOffset: 21,
    defaultReadoutMode: 'Normal',
  ),
);
