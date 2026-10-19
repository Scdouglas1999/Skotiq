import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/harness.dart';

const _mountId = 'simulator:mount:0';

class _MountNotifier extends MountStateNotifier {
  _MountNotifier(super.ref, {bool slewing = false}) {
    // ignore: invalid_use_of_protected_member
    state = MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _mountId,
      deviceName: 'Simulated Mount',
      isTracking: true,
      isSlewing: slewing,
    );
  }
}

/// Set park stores the park position through the backend and never parks,
/// and is refused for a driver that cannot set park or a moving mount.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<HarnessHandle> pump(
    WidgetTester tester,
    MockBackend backend, {
    bool canSetPark = true,
    bool slewing = false,
  }) {
    when(() => backend.getMountCapabilities(_mountId)).thenAnswer(
      (_) async => MountCapabilities(canSetPark: canSetPark, canPark: true),
    );
    when(() => backend.mountSetPark(_mountId)).thenAnswer((_) async {});
    return pumpAppScreen(
      tester,
      const SizedBox.shrink(),
      backend: backend,
      extraOverrides: [
        mountStateProvider.overrideWith(
          (ref) => _MountNotifier(ref, slewing: slewing),
        ),
      ],
    );
  }

  testWidgets('stores the park position without parking', (tester) async {
    final backend = mockBackend();
    final handle = await pump(tester, backend);

    final result =
        await handle.container.read(mountCommandServiceProvider).setParkHere();

    expect(result.isSuccess, isTrue, reason: result.message);
    verify(() => backend.mountSetPark(_mountId)).called(1);
    verifyNever(() => backend.mountPark(_mountId));
  });

  testWidgets('a driver that cannot set park is refused', (tester) async {
    final backend = mockBackend();
    final handle = await pump(tester, backend, canSetPark: false);

    final result =
        await handle.container.read(mountCommandServiceProvider).setParkHere();

    expect(result.isSuccess, isFalse);
    expect(result.message, contains('cannot store a park position'));
    verifyNever(() => backend.mountSetPark(_mountId));
  });

  testWidgets('a moving mount is refused', (tester) async {
    final backend = mockBackend();
    final handle = await pump(tester, backend, slewing: true);

    final result =
        await handle.container.read(mountCommandServiceProvider).setParkHere();

    expect(result.isSuccess, isFalse);
    expect(result.message, contains('stop moving'));
    verifyNever(() => backend.mountSetPark(_mountId));
  });
}
