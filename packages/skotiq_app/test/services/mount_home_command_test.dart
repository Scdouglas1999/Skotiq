import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/harness.dart';

const _mountId = 'simulator:mount:0';

class _MountNotifier extends MountStateNotifier {
  _MountNotifier(super.ref, {bool parked = false}) {
    // ignore: invalid_use_of_protected_member
    state = MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _mountId,
      deviceName: 'Simulated Mount',
      isParked: parked,
      isTracking: true,
    );
  }
}

/// Elapsed time that moves only when the watcher waits, so the 15 s motion
/// window and the 5 min completion timeout run instantly and in order.
class _FakeStopwatch implements Stopwatch {
  Duration now = Duration.zero;

  @override
  Duration get elapsed => now;

  @override
  void start() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MountStatus _status({
  bool slewing = false,
  bool atHome = false,
  double ra = 5.0,
  double dec = 20.0,
  bool atHomeSupported = true,
}) =>
    MountStatus(
      connected: true,
      tracking: false,
      slewing: slewing,
      parked: false,
      atHome: atHome,
      sideOfPier: PierSide.west,
      rightAscension: ra,
      declination: dec,
      trackingRate: TrackingRate.sidereal,
      canPark: true,
      canSlew: true,
      canSync: true,
      canPulseGuide: true,
      canSetTrackingRate: true,
      availability: {'at_home': atHomeSupported ? 'available' : 'unsupported'},
    );

/// Pump the app with a connected mount and a home watcher on a fake clock.
/// The backend answers status reads from [statuses] in order, repeating the
/// last one.
Future<HarnessHandle> _pump(
  WidgetTester tester,
  MockBackend backend, {
  required List<MountStatus> statuses,
  bool parked = false,
}) {
  var index = 0;
  when(() => backend.getMountStatus(_mountId)).thenAnswer((_) async {
    final status = statuses[index];
    if (index < statuses.length - 1) index++;
    return status;
  });
  when(() => backend.mountFindHome(_mountId)).thenAnswer((_) async {});
  when(() => backend.mountAbort(_mountId)).thenAnswer((_) async {});
  return pumpAppScreen(
    tester,
    const SizedBox.shrink(),
    backend: backend,
    extraOverrides: [
      mountStateProvider.overrideWith(
        (ref) => _MountNotifier(ref, parked: parked),
      ),
      mountHomeWatcherFactoryProvider.overrideWithValue(({
        required readStatus,
        isCancelled,
      }) {
        final clock = _FakeStopwatch();
        return MountHomeWatcher(
          readStatus: readStatus,
          isCancelled: isCancelled,
          delay: (d) async => clock.now += d,
          stopwatch: () => clock,
        );
      }),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MockBackend homeCapableBackend() {
    final backend = mockBackend();
    when(() => backend.getMountCapabilities(_mountId)).thenAnswer(
      (_) async => const MountCapabilities(
        canFindHome: true,
        canPark: true,
        canAbortSlew: true,
      ),
    );
    return backend;
  }

  testWidgets('a home the driver confirms reports the mount at home', (
    tester,
  ) async {
    final backend = homeCapableBackend();
    final handle = await _pump(
      tester,
      backend,
      statuses: [
        _status(),
        _status(slewing: true, dec: 50),
        _status(atHome: true, dec: 90),
      ],
    );

    final result =
        await handle.container.read(mountCommandServiceProvider).findHome();

    expect(result.isSuccess, isTrue, reason: result.message);
    expect(result.message, 'Mount is at home');
    verify(() => backend.mountFindHome(_mountId)).called(1);
    verifyNever(() => backend.mountPark(_mountId));
    verifyNever(() => backend.mountUnpark(_mountId));
    final mount = handle.container.read(mountStateProvider);
    expect(mount.isHoming, isFalse);
    expect(mount.homeUnconfirmed, isFalse);
    expect(mount.isParked, isFalse, reason: 'homing never parks');
  });

  testWidgets('a driver without AtHome gives an unconfirmed home', (
    tester,
  ) async {
    final backend = homeCapableBackend();
    final handle = await _pump(
      tester,
      backend,
      statuses: [
        _status(atHomeSupported: false),
        _status(slewing: true, dec: 50, atHomeSupported: false),
        _status(dec: 90, atHomeSupported: false),
      ],
    );

    final result =
        await handle.container.read(mountCommandServiceProvider).findHome();

    expect(result.isSuccess, isTrue, reason: result.message);
    expect(result.message, MountCommandService.homeUnconfirmedMessage);
    expect(handle.container.read(mountStateProvider).homeUnconfirmed, isTrue);
  });

  testWidgets('a driver that accepts Home but never moves is a failure', (
    tester,
  ) async {
    // The PegasusAstro NYX-101 case: FindHome returns, nothing moves.
    final backend = homeCapableBackend();
    final still = _status(dec: 8.01, atHomeSupported: false);
    final handle = await _pump(tester, backend, statuses: [still]);

    final result =
        await handle.container.read(mountCommandServiceProvider).findHome();

    expect(result.isSuccess, isFalse);
    expect(result.message, MountHomeWatcher.didNotMoveMessage);
    verify(() => backend.mountAbort(_mountId)).called(1);
    expect(handle.container.read(mountStateProvider).isHoming, isFalse);
  });

  testWidgets('a parked mount is refused and never unparked', (tester) async {
    final backend = homeCapableBackend();
    final handle = await _pump(
      tester,
      backend,
      statuses: [_status()],
      parked: true,
    );

    final result =
        await handle.container.read(mountCommandServiceProvider).findHome();

    expect(result.isSuccess, isFalse);
    expect(result.message, MountCommandService.homeWhileParkedMessage);
    verifyNever(() => backend.mountFindHome(_mountId));
    verifyNever(() => backend.mountUnpark(_mountId));
  });

  testWidgets('a mount without a home position is refused', (tester) async {
    final backend = mockBackend();
    when(
      () => backend.getMountCapabilities(_mountId),
    ).thenAnswer((_) async => const MountCapabilities(canFindHome: false));
    final handle = await _pump(tester, backend, statuses: [_status()]);

    final result =
        await handle.container.read(mountCommandServiceProvider).findHome();

    expect(result.isSuccess, isFalse);
    expect(result.message, contains('does not have a home position'));
    verifyNever(() => backend.mountFindHome(_mountId));
  });

  testWidgets('Abort slew reaches a home in progress', (tester) async {
    final backend = homeCapableBackend();
    final homeSent = Completer<void>();
    final handle = await _pump(
      tester,
      backend,
      statuses: [_status(), _status(slewing: true, dec: 40)],
    );
    // Hold the watcher inside its wait so the home is genuinely in flight
    // when Abort is pressed.
    final release = Completer<void>();
    when(() => backend.mountFindHome(_mountId)).thenAnswer((_) async {
      homeSent.complete();
      await release.future;
    });
    final service = handle.container.read(mountCommandServiceProvider);

    final home = service.findHome();
    await homeSent.future;
    expect(handle.container.read(mountStateProvider).isHoming, isTrue);

    final abort = await service.abortSlew();
    expect(
      abort.isSuccess,
      isTrue,
      reason: 'abort must not queue behind the home it is stopping',
    );
    verify(() => backend.mountAbort(_mountId)).called(1);

    release.complete();
    final result = await home;
    expect(result.isSuccess, isFalse);
    expect(result.message, MountHomeWatcher.cancelledMessage);
  });
}
