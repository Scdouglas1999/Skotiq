import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Drives the test's stand-in for the active profile's optical configuration.
final _testOpticalConfig = StateProvider<OpticalConfig?>((ref) => null);

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      opticalConfigProvider.overrideWith(
        (ref) => ref.watch(_testOpticalConfig),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Lets the binding's deferred writes run (it defers to a microtask because
/// Riverpod forbids mutating another provider during initialisation).
Future<void> _settle() => Future<void>.delayed(Duration.zero);

const _fullRig = OpticalConfig(
  telescopeName: 'ED80',
  focalLength: 480,
  aperture: 80,
  cameraName: 'ASI2600MM',
  sensorWidth: 6248,
  sensorHeight: 4176,
  pixelSize: 3.76,
);

void main() {
  test(
    'seeds the planetarium overlay from the rig already connected',
    () async {
      final container = _container();
      container.read(_testOpticalConfig.notifier).state = _fullRig;

      // Nothing has touched the planetarium provider yet: this is the "open the
      // planetarium fresh and press F" state that used to draw nothing.
      expect(container.read(equipmentFOVProvider).fov, isNull);

      container.read(equipmentFovBindingProvider);
      await _settle();

      final fov = container.read(equipmentFOVProvider).fov;
      expect(fov, isNotNull);
      expect(fov!.$1, closeTo(_fullRig.fieldOfView!.$1, 1e-9));
      expect(fov.$2, closeTo(_fullRig.fieldOfView!.$2, 1e-9));
      expect(
        container.read(equipmentFOVProvider).imageScale,
        closeTo(_fullRig.imageScale!, 1e-9),
      );
    },
  );

  test('tracks a profile change instead of pinning the first rig', () async {
    final container = _container();
    container.read(_testOpticalConfig.notifier).state = _fullRig;
    container.read(equipmentFovBindingProvider);
    await _settle();

    container.read(_testOpticalConfig.notifier).state = _fullRig.copyWith(
      focalLength: 960,
    );
    await _settle();

    final fov = container.read(equipmentFOVProvider).fov!;
    // Doubling the focal length roughly halves the field.
    expect(fov.$1, closeTo(_fullRig.fieldOfView!.$1 / 2, 0.02));
  });

  test('clears the overlay when the rig stops being knowable', () async {
    final container = _container();
    container.read(_testOpticalConfig.notifier).state = _fullRig;
    container.read(equipmentFovBindingProvider);
    await _settle();
    expect(container.read(equipmentFOVProvider).fov, isNotNull);

    // Camera disconnects: the profile still knows the optics but nothing knows
    // the sensor, so the box must disappear rather than linger at its last
    // size.
    container.read(_testOpticalConfig.notifier).state = const OpticalConfig(
      telescopeName: 'ED80',
      focalLength: 480,
      aperture: 80,
    );
    await _settle();
    expect(container.read(equipmentFOVProvider).fov, isNull);
    expect(container.read(equipmentFOVProvider).telescope, isNotNull);

    // Profile deselected entirely.
    container.read(_testOpticalConfig.notifier).state = null;
    await _settle();
    expect(container.read(equipmentFOVProvider).fov, isNull);
    expect(container.read(equipmentFOVProvider).telescope, isNull);
    expect(container.read(equipmentFOVProvider).camera, isNull);
  });

  test('no profile at all is a no-op, not a crash or a bogus box', () async {
    final container = _container();

    container.read(equipmentFovBindingProvider);
    await _settle();

    final state = container.read(equipmentFOVProvider);
    expect(state.telescope, isNull);
    expect(state.camera, isNull);
    expect(state.fov, isNull);
  });

  test(
    'optics changes preserve the framing rotation the user dialled in',
    () async {
      final container = _container();
      container.read(equipmentFovBindingProvider);
      await _settle();

      container.read(equipmentFOVProvider.notifier).setRotation(42);
      container.read(_testOpticalConfig.notifier).state = _fullRig;
      await _settle();

      expect(container.read(equipmentFOVProvider).rotation, 42);
    },
  );
}
