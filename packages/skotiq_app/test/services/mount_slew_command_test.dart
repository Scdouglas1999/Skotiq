import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/harness.dart';

const _mountId = 'simulator:mount:0';
const _target = (ra: 6.0, dec: 60.0);

class _MountNotifier extends MountStateNotifier {
  _MountNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _mountId,
      deviceName: 'Simulated Mount',
      isTracking: true,
    );
  }
}

/// Elapsed time that moves only when the watcher waits.
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
  required double ra,
  required double dec,
  bool slewing = false,
}) =>
    MountStatus(
      connected: true,
      tracking: true,
      slewing: slewing,
      parked: false,
      atHome: false,
      sideOfPier: PierSide.west,
      rightAscension: ra,
      declination: dec,
      altitude: 40,
      azimuth: 10,
      trackingRate: TrackingRate.sidereal,
      canPark: true,
      canSlew: true,
      canSync: true,
      canPulseGuide: true,
      canSetTrackingRate: true,
      availability: const {},
    );

/// An ASCOM-like mount: after the slew is accepted it reads idle at the start
/// for [lagReads] reads, slewing for [travelReads] reads while it closes on
/// the target, then idle on the target.
List<MountStatus> _laggingSlew({
  int lagReads = 3,
  int travelReads = 6,
  ({double ra, double dec}) to = _target,
}) =>
    [
      for (var i = 0; i < lagReads; i++) _status(ra: 0, dec: 0),
      for (var i = 1; i <= travelReads; i++)
        _status(
          ra: to.ra * i / (travelReads + 1),
          dec: to.dec * i / (travelReads + 1),
          slewing: true,
        ),
      _status(ra: to.ra, dec: to.dec),
    ];

class _Script {
  _Script(this.statuses);

  final List<MountStatus> statuses;
  int reads = 0;
  void Function(int read)? onRead;

  MountStatus next() {
    final status = statuses[reads.clamp(0, statuses.length - 1)];
    reads++;
    onRead?.call(reads);
    return status;
  }
}

Future<HarnessHandle> _pump(
  WidgetTester tester,
  MockBackend backend,
  _Script script,
) {
  when(() => backend.getMountCapabilities(_mountId)).thenAnswer(
    (_) async => const MountCapabilities(canSlew: true, canAbortSlew: true),
  );
  when(() => backend.mountSlewToCoordinates(_mountId, any(), any()))
      .thenAnswer((_) async {});
  when(() => backend.mountAbort(_mountId)).thenAnswer((_) async {});
  when(() => backend.getMountStatus(_mountId))
      .thenAnswer((_) async => script.next());
  return pumpAppScreen(
    tester,
    const SizedBox.shrink(),
    backend: backend,
    extraOverrides: [
      mountStateProvider.overrideWith((ref) => _MountNotifier(ref)),
      mountSlewWatcherFactoryProvider.overrideWithValue(({
        required readStatus,
        required targetRa,
        required targetDec,
        isCancelled,
        onProgress,
      }) {
        final clock = _FakeStopwatch();
        return MountSlewWatcher(
          readStatus: readStatus,
          targetRa: targetRa,
          targetDec: targetDec,
          isCancelled: isCancelled,
          onProgress: onProgress,
          delay: (d) async => clock.now += d,
          stopwatch: () => clock,
        );
      }),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Slew complete waits for the mount to arrive, not for the driver '
      'to accept the slew', (tester) async {
    final backend = mockBackend();
    final script = _Script(_laggingSlew());
    final handle = await _pump(tester, backend, script);
    final container = handle.container;
    final seen = <MountSlewProgress>[];
    final operationSteps = <String?>[];
    var completed = false;
    script.onRead = (_) {
      expect(completed, isFalse, reason: 'reported complete mid-slew');
      final progress = container.read(mountSlewProgressProvider);
      if (progress != null) seen.add(progress);
      operationSteps.add(
        container
            .read(activeOperationsProvider)[OperationType.slewToTarget]
            ?.currentStep,
      );
    };

    final result = await container
        .read(mountCommandServiceProvider)
        .slewTo(_target.ra, _target.dec);
    completed = true;

    expect(result.isSuccess, isTrue, reason: result.message);
    expect(result.message, 'Slew complete');
    // Every read through the lag and the travel happened before the result.
    expect(script.reads, greaterThanOrEqualTo(_laggingSlew().length + 1));
    expect(seen.first.remainingDegrees, greaterThan(50));
    expect(
      operationSteps.whereType<String>(),
      contains(startsWith('Slewing, ')),
    );
    // The position is the mount's reading on arrival, not the target copied
    // in with a zero altitude.
    final mount = container.read(mountStateProvider);
    expect(mount.isSlewing, isFalse);
    expect(mount.ra, closeTo(_target.ra, 1e-9));
    expect(mount.altitude, 40);
    expect(container.read(mountSlewProgressProvider), isNull);
    expect(
      container.read(activeOperationsProvider)[OperationType.slewToTarget],
      isNull,
    );
  });

  testWidgets('a mount that stops short is reported as a failure', (
    tester,
  ) async {
    final backend = mockBackend();
    final script = _Script(_laggingSlew(to: (ra: 6.0, dec: 50.0)));
    final handle = await _pump(tester, backend, script);

    final result = await handle.container
        .read(mountCommandServiceProvider)
        .slewTo(_target.ra, _target.dec);

    expect(result.isSuccess, isFalse);
    expect(result.message, 'The mount stopped 10.0° from the target.');
    expect(handle.container.read(mountStateProvider).isSlewing, isFalse);
  });

  testWidgets('a mount that accepts the slew and never moves is a failure', (
    tester,
  ) async {
    final backend = mockBackend();
    final script = _Script([_status(ra: 0, dec: 0)]);
    final handle = await _pump(tester, backend, script);

    final result = await handle.container
        .read(mountCommandServiceProvider)
        .slewTo(_target.ra, _target.dec);

    expect(result.isSuccess, isFalse);
    expect(result.message, MountSlewWatcher.didNotMoveMessage);
  });

  testWidgets('Abort slew during a slew ends it as stopped, not complete', (
    tester,
  ) async {
    final backend = mockBackend();
    final script = _Script(_laggingSlew(travelReads: 20));
    final handle = await _pump(tester, backend, script);
    final service = handle.container.read(mountCommandServiceProvider);
    script.onRead = (read) {
      if (read == 6) service.abortSlew(showFeedback: false);
    };

    final result = await service.slewTo(_target.ra, _target.dec);

    expect(result.isSuccess, isFalse);
    expect(result.message, MountSlewWatcher.cancelledMessage);
    verify(() => backend.mountAbort(_mountId)).called(1);
    expect(handle.container.read(mountSlewProgressProvider), isNull);
  });
}
