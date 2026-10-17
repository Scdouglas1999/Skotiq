import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/harness.dart';

const _mountId = 'simulator:mount:0';

class _ConnectedMountNotifier extends MountStateNotifier {
  _ConnectedMountNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _mountId,
      deviceName: 'Simulated Mount',
      isParked: false,
      isTracking: true,
    );
  }
}

class _SwitchableBackendNotifier extends BackendNotifier {
  _SwitchableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

Future<HarnessHandle> _pump(
  WidgetTester tester,
  MockBackend backend,
) =>
    pumpAppScreen(
      tester,
      const SizedBox.shrink(),
      backend: backend,
      extraOverrides: [
        mountStateProvider.overrideWith(_ConnectedMountNotifier.new),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('slew is rejected when the mount reports no GoTo support',
      (tester) async {
    final backend = mockBackend();
    when(() => backend.getMountCapabilities(_mountId)).thenAnswer(
      (_) async => const MountCapabilities(),
    );
    final handle = await _pump(tester, backend);

    final result = await handle.container
        .read(mountCommandServiceProvider)
        .slewTo(5.5, -20.25);

    expect(result.isSuccess, isFalse);
    expect(result.message, contains('GoTo slewing is unsupported'));
    verifyNever(
      () => backend.mountSlewToCoordinates(_mountId, 5.5, -20.25),
    );
  });

  testWidgets('unknown capabilities fail closed before a slew', (tester) async {
    final backend = mockBackend();
    when(
      () => backend.getMountCapabilities(_mountId),
    ).thenAnswer((_) async => null);
    final handle = await _pump(tester, backend);

    final result = await handle.container
        .read(mountCommandServiceProvider)
        .slewTo(5.5, -20.25);

    expect(result.isSuccess, isFalse);
    expect(result.message, contains('capabilities are unavailable'));
    verifyNever(
      () => backend.mountSlewToCoordinates(_mountId, 5.5, -20.25),
    );
  });

  testWidgets('capability transport errors fail closed before a command', (
    tester,
  ) async {
    final backend = mockBackend();
    when(
      () => backend.getMountCapabilities(_mountId),
    ).thenThrow(Exception('host unavailable'));
    final handle = await _pump(tester, backend);

    final result = await handle.container
        .read(mountCommandServiceProvider)
        .setTracking(false);

    expect(result.isSuccess, isFalse);
    expect(result.message, contains('host unavailable'));
    verifyNever(() => backend.mountSetTracking(_mountId, false));
  });

  testWidgets('abort slew is capability-gated', (tester) async {
    final backend = mockBackend();
    when(
      () => backend.getMountCapabilities(_mountId),
    ).thenAnswer((_) async => const MountCapabilities(canAbortSlew: false));
    final handle = await _pump(tester, backend);

    final result =
        await handle.container.read(mountCommandServiceProvider).abortSlew();

    expect(result.isSuccess, isFalse);
    expect(result.message, contains('aborting a slew is unsupported'));
    verifyNever(() => backend.mountAbort(_mountId));
  });

  testWidgets('a mount disconnect during capability lookup cancels the command',
      (tester) async {
    final backend = mockBackend();
    final capabilities = Completer<MountCapabilities?>();
    when(() => backend.getMountCapabilities(_mountId))
        .thenAnswer((_) => capabilities.future);
    final handle = await _pump(tester, backend);
    final service = handle.container.read(mountCommandServiceProvider);

    final command = service.sync(5.5, -20.25);
    await tester.pump();
    handle.container.read(mountStateProvider.notifier).setDisconnected();
    capabilities.complete(const MountCapabilities(canSync: true));

    final result = await command;
    expect(result.isSuccess, isFalse);
    expect(result.message, contains('connection changed'));
    verifyNever(() => backend.mountSync(_mountId, 5.5, -20.25));
  });

  testWidgets('ordinary mount commands do not overlap', (tester) async {
    final backend = mockBackend();
    final capabilities = Completer<MountCapabilities?>();
    when(() => backend.getMountCapabilities(_mountId))
        .thenAnswer((_) => capabilities.future);
    when(() => backend.mountSetTracking(_mountId, false))
        .thenAnswer((_) async {});
    final handle = await _pump(tester, backend);
    final service = handle.container.read(mountCommandServiceProvider);

    final first = service.setTracking(false);
    await tester.pump();
    final overlapping = await service.sync(5.5, -20.25);

    expect(overlapping.isSuccess, isFalse);
    expect(overlapping.message, contains('already in progress'));

    capabilities.complete(const MountCapabilities(canSetTracking: true));
    expect((await first).isSuccess, isTrue);
    verify(() => backend.mountSetTracking(_mountId, false)).called(1);
    verifyNever(() => backend.mountSync(_mountId, 5.5, -20.25));
  });

  testWidgets('same-id host switch cannot retarget an admitted command',
      (tester) async {
    final backendA = mockBackend();
    final backendB = mockBackend();
    final capabilities = Completer<MountCapabilities?>();
    when(() => backendA.getMountCapabilities(_mountId))
        .thenAnswer((_) => capabilities.future);
    late _SwitchableBackendNotifier backendNotifier;
    final handle = await pumpAppScreen(
      tester,
      const SizedBox.shrink(),
      backend: backendA,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => backendNotifier = _SwitchableBackendNotifier(ref, backendA),
        ),
        mountStateProvider.overrideWith(_ConnectedMountNotifier.new),
      ],
    );

    final serviceA = handle.container.read(mountCommandServiceProvider);
    final command = serviceA.setTracking(false);
    await tester.pump();

    backendNotifier.replaceBackend(backendB);
    final serviceB = handle.container.read(mountCommandServiceProvider);
    expect(serviceB, isNot(same(serviceA)));

    capabilities.complete(
      const MountCapabilities(canSetTracking: true),
    );
    final result = await command;

    expect(result.isSuccess, isFalse);
    expect(result.message, contains('connection changed'));
    verifyNever(() => backendA.mountSetTracking(_mountId, false));
    verifyNever(() => backendB.mountSetTracking(_mountId, false));
  });

