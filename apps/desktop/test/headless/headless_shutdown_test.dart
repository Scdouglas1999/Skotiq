import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless/headless_shutdown.dart';

/// Coverage for the bounded, idempotent, repeated-signal-safe headless
/// shutdown coordinator. These pin the trust/reliability contract that a hung
/// or throwing teardown step — or an impatient operator mashing Ctrl+C — can
/// never wedge the daemon with the process still alive.
void main() {
  group('HeadlessShutdown', () {
    late List<int> exitCodes;
    late List<String> events;

    setUp(() {
      exitCodes = [];
      events = [];
    });

    HeadlessShutdown build({
      Future<void> Function()? safeRig,
      List<ShutdownStep> Function()? teardownSteps,
      Duration safingTimeout = const Duration(seconds: 60),
      Duration stepTimeout = const Duration(seconds: 20),
      Duration hardDeadline = const Duration(seconds: 90),
      int completionExitCode = 0,
    }) {
      return HeadlessShutdown(
        safeRig: safeRig ?? () async => events.add('safeRig'),
        teardownSteps:
            teardownSteps ??
            () => [
              (name: 'a', action: () async => events.add('a')),
              (name: 'b', action: () async => events.add('b')),
            ],
        exitProcess: (code) {
          exitCodes.add(code);
          events.add('exit($code)');
        },
        onInfo: (m, {error}) => events.add('info:$m'),
        onCritical: (m, {error}) =>
            events.add('critical:$m${error == null ? '' : ':$error'}'),
        onStderr: (m) => events.add('stderr:$m'),
        safingTimeout: safingTimeout,
        stepTimeout: stepTimeout,
        hardDeadline: hardDeadline,
        completionExitCode: completionExitCode,
      );
    }

    test('runs safing first, then every step in order, then exit(0)', () async {
      final coordinator = build();
      await coordinator.request('Received SIGINT');

      expect(events, [
        'info:Received SIGINT; shutting down',
        'safeRig',
        'info:Pre-shutdown rig safing completed',
        'a',
        'b',
        'exit(0)',
      ]);
      expect(exitCodes, [0]);
    });

    test(
      'a safing failure is logged loudly but never aborts teardown or exit',
      () async {
        final coordinator = build(
          safeRig: () async => throw StateError('mount wedged'),
        );
        await coordinator.request('Received SIGTERM');

        // Teardown still ran to completion and the daemon still exited.
        expect(events, containsAllInOrder(['a', 'b', 'exit(0)']));
        expect(exitCodes, [0]);
        expect(
          events.any((e) => e.startsWith('critical:Pre-shutdown rig safing')),
          isTrue,
        );
        expect(events.any((e) => e.startsWith('stderr:CRITICAL')), isTrue);
      },
    );

    test(
      'a startup-failure cleanup can preserve a non-zero exit code',
      () async {
        final coordinator = build(completionExitCode: 1);

        await coordinator.request('Startup failed');

        expect(events, containsAllInOrder(['safeRig', 'a', 'b', 'exit(1)']));
        expect(exitCodes, [1]);
      },
    );

    test(
      'a throwing teardown step does not short-circuit the remaining steps',
      () async {
        final coordinator = build(
          teardownSteps: () => [
            (name: 'first', action: () async => events.add('first')),
            (name: 'boom', action: () async => throw Exception('stop failed')),
            (name: 'third', action: () async => events.add('third')),
          ],
        );
        await coordinator.request('Received SIGINT');

        // 'third' STILL ran despite 'boom' throwing, and we exited cleanly.
        expect(events, containsAllInOrder(['first', 'third', 'exit(0)']));
        expect(exitCodes, [0]);
        expect(
          events.any(
            (e) => e.startsWith('critical:Shutdown step "boom" failed'),
          ),
          isTrue,
        );
      },
    );

    test('a hung teardown step is bounded by the per-step timeout', () async {
      final hang = Completer<void>();
      addTearDown(() {
        if (!hang.isCompleted) hang.complete();
      });
      final coordinator = build(
        stepTimeout: const Duration(milliseconds: 40),
        teardownSteps: () => [
          (name: 'wedged', action: () => hang.future), // never completes
          (name: 'after', action: () async => events.add('after')),
        ],
      );

      await coordinator.request('Received SIGINT');

      // The hung step was abandoned after the timeout, the next step ran, and
      // the daemon exited without waiting on the wedged future.
      expect(events, containsAllInOrder(['after', 'exit(0)']));
      expect(exitCodes, [0]);
      expect(
        events.any(
          (e) => e.startsWith('critical:Shutdown step "wedged" failed'),
        ),
        isTrue,
      );
    });

    test(
      'a repeated signal during an in-flight shutdown forces exit(1)',
      () async {
        final safingGate = Completer<void>();
        var safeRigCalls = 0;
        final coordinator = build(
          safeRig: () async {
            safeRigCalls++;
            await safingGate.future; // park the first shutdown mid-safing
          },
        );

        // First signal: parks awaiting the safing gate.
        final first = coordinator.request('Received SIGINT');
        await Future<void>.delayed(Duration.zero);
        expect(exitCodes, isEmpty, reason: 'still safing, no exit yet');

        // Second signal while wedged: immediate forced exit.
        await coordinator.request('Received SIGINT');
        expect(exitCodes, [1], reason: 'repeated signal forces exit(1)');

        // Releasing the gate lets the first shutdown finish, but it must NOT
        // exit again (the process is already gone) nor re-run safing.
        safingGate.complete();
        await first;
        expect(exitCodes, [1], reason: 'first shutdown cannot double-exit');
        expect(safeRigCalls, 1, reason: 'safing runs exactly once');
      },
    );

    test(
      'the hard deadline force-exits even if the sequence overruns',
      () async {
        final hang = Completer<void>();
        addTearDown(() {
          if (!hang.isCompleted) hang.complete();
        });
        final coordinator = build(
          // Step timeout longer than the deadline, so only the deadline can
          // rescue a wedged step.
          stepTimeout: const Duration(seconds: 30),
          hardDeadline: const Duration(milliseconds: 40),
          teardownSteps: () => [(name: 'wedged', action: () => hang.future)],
        );

        unawaited(coordinator.request('Received SIGINT'));
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(exitCodes, [1], reason: 'hard deadline forced the exit');
        expect(
          events.any((e) => e.startsWith('stderr:Shutdown exceeded')),
          isTrue,
        );
      },
    );

    test('a safing timeout does not block teardown', () async {
      final safingHang = Completer<void>();
      addTearDown(() {
        if (!safingHang.isCompleted) safingHang.complete();
      });
      final coordinator = build(
        safingTimeout: const Duration(milliseconds: 40),
        safeRig: () => safingHang.future, // never completes
      );

      await coordinator.request('Received SIGINT');

      expect(events, containsAllInOrder(['a', 'b', 'exit(0)']));
      expect(exitCodes, [0]);
    });
  });
}
