import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show AstronomyCalculations;

/// Elapsed time that only moves when the watcher waits, so a long slew runs
/// in microseconds and every step is deterministic.
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
}) => MountStatus(
  connected: true,
  tracking: true,
  slewing: slewing,
  parked: false,
  atHome: false,
  sideOfPier: PierSide.west,
  rightAscension: ra,
  declination: dec,
  trackingRate: TrackingRate.sidereal,
  canPark: true,
  canSlew: true,
  canSync: true,
  canPulseGuide: true,
  canSetTrackingRate: true,
  availability: const {},
);

const _from = (ra: 0.0, dec: 0.0);
const _to = (ra: 6.0, dec: 60.0);

/// A mount that accepts the slew, keeps reporting `Slewing == false` at its
/// starting position for [lag], then travels to the target for [travel] with
/// `Slewing == true`, then sits on the target idle.
MountStatus Function(Duration) _laggingSlew({
  Duration lag = const Duration(milliseconds: 1500),
  Duration travel = const Duration(seconds: 20),
  ({double ra, double dec}) to = _to,
}) {
  return (t) {
    if (t < lag) return _status(ra: _from.ra, dec: _from.dec);
    final f = ((t - lag).inMicroseconds / travel.inMicroseconds).clamp(
      0.0,
      1.0,
    );
    return _status(
      ra: _from.ra + (to.ra - _from.ra) * f,
      dec: _from.dec + (to.dec - _from.dec) * f,
      slewing: f < 1.0,
    );
  };
}

({MountSlewWatcher watcher, _FakeStopwatch clock, List<MountSlewProgress> log})
_watcher(
  MountStatus Function(Duration elapsed) statusAt, {
  bool Function()? isCancelled,
  ({double ra, double dec}) target = _to,
  bool Function(Duration elapsed)? failAt,
}) {
  final clock = _FakeStopwatch();
  final log = <MountSlewProgress>[];
  final watcher = MountSlewWatcher(
    readStatus: () async {
      if (failAt != null && failAt(clock.now)) {
        throw StateError('driver did not answer');
      }
      return statusAt(clock.now);
    },
    targetRa: target.ra,
    targetDec: target.dec,
    isCancelled: isCancelled,
    onProgress: log.add,
    now: DateTime.utc(2026, 10, 21, 3),
    delay: (d) async => clock.now += d,
    stopwatch: () => clock,
  );
  return (watcher: watcher, clock: clock, log: log);
}

