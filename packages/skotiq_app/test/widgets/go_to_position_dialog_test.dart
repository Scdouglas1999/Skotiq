// Behavioral coverage for the FocusPanel "Go To Position" interaction
// (packages/skotiq_app/lib/screens/imaging/widgets/focus_panel.dart).
//
// The dialog awaits the real focuser move, so the contract under test is:
//   * whole-number input is validated and bad input never issues a move;
//   * an unknown driver max is NOT replaced with a fabricated ceiling;
//   * a move in flight shows a busy state and rejects duplicate submissions;
//   * a failed move keeps the dialog open with the typed value and a retry;
//   * a successful move dismisses only after its Future resolves;
//   * a pre-move Cancel issues neither a move nor a halt;
//   * aborting an in-flight move issues exactly one real halt, holds the dialog
//     open until the halt Future resolves, and stays open/retryable if it
//     fails;
//   * back/barrier gestures cannot silently dismiss a moving focuser — they
//     halt the hardware first;
//   * the move is routed through deviceServiceProvider.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/focus_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockDeviceService extends Mock implements DeviceService {}

/// Pumps a launcher and opens the dialog through `showDialog`, exactly as
/// [FocusPanel] does, so `Navigator.pop` genuinely dismisses the route.
Future<void> _openDialog(
  WidgetTester tester, {
  required int initialPosition,
  required int? maxPosition,
  required Future<void> Function(int position) onSubmit,
  Future<void> Function()? onHalt,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => GoToPositionDialog(
                  initialPosition: initialPosition,
                  maxPosition: maxPosition,
                  onSubmit: onSubmit,
                  onHalt: onHalt ?? () async {},
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(GoToPositionDialog), findsOneWidget);
}

void main() {
  testWidgets('invalid input shows an error and never issues a move',
      (tester) async {
    var calls = 0;
    await _openDialog(
      tester,
      initialPosition: 1000,
      maxPosition: 20000,
      onSubmit: (_) async => calls++,
    );

    // Non-numeric input is rejected.
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(calls, 0);
    expect(find.byType(GoToPositionDialog), findsOneWidget);
    expect(find.text('Enter a whole number.'), findsOneWidget);

    // Negative input is rejected against the >= 0 lower bound.
    await tester.enterText(find.byType(TextField), '-5');
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('Position must be 0 or greater.'), findsOneWidget);

    // Above a known max is rejected too.
    await tester.enterText(find.byType(TextField), '20001');
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('Position must be between 0 and 20000.'), findsOneWidget);
  });

  testWidgets('unknown max validates only the floor and invents no ceiling',
      (tester) async {
    int? moved;
    await _openDialog(
      tester,
      initialPosition: 0,
      maxPosition: null,
      onSubmit: (position) async => moved = position,
    );

    // Empty field surfaces the hint; it must not fabricate a 50000 ceiling.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('0 or greater'), findsOneWidget);
    expect(find.textContaining('50000'), findsNothing);

    // With the real max unknown, a large value is accepted rather than clamped
    // to an invented ceiling.
    await tester.enterText(find.byType(TextField), '999999');
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(moved, 999999);
    expect(find.byType(GoToPositionDialog), findsNothing);
  });

  testWidgets('a second tap while a move is in flight is ignored',
      (tester) async {
    var calls = 0;
    final gate = Completer<void>();
    await _openDialog(
      tester,
      initialPosition: 1000,
      maxPosition: 20000,
      onSubmit: (_) async {
        calls++;
        await gate.future;
      },
    );

    await tester.enterText(find.byType(TextField), '1500');
    await tester.tap(find.text('Go'));
    await tester.pump();

    // Busy state is truthful and the primary action is disabled.
    expect(find.text('Moving...'), findsOneWidget);
    expect(find.text('Go'), findsNothing);

    // Tapping the disabled button again must not launch a second move.
    await tester.tap(find.text('Moving...'));
    await tester.pump();
    expect(calls, 1);

    gate.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(GoToPositionDialog), findsNothing);
  });

  testWidgets('a failed move stays open with the value and a live retry',
      (tester) async {
    var calls = 0;
    await _openDialog(
      tester,
      initialPosition: 1000,
      maxPosition: 20000,
      onSubmit: (_) async {
        calls++;
        throw StateError('driver offline');
      },
    );

    await tester.enterText(find.byType(TextField), '12345');
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    // Still open, error surfaced, typed value preserved, retry re-enabled.
    expect(find.byType(GoToPositionDialog), findsOneWidget);
    expect(find.textContaining('Move failed'), findsOneWidget);
    expect(find.text('12345'), findsOneWidget);
    expect(find.text('Go'), findsOneWidget);
    expect(find.text('Moving...'), findsNothing);

    // The retry affordance really issues the move again.
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(GoToPositionDialog), findsOneWidget);
  });

  testWidgets('success dismisses only after the move Future resolves',
      (tester) async {
    var calls = 0;
    final gate = Completer<void>();
    await _openDialog(
      tester,
      initialPosition: 1000,
      maxPosition: 20000,
      onSubmit: (_) async {
        calls++;
        await gate.future;
      },
    );

    await tester.enterText(find.byType(TextField), '1500');
    await tester.tap(find.text('Go'));
    await tester.pump();

    // Move not yet resolved: dialog remains and shows the busy state.
    expect(find.byType(GoToPositionDialog), findsOneWidget);
    expect(find.text('Moving...'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(GoToPositionDialog), findsNothing);
  });

  testWidgets('routes the move through deviceServiceProvider', (tester) async {
    final device = _MockDeviceService();
    when(() => device.moveFocuserTo(any())).thenAnswer((_) async {});

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        deviceServiceProvider.overrideWithValue(device)
      ],
    );
    addTearDown(container.dispose);

    await _openDialog(
      tester,
      initialPosition: 1000,
      maxPosition: 20000,
      onSubmit: (position) =>
          container.read(deviceServiceProvider).moveFocuserTo(position),
    );

    await tester.enterText(find.byType(TextField), '4200');
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();

    verify(() => device.moveFocuserTo(4200)).called(1);
    expect(find.byType(GoToPositionDialog), findsNothing);
  });

  testWidgets('a pre-move Cancel issues neither a move nor a halt',
      (tester) async {
    var moveCalls = 0;
    var haltCalls = 0;
    await _openDialog(
      tester,
      initialPosition: 1000,
      maxPosition: 20000,
      onSubmit: (_) async => moveCalls++,
      onHalt: () async => haltCalls++,
    );

    // Nothing is in flight, so Cancel (not Stop) is offered and just leaves.
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(moveCalls, 0);
    expect(haltCalls, 0);
    expect(find.byType(GoToPositionDialog), findsNothing);
  });

  testWidgets('Stop aborts an in-flight move by awaiting the real halt',
      (tester) async {
    var moveCalls = 0;
    var haltCalls = 0;
    final moveGate = Completer<void>();
    final haltGate = Completer<void>();
    await _openDialog(
      tester,
      initialPosition: 1000,
      maxPosition: 20000,
      onSubmit: (_) async {
        moveCalls++;
        await moveGate.future; // Move stays in flight.
      },
      onHalt: () async {
        haltCalls++;
        await haltGate.future; // Halt stays in flight until we release it.
      },
    );

    await tester.enterText(find.byType(TextField), '1500');
    await tester.tap(find.text('Go'));
    await tester.pump();

    // While moving the abort affordance is the destructive Stop, not a silent
    // Cancel that would leave the focuser running.
    expect(find.text('Moving...'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Stop'), findsOneWidget);

    // Stop issues exactly one halt and shows a busy state, but the dialog must
    // stay open until the halt Future actually resolves.
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(haltCalls, 1);
    expect(find.text('Stopping...'), findsOneWidget);
    expect(find.byType(GoToPositionDialog), findsOneWidget);

    // A second Stop tap while halting must not fire a duplicate halt.
    await tester.tap(find.text('Stopping...'));
    await tester.pump();
    expect(haltCalls, 1);

    // Only once the halt completes does the dialog close.
    haltGate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(GoToPositionDialog), findsNothing);
    expect(haltCalls, 1);

    // Releasing the abandoned move afterwards must not double-pop or error.
    moveGate.complete();
    await tester.pumpAndSettle();
    expect(moveCalls, 1);
  });

  testWidgets('a failed halt keeps the dialog open with a live retry',
      (tester) async {
    var haltCalls = 0;
    var failNextHalt = true;
    final moveGate = Completer<void>();
    await _openDialog(
      tester,
      initialPosition: 1000,
      maxPosition: 20000,
      onSubmit: (_) => moveGate.future, // Move stays in flight throughout.
      onHalt: () async {
        haltCalls++;
        if (failNextHalt) {
          failNextHalt = false;
          throw StateError('comms lost');
        }
      },
    );

    await tester.enterText(find.byType(TextField), '1500');
    await tester.tap(find.text('Go'));
    await tester.pump();

    // The move stays gated, so its "Moving..." spinner never stops; settle
    // would hang. Pump discrete frames to flush the rejected halt future.
    await tester.tap(find.text('Stop'));
    await tester.pump(); // shows "Stopping..."
    await tester.pump(); // halt future rejects; error surfaces

    // Halt failed: dialog stays, error surfaced, Stop re-enabled for a retry.
    expect(haltCalls, 1);
    expect(find.byType(GoToPositionDialog), findsOneWidget);
    expect(find.textContaining('Stop failed'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Stopping...'), findsNothing);

    // The retry really issues the halt again; this time it succeeds and closes.
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(haltCalls, 2);
    expect(find.byType(GoToPositionDialog), findsNothing);

    moveGate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('back/barrier cannot silently dismiss a moving focuser',
      (tester) async {
    var haltCalls = 0;
    final moveGate = Completer<void>();
    final haltGate = Completer<void>();
    await _openDialog(
      tester,
      initialPosition: 1000,
      maxPosition: 20000,
      onSubmit: (_) => moveGate.future, // Move stays in flight.
      onHalt: () async {
        haltCalls++;
        await haltGate.future;
      },
    );

    await tester.enterText(find.byType(TextField), '1500');
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(find.text('Moving...'), findsOneWidget);

    // Tap the modal barrier outside the dialog — the classic "click away".
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();

    // It did NOT silently close; it converted the gesture into a real halt.
    expect(find.byType(GoToPositionDialog), findsOneWidget);
    expect(haltCalls, 1);
    expect(find.text('Stopping...'), findsOneWidget);

    // Dismissal lands only once that halt actually completes.
    haltGate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(GoToPositionDialog), findsNothing);

    moveGate.complete();
    await tester.pumpAndSettle();
  });
}
