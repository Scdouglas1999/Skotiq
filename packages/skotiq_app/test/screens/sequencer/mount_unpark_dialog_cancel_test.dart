// Cancel has to beat the countdown in every window it is offered in.
//
// The dialog disabled "Cancel Sequence" for the whole `unpark()` round-trip,
// so once the timer expired there was no way to stop the start: the button
// went dead and the sequence began. Live, a press about a second before expiry
// looked exactly like a cancel that had been ignored.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mount_unpark_dialog.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// An unpark that never finishes until the test says so, so the window in
/// which the old dialog was uncancellable can actually be entered.
class _PendingUnparkService extends MountCommandService {
  _PendingUnparkService(super.ref);

  final Completer<CommandActionResult> gate = Completer();
  var calls = 0;

  @override
  Future<CommandActionResult> unpark() {
    calls++;
    return gate.future;
  }
}

class _ParkedMountNotifier extends MountStateNotifier {
  _ParkedMountNotifier(super.ref) {
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim-mount',
      deviceName: 'Simulated Mount',
      isParked: true,
    );
  }
}

void _swallowLayoutOverflow() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = defaultOnError);
}

void main() {
  /// Null until the dialog first reads the provider, which it only does when
  /// the countdown expires — so "still null" is itself the assertion that no
  /// unpark was attempted.
  _PendingUnparkService? unparkService;
  var unparked = 0;
  var cancelled = 0;

  Future<void> pump(WidgetTester tester, {int countdownSeconds = 2}) async {
    _swallowLayoutOverflow();
    unparkService = null;
    unparked = 0;
    cancelled = 0;
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => MountUnparkDialog(
          countdownSeconds: countdownSeconds,
          onUnparkAndContinue: () => unparked++,
          onCancel: () => cancelled++,
        ),
      ),
      size: const Size(1200, 1200),
      settle: false,
      extraOverrides: [
        mountStateProvider.overrideWith(_ParkedMountNotifier.new),
        mountCommandServiceProvider.overrideWith((ref) {
          final service = _PendingUnparkService(ref);
          unparkService = service;
          return service;
        }),
      ],
    );
    await tester.pump();
  }

  testWidgets('Cancel inside the countdown stops the start', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Cancel sequence'));
    await tester.pump();

    expect(cancelled, 1);
    expect(unparked, 0);

    // And the expired timer must not resurrect the start behind it.
    await tester.pump(const Duration(seconds: 5));
    expect(unparked, 0);
    expect(unparkService, isNull,
        reason: 'a cancelled countdown must never reach the mount');
  });

  testWidgets('Cancel still wins after the countdown has fired',
      (tester) async {
    await pump(tester, countdownSeconds: 1);

    // Let the countdown expire. The unpark is now in flight and unresolved.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(unparkService?.calls, 1);
    expect(unparked, 0, reason: 'the unpark has not come back yet');

    // The operator presses Cancel during the mount round-trip. This press used
    // to hit a disabled button and change nothing.
    await tester.tap(find.text('Cancel sequence'));
    await tester.pump();
    expect(cancelled, 1);

    // The unpark now succeeds — and must NOT start the sequence anyway.
    unparkService!.gate.complete(CommandActionResult.ok);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(unparked, 0,
        reason: 'a cancel that lands during the unpark must abort the start');
  });
}