void main() {
  test('a Slewing flag that lags the command does not end the slew '
      '(ASCOM SlewToCoordinatesAsync)', () async {
    final w = _watcher(_laggingSlew());

    final arrived = await w.watcher.watch();

    // The first reads were idle at the start: the watcher kept going until
    // the mount had travelled and stopped.
    expect(w.log.first.slewing, isFalse);
    expect(w.log.first.remainingDegrees, greaterThan(50));
    expect(w.clock.now, greaterThanOrEqualTo(const Duration(seconds: 21)));
    expect(arrived.rightAscension, closeTo(_to.ra, 1e-9));
    expect(arrived.declination, closeTo(_to.dec, 1e-9));
  });

  test('progress counts the arc down to the target', () async {
    final w = _watcher(_laggingSlew());

    await w.watcher.watch();

    final midway = w.log.where((p) => p.slewing).toList();
    expect(midway, isNotEmpty);
    for (var i = 1; i < midway.length; i++) {
      expect(
        midway[i].remainingDegrees,
        lessThanOrEqualTo(midway[i - 1].remainingDegrees),
      );
    }
    expect(w.log.last.remainingDegrees, lessThan(0.01));
    expect(w.log.last.fraction, closeTo(1.0, 1e-3));
  });

  test('a mount that never moves is reported, not arrived', () async {
    final w = _watcher((_) => _status(ra: _from.ra, dec: _from.dec));

    await expectLater(
      w.watcher.watch(),
      throwsA(
        isA<MountSlewException>().having(
          (e) => e.message,
          'message',
          MountSlewWatcher.didNotMoveMessage,
        ),
      ),
    );
    expect(
      w.clock.now,
      greaterThanOrEqualTo(MountSlewWatcher.defaultMotionStartWindow),
    );
  });

  test('a mount that stops short says how far from the target', () async {
    final w = _watcher(_laggingSlew(to: (ra: 6.0, dec: 55.0)));

    await expectLater(
      w.watcher.watch(),
      throwsA(
        isA<MountSlewException>().having(
          (e) => e.message,
          'message',
          'The mount stopped 5.0° from the target.',
        ),
      ),
    );
  });

  test('a mount already on the target is accepted only after the start '
      'grace', () async {
    final w = _watcher((_) => _status(ra: _to.ra, dec: _to.dec));

    await w.watcher.watch();

    expect(
      w.clock.now,
      greaterThanOrEqualTo(MountSlewWatcher.defaultStartGrace),
    );
  });

  test('a short slew that is over before Slewing is ever seen still '
      'waits out the start grace', () async {
    // A centering correction: a few arcminutes, finished between reads.
    const target = (ra: 6.0, dec: 60.05);
    final w = _watcher(
      (t) => t < const Duration(milliseconds: 600)
          ? _status(ra: _to.ra, dec: _to.dec)
          : _status(ra: target.ra, dec: target.dec),
      target: target,
    );

    await w.watcher.watch();

    expect(
      w.clock.now,
      greaterThanOrEqualTo(MountSlewWatcher.defaultStartGrace),
    );
  });

  test('a mount that reports of-date coordinates arrives', () async {
    final (raDeg, decDeg) = AstronomyCalculations.precessFromJ2000ToDate(
      raDeg: _to.ra * 15,
      decDeg: _to.dec,
      dt: DateTime.utc(2026, 10, 21, 3),
    );
    final ofDate = (ra: raDeg / 15, dec: decDeg);
    final w = _watcher(_laggingSlew(to: ofDate));

    await w.watcher.watch();

    expect(w.log.last.remainingDegrees, lessThan(1e-6));
  });

  test('Abort slew stops the watch with its own message', () async {
    late final _FakeStopwatch clock;
    // Aborted five seconds in, with the mount under way.
    final w = _watcher(
      _laggingSlew(),
      isCancelled: () => clock.now >= const Duration(seconds: 5),
    );
    clock = w.clock;

    await expectLater(
      w.watcher.watch(),
      throwsA(
        isA<MountSlewException>().having(
          (e) => e.message,
          'message',
          MountSlewWatcher.cancelledMessage,
        ),
      ),
    );
    expect(w.log.last.slewing, isTrue);
  });

  test('a mount that stops answering mid-slew fails the slew', () async {
    final w = _watcher(
      _laggingSlew(),
      failAt: (t) => t >= const Duration(seconds: 5),
    );

    await expectLater(
      w.watcher.watch(),
      throwsA(
        isA<MountSlewException>().having(
          (e) => e.message,
          'message',
          startsWith('Lost contact with the mount during the slew'),
        ),
      ),
    );
  });

  test('a mount still moving after the timeout fails the slew', () async {
    final w = _watcher((_) => _status(ra: 3, dec: 30, slewing: true));

    await expectLater(
      w.watcher.watch(),
      throwsA(
        isA<MountSlewException>().having(
          (e) => e.message,
          'message',
          contains('still moving 5 minutes'),
        ),
      ),
    );
  });

  test('a single failed read is ridden out', () async {
    var failures = 0;
    final w = _watcher(
      _laggingSlew(),
      failAt: (t) => t >= const Duration(seconds: 5) && failures++ < 1,
    );

    await w.watcher.watch();
  });

  test('formatSlewDistance uses arcminutes below a degree', () {
    expect(formatSlewDistance(12.34), '12.3°');
    expect(formatSlewDistance(0.07), "4.2'");
  });
}