  testWidgets('tracking rate is rejected when the mount does not advertise it',
      (tester) async {
    final backend = mockBackend();
    when(() => backend.getMountCapabilities(_mountId)).thenAnswer(
      (_) async => const MountCapabilities(
        canSetTrackingRate: true,
        supportedTrackingRates: [TrackingRate.sidereal],
      ),
    );
    final handle = await _pump(tester, backend);

    final result = await handle.container
        .read(mountCommandServiceProvider)
        .setTrackingRate(TrackingRate.lunar);

    expect(result.isSuccess, isFalse);
    expect(
        result.message, contains('does not support the lunar tracking rate'));
    verifyNever(
      () => backend.mountSetTrackingRate(_mountId, TrackingRate.lunar.index),
    );
  });

  testWidgets(
      'supported tracking rate is sent through the guarded command path',
      (tester) async {
    final backend = mockBackend();
    when(() => backend.getMountCapabilities(_mountId)).thenAnswer(
      (_) async => const MountCapabilities(
        canSetTrackingRate: true,
        supportedTrackingRates: [
          TrackingRate.sidereal,
          TrackingRate.lunar,
        ],
      ),
    );
    when(
      () => backend.mountSetTrackingRate(_mountId, TrackingRate.lunar.index),
    ).thenAnswer((_) async {});
    final handle = await _pump(tester, backend);

    final result = await handle.container
        .read(mountCommandServiceProvider)
        .setTrackingRate(TrackingRate.lunar);

    expect(result.isSuccess, isTrue);
    verify(
      () => backend.mountSetTrackingRate(_mountId, TrackingRate.lunar.index),
    ).called(1);
  });

  testWidgets('backend-swap quiescing waits for an active mount command',
      (tester) async {
    final backend = mockBackend();
    final slewStarted = Completer<void>();
    final slewFinished = Completer<void>();
    when(() => backend.getMountCapabilities(_mountId)).thenAnswer(
      (_) async => const MountCapabilities(canSlew: true, canAbortSlew: true),
    );
    when(() => backend.mountSlewToCoordinates(_mountId, 5.5, -20.25))
        .thenAnswer((_) async {
      slewStarted.complete();
      await slewFinished.future;
    });
    final handle = await _pump(tester, backend);
    final command =
        handle.container.read(mountCommandServiceProvider).slewTo(5.5, -20.25);
    await slewStarted.future;

    var quiesced = false;
    final quiesce = handle.container
        .read(deviceServiceProvider)
        .prepareForBackendSwap()
        .then((_) => quiesced = true);
    await tester.pump();
    expect(quiesced, isFalse);

    slewFinished.complete();
    expect((await command).isSuccess, isTrue);
    await quiesce;
    expect(quiesced, isTrue);
  });
}
