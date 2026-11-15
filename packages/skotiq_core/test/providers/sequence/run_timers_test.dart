// RunTimers: the elapsed ticker honors an executor pause, the checkpoint saver
// never runs two saves at once, and stopTimers silences both.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_executor/run_timers.dart';

class _MockGuard extends Mock implements DiskSpaceGuardService {}

void main() {
  late _MockGuard guard;

  setUp(() {
    guard = _MockGuard();
    when(() => guard.stop()).thenReturn(null);
  });

  RunTimers build({
    required bool Function() isPaused,
    required List<double> elapsed,
    required Future<void> Function() save,
    bool running = true,
    String capturePath = '',
    List<String>? diskNotices,
  }) => RunTimers(
    isPaused: isPaused,
    onElapsed: elapsed.add,
    isRunning: () => running,
    saveCheckpoint: save,
    capturePath: () => capturePath,
    diskGuard: () => guard,
    safeTheRig: (_) async {},
    notifyDiskLow: (message) => diskNotices?.add(message),
    logger: LoggingService.new,
  );

  test('the ticker reports elapsed seconds and holds while paused', () {
    fakeAsync((async) {
      var paused = false;
      final elapsed = <double>[];
      final timers = build(
        isPaused: () => paused,
        elapsed: elapsed,
        save: () async {},
      );
      timers.start();
      async.elapse(const Duration(seconds: 3));
      expect(elapsed, hasLength(3));
      paused = true;
      async.elapse(const Duration(seconds: 5));
      expect(elapsed, hasLength(3));
      timers.dispose();
    });
  });

  test('a slow checkpoint save is never overlapped by the next tick', () {
    fakeAsync((async) {
      var saves = 0;
      final gate = Completer<void>();
      final timers = build(
        isPaused: () => false,
        elapsed: [],
        save: () {
          saves++;
          return gate.future;
        },
      );
      timers.start();
      async.elapse(const Duration(seconds: 95));
      expect(saves, 1, reason: 'the first save is still in flight');
      gate.complete();
      async.elapse(const Duration(seconds: 30));
      expect(saves, 2);
      timers.dispose();
    });
  });

  test('stopTimers silences the ticker and the saver', () {
    fakeAsync((async) {
      var saves = 0;
      final elapsed = <double>[];
      final timers = build(
        isPaused: () => false,
        elapsed: elapsed,
        save: () async => saves++,
      );
      timers.start();
      timers.stopTimers();
      async.elapse(const Duration(minutes: 2));
      expect(elapsed, isEmpty);
      expect(saves, 0);
      timers.dispose();
    });
  });

  test('no capture path means no disk watchdog', () {
    fakeAsync((async) {
      final timers = build(
        isPaused: () => false,
        elapsed: [],
        save: () async {},
      );
      timers.start();
      verifyNever(() => guard.start(capturePath: any(named: 'capturePath')));
      timers.dispose();
      verify(() => guard.stop()).called(1);
    });
  });

  test('a low-disk reading is told, a failed disk query is not', () {
    fakeAsync((async) {
      final events = StreamController<DiskSpaceWatchdogEvent>.broadcast();
      when(() => guard.events).thenAnswer((_) => events.stream);
      when(() => guard.start(capturePath: '/frames')).thenReturn(null);
      final notices = <String>[];
      final timers = build(
        isPaused: () => false,
        elapsed: [],
        save: () async {},
        capturePath: '/frames',
        diskNotices: notices,
      );
      timers.start();

      DiskSpaceInfo reading(int free) => DiskSpaceInfo(
        path: '/frames',
        totalBytes: free == 0 ? 0 : 1 << 40,
        freeBytes: free,
        sampledAt: DateTime(2026, 11, 15),
      );
      events.add(
        DiskSpaceWatchdogEvent(
          snapshot: reading(0),
          severity: DiskSpaceSeverity.warning,
          message: 'Disk-space monitoring failed: df exited 1',
        ),
      );
      events.add(
        DiskSpaceWatchdogEvent(
          snapshot: reading(8 << 30),
          severity: DiskSpaceSeverity.warning,
          message: 'Low disk space: 8 GB free on /frames.',
        ),
      );
      async.flushMicrotasks();

      expect(notices, ['Low disk space: 8 GB free on /frames.']);
      timers.dispose();
      events.close();
    });
  });
}
