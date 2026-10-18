import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Elapsed time that only moves when the watcher waits, so a five-minute
/// home runs in microseconds and every step is deterministic.
class _FakeStopwatch implements Stopwatch {
  Duration now = Duration.zero;

  @override
  Duration get elapsed => now;

  @override
  void start() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _availableAtHome = {'at_home': 'available'};
const _unsupportedAtHome = {'at_home': 'unsupported'};

MountStatus _status({
  bool slewing = false,
  bool parked = false,
  bool atHome = false,
  double ra = 5.0,
  double dec = 20.0,
  bool tracking = false,
  Map<String, String> availability = _availableAtHome,
}) => MountStatus(
  connected: true,
  tracking: tracking,
  slewing: slewing,
  parked: parked,
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
  availability: availability,
);

/// A watcher fed by [statusAt], called with the fake elapsed time of each
/// read.
({MountHomeWatcher watcher, _FakeStopwatch clock}) _watcher(
  MountStatus Function(Duration elapsed) statusAt, {
  bool Function()? isCancelled,
}) {
  final clock = _FakeStopwatch();
  final watcher = MountHomeWatcher(
    readStatus: () async => statusAt(clock.now),
    isCancelled: isCancelled,
    delay: (d) async => clock.now += d,
    stopwatch: () => clock,
  );
  return (watcher: watcher, clock: clock);
}

void main() {
  final before = _status();

  test('motion then AtHome is a confirmed home', () async {
    final w = _watcher(
      (t) => t < const Duration(seconds: 3)
          ? _status(slewing: true, dec: 60)
          : _status(atHome: true, dec: 90),
    );

    expect(await w.watcher.watch(before), MountHomeOutcome.confirmed);
  });

  test(
    'motion then stop on a driver without AtHome is an unconfirmed home',
    () async {
      final w = _watcher(
        (t) => t < const Duration(seconds: 3)
            ? _status(slewing: true, availability: _unsupportedAtHome)
            : _status(dec: 90, availability: _unsupportedAtHome),
      );

      expect(
        await w.watcher.watch(_status(availability: _unsupportedAtHome)),
        MountHomeOutcome.unconfirmed,
      );
    },
  );

  test('a mount that never moves is reported, not homed '
      '(PegasusAstro NYX-101 replay)', () async {
    // What the rig showed after FindHome returned in 0.2 s: Slewing false,
    // Dec fixed at 8.01, RA drifting with sidereal time because tracking was
    // off, AtHome unsupported.
    const siderealHoursPerSecond = 1.00273790935 / 3600.0;
    final start = _status(ra: 3.0, dec: 8.01, availability: _unsupportedAtHome);
    final w = _watcher(
      (t) => _status(
        ra: 3.0 + t.inMicroseconds / 1e6 * siderealHoursPerSecond,
        dec: 8.01,
        availability: _unsupportedAtHome,
      ),
    );

    await expectLater(
      w.watcher.watch(start),
      throwsA(
        isA<MountHomeException>().having(
          (e) => e.message,
          'message',
          MountHomeWatcher.didNotMoveMessage,
        ),
      ),
    );
    expect(
      w.clock.now,
      greaterThanOrEqualTo(MountHomeWatcher.defaultMotionStartWindow),
      reason: 'the mount gets the whole start window before it is blamed',
    );
    expect(
      w.clock.now,
      lessThan(
        MountHomeWatcher.defaultMotionStartWindow + const Duration(seconds: 1),
      ),
    );
  });

  test('a stopped mount that is tracking does not read as moving', () {
    final tracking = _status(ra: 3.0, dec: 8.0, tracking: true);
    expect(
      MountHomeWatcher.pointingMoved(
        tracking,
        tracking,
        const Duration(minutes: 4),
      ),
      isFalse,
    );
  });

  test('a turning RA axis reads as moving even with Dec still', () {
    expect(
      MountHomeWatcher.pointingMoved(
        _status(ra: 3.0, dec: 8.0),
        _status(ra: 4.0, dec: 8.0),
        const Duration(seconds: 2),
      ),
      isTrue,
    );
  });

  test('stopping short of home with AtHome false is a failure', () async {
    final w = _watcher(
      (t) => t < const Duration(seconds: 2)
          ? _status(slewing: true)
          : _status(dec: 70),
    );

    await expectLater(
      w.watcher.watch(before),
      throwsA(
        isA<MountHomeException>().having(
          (e) => e.message,
          'message',
          MountHomeWatcher.stoppedShortMessage,
        ),
      ),
    );
  });

  test('a mount already at home is confirmed without moving', () async {
    final home = _status(atHome: true, dec: 90);
    final w = _watcher((_) => home);

    expect(await w.watcher.watch(home), MountHomeOutcome.confirmed);
  });

  test('the operator stopping it ends the watch as cancelled', () async {
    var reads = 0;
    final clock = _FakeStopwatch();
    final watcher = MountHomeWatcher(
      readStatus: () async {
        reads++;
        return _status(slewing: true);
      },
      isCancelled: () => reads >= 3,
      delay: (d) async => clock.now += d,
      stopwatch: () => clock,
    );

    await expectLater(
      watcher.watch(before),
      throwsA(
        isA<MountHomeException>().having(
          (e) => e.message,
          'message',
          MountHomeWatcher.cancelledMessage,
        ),
      ),
    );
  });

  test('a home still moving after the completion timeout fails', () async {
    final w = _watcher((_) => _status(slewing: true));

    await expectLater(
      w.watcher.watch(before),
      throwsA(isA<MountHomeException>()),
    );
    expect(
      w.clock.now,
      greaterThanOrEqualTo(MountHomeWatcher.defaultCompletionTimeout),
    );
  });
}
