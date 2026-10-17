// A desktop GUI that dies with devices connected must not leave nothing
// behind — no shutdown record, no safed device, a log whose last line is an
// unrelated warning. An unattended imager must never end that quietly.
//
// These tests pin the death path itself, independently of whatever triggers
// it:
//   * the record is on disk BEFORE any device command is sent, because a safing
//     call that hangs must still leave evidence;
//   * safing runs, is time-bounded, and a failure to park never stops the
//     process from ending;
//   * a repeated stop signal is an escape hatch, not a no-op;
//   * a session that just vanishes leaves a `running` record naming the last
//     error it saw, so the NEXT launch can say so.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/desktop_last_gasp.dart';

void main() {
  late Directory dataRoot;
  late File recordFile;

  setUp(() {
    dataRoot = Directory.systemTemp.createTempSync('ns-last-gasp');
    recordFile = resolveDesktopSessionRecordFile(dataRoot.path);
  });

  tearDown(() {
    if (dataRoot.existsSync()) dataRoot.deleteSync(recursive: true);
  });

  DesktopLastGasp build({
    required Future<void> Function() safeRig,
    required List<int> exits,
    Duration safingTimeout = const Duration(seconds: 45),
    Duration releaseTimeout = const Duration(seconds: 10),
    Future<void> Function()? releaseDarkroomJobs,
    void Function(String message, {Object? error})? onCritical,
  }) {
    return DesktopLastGasp(
      recordFile: recordFile,
      safeRig: safeRig,
      exitProcess: exits.add,
      releaseDarkroomJobs: releaseDarkroomJobs,
      safingTimeout: safingTimeout,
      releaseTimeout: releaseTimeout,
      onCritical: onCritical,
      version: '6.1.0',
      pid: 4242,
    );
  }

  test('the record is written before the rig is touched', () async {
    final safingStarted = Completer<void>();
    final releaseSafing = Completer<void>();
    final exits = <int>[];
    final lastGasp = build(
      safeRig: () {
        safingStarted.complete();
        return releaseSafing.future;
      },
      exits: exits,
    );

    final pending = lastGasp.handleFatal('Received SIGTERM');
    await safingStarted.future;

    // Safing is still in flight and the process has not exited — but the
    // evidence already survives a kill -9 from here on.
    expect(exits, isEmpty);
    final midFlight = DesktopSessionRecord.tryParse(
      recordFile.readAsStringSync(),
    )!;
    expect(midFlight.outcome, DesktopSessionOutcome.fatal);
    expect(midFlight.reason, 'Received SIGTERM');
    expect(
      midFlight.rigSafed,
      isFalse,
      reason:
          'Claiming the rig was safed before safing returned would be '
          'the app stating something untrue about the mount.',
    );

    releaseSafing.complete();
    await pending;

    final settled = DesktopSessionRecord.tryParse(
      recordFile.readAsStringSync(),
    )!;
    expect(settled.rigSafed, isTrue);
    expect(exits, [70]);
  });

  test('a safing failure is recorded and never blocks the exit', () async {
    final exits = <int>[];
    final lastGasp = build(
      safeRig: () async => throw StateError('mount refused to park'),
      exits: exits,
    );

    await lastGasp.handleFatal('Received SIGTERM');

    final record = DesktopSessionRecord.tryParse(
      recordFile.readAsStringSync(),
    )!;
    expect(record.rigSafed, isFalse);
    expect(record.safingError, contains('mount refused to park'));
    expect(
      exits,
      [70],
      reason:
          'A rig that will not park must not wedge the '
          'process; the operator gets the record instead.',
    );
  });

  test(
    'a safing call that hangs is bounded and the process still exits',
    () async {
      final exits = <int>[];
      final lastGasp = build(
        safeRig: () => Completer<void>().future, // never completes
        exits: exits,
        safingTimeout: const Duration(milliseconds: 50),
      );

      await lastGasp.handleFatal('Received SIGTERM');

      expect(exits, [70]);
      final record = DesktopSessionRecord.tryParse(
        recordFile.readAsStringSync(),
      )!;
      expect(record.rigSafed, isFalse);
      expect(record.safingError, contains('TimeoutException'));
    },
  );

  test('a repeated stop signal forces an immediate exit', () async {
    final releaseSafing = Completer<void>();
    final exits = <int>[];
    var safingCalls = 0;
    final lastGasp = build(
      safeRig: () {
        safingCalls += 1;
        return releaseSafing.future;
      },
      exits: exits,
    );

    final first = lastGasp.handleFatal('Received SIGTERM');
    await Future<void>.delayed(Duration.zero);
    await lastGasp.handleFatal('Received SIGINT');

    expect(
      exits,
      [1],
      reason:
          'A second stop signal is the operator escaping '
          'a wedged teardown; swallowing it leaves SIGKILL as the only way out.',
    );
    expect(safingCalls, 1, reason: 'The safing sequence runs exactly once.');

    releaseSafing.complete();
    await first;
    // The first path completing must not exit a second time.
    expect(exits, [1]);
  });

  test(
    'a session that vanishes leaves a running record naming its last error',
    () {
      final lastGasp = build(safeRig: () async {}, exits: <int>[]);
      lastGasp.markRunning();

      expect(
        lastGasp.readPreviousSession()!.outcome,
        DesktopSessionOutcome.running,
      );

      lastGasp.noteError('FlutterError: Timed out waiting for OpenGL frame');

      // Nothing else happens — the process is gone. That silent death is
      // diagnosable at the next launch.
      final record = DesktopSessionRecord.tryParse(
        recordFile.readAsStringSync(),
      )!;
      expect(record.endedWithoutShutdownPath, isTrue);
      expect(record.lastError, contains('OpenGL frame'));
      expect(record.version, '6.1.0');
      expect(record.pid, 4242);
    },
  );

  test('a clean window close is not reported as a silent death', () {
    final lastGasp = build(safeRig: () async {}, exits: <int>[]);
    lastGasp.markRunning();
    lastGasp.recordCleanExit('Window closed');

    final record = lastGasp.readPreviousSession()!;
    expect(record.outcome, DesktopSessionOutcome.clean);
    expect(
      record.endedWithoutShutdownPath,
      isFalse,
      reason:
          'Crying "the app died" after every normal quit would make the '
          'notice worthless.',
    );
  });

  test('a torn record from a half-written session reads as nothing', () {
    recordFile.parent.createSync(recursive: true);
    recordFile.writeAsStringSync('{"outcome":"run');
    final lastGasp = build(safeRig: () async {}, exits: <int>[]);

    expect(lastGasp.readPreviousSession(), isNull);
  });

  test('a torn record is REPORTED, not just read as nothing', () {
    recordFile.parent.createSync(recursive: true);
    recordFile.writeAsStringSync('{"outcome":"run');
    final critical = <String>[];
    final lastGasp = build(
      safeRig: () async {},
      exits: <int>[],
      onCritical: (message, {error}) => critical.add(message),
    );

    expect(lastGasp.readPreviousSession(), isNull);
    expect(
      critical,
      hasLength(1),
      reason:
          'A record cut off mid-write is proof the previous process died '
          'without a shutdown path; answering "no record" and saying nothing '
          'hides the exact death this file exists to expose.',
    );
    expect(critical.single, contains(recordFile.path));
  });

  test('a record that cannot be decoded is reported with its error', () {
    recordFile.parent.createSync(recursive: true);
    // A partially-written block on a failing disk: the bytes are there but they
    // are not text, so readAsStringSync throws instead of returning JSON.
    recordFile.writeAsBytesSync(<int>[0xff, 0xfe, 0xfd, 0x00]);
    final critical = <String>[];
    final errors = <Object?>[];
    final lastGasp = build(
      safeRig: () async {},
      exits: <int>[],
      onCritical: (message, {error}) {
        critical.add(message);
        errors.add(error);
      },
    );

    expect(lastGasp.readPreviousSession(), isNull);
    expect(critical, hasLength(1));
    expect(errors.single, isNotNull);
  });

  test('a first launch with no record at all says nothing', () {
    final critical = <String>[];
    final lastGasp = build(
      safeRig: () async {},
      exits: <int>[],
      onCritical: (message, {error}) => critical.add(message),
    );

    expect(lastGasp.readPreviousSession(), isNull);
    expect(
      critical,
      isEmpty,
      reason:
          'Crying "unreadable record" on every fresh install would make the '
          'notice worthless.',
    );
  });

  // The GUI drains the same dawn queue the daemon does, so it owes the same
  // hand-back: a pass left `running` by an orderly quit is read at the next
  // open as a dead process and charged one of the job's three starts. Three
  // ordinary quits during a dawn pass then fail the night outright.
  group('the Darkroom queue', () {
    test('a running pass is handed back before the rig is safed', () async {
      final order = <String>[];
      final exits = <int>[];
      final lastGasp = build(
        safeRig: () async => order.add('safe'),
        releaseDarkroomJobs: () async => order.add('release'),
        exits: exits,
      );

      await lastGasp.handleFatal('Received SIGTERM');

      expect(order, ['release', 'safe']);
      expect(exits, [70]);
    });

    test('a hand-back that hangs never blocks the exit', () async {
      final exits = <int>[];
      final criticals = <String>[];
      final lastGasp = build(
        safeRig: () async {},
        releaseDarkroomJobs: () => Completer<void>().future,
        releaseTimeout: const Duration(milliseconds: 20),
        onCritical: (message, {error}) => criticals.add(message),
        exits: exits,
      );

      await lastGasp.handleFatal('Received SIGTERM');

      expect(exits, [70]);
      expect(
        criticals.any((m) => m.contains('could not be handed back')),
        isTrue,
        reason: 'the operator is told the next launch will spend a start',
      );
    });

    test('an operator quit hands the pass back too', () async {
      final released = <int>[];
      final exits = <int>[];
      final lastGasp = build(
        safeRig: () async {},
        releaseDarkroomJobs: () async => released.add(1),
        exits: exits,
      );

      lastGasp.recordCleanExit('Window closed');
      await lastGasp.handOffDarkroomWork();

      expect(released, hasLength(1), reason: 'once, not once per caller');
    });
  });
}
