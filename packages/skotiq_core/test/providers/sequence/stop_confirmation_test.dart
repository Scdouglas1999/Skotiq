import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/providers/sequence/sequence_executor/stop_confirmation.dart';

/// Stand-in for the finalization transaction's confirmable stop state.
class _Target implements NativeStopConfirmationTarget {
  @override
  bool nativeStopConfirmed = false;
}

void main() {
  const fast = Duration(milliseconds: 20);

  NativeStopConfirmer confirmer({
    required Future<String> Function() readNativeState,
    Duration timeout = const Duration(milliseconds: 400),
    List<String>? infoLog,
    List<String>? debugLog,
  }) => NativeStopConfirmer(
    readNativeState: readNativeState,
    logInfo: (m) => infoLog?.add(m),
    logDebug: (m) => debugLog?.add(m),
    timeout: timeout,
    pollInterval: fast,
  );

  test('a target already confirmed returns immediately and settles the '
      'completer', () async {
    final target = _Target()..nativeStopConfirmed = true;
    final completer = Completer<void>();

    await confirmer(
      readNativeState: () async => fail('status must not be polled'),
    ).awaitTermination(target, completer);

    expect(completer.isCompleted, isTrue);
  });

  test(
    'the pushed terminal event confirms without any terminal status',
    () async {
      final target = _Target();
      final completer = Completer<void>();
      var polls = 0;

      final future = confirmer(
        readNativeState: () async {
          polls++;
          return 'running';
        },
      ).awaitTermination(target, completer);

      await Future<void>.delayed(fast);
      completer.complete();
      await future;

      expect(target.nativeStopConfirmed, isTrue);
      expect(
        polls,
        greaterThan(0),
        reason: 'the poll runs alongside the event',
      );
    },
  );

  test('a terminal status confirms when no event ever arrives', () async {
    final target = _Target();
    final infoLog = <String>[];
    var polls = 0;

    await confirmer(
      readNativeState: () async {
        polls++;
        return polls < 2 ? 'running' : 'cancelled';
      },
      infoLog: infoLog,
    ).awaitTermination(target, Completer<void>());

    expect(target.nativeStopConfirmed, isTrue);
    expect(infoLog.single, contains('status poll'));
  });

  test('an unrecognised state is NOT treated as terminal', () async {
    final target = _Target();

    await expectLater(
      confirmer(
        readNativeState: () async => 'some-future-native-state',
      ).awaitTermination(target, Completer<void>()),
      throwsA(isA<TimeoutException>()),
    );
    expect(target.nativeStopConfirmed, isFalse);
  });

  test(
    'a failing status read is not confirmation, and is logged once',
    () async {
      final target = _Target();
      final debugLog = <String>[];

      await expectLater(
        confirmer(
          readNativeState: () async => throw StateError('backend unreachable'),
          debugLog: debugLog,
        ).awaitTermination(target, Completer<void>()),
        throwsA(isA<TimeoutException>()),
      );

      expect(target.nativeStopConfirmed, isFalse);
      expect(debugLog, hasLength(1));
      expect(debugLog.single, contains('status poll failed'));
    },
  );

  test(
    'a hanging status read cannot outlive the confirmation window',
    () async {
      final target = _Target();

      await expectLater(
        confirmer(
          readNativeState: () => Completer<String>().future,
          timeout: const Duration(milliseconds: 200),
        ).awaitTermination(target, Completer<void>()),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test('every terminal state in the allow-list confirms', () async {
    for (final state in kNativeTerminalStates) {
      final target = _Target();
      await confirmer(
        readNativeState: () async => state.toUpperCase(),
      ).awaitTermination(target, Completer<void>());
      expect(target.nativeStopConfirmed, isTrue, reason: state);
    }
  });
}
