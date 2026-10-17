// Tests for the hold-to-confirm Stop button (from the
// headless-2026-05-24 audit). The widget lives in `skotiq_ui` so it can
// be reused by the shared MobilePlaybackBar, but the test home is here in
// `apps/mobile/test/widgets/` to match the audit's deliverable layout and
// because mobile is the primary consumer.
//
// We use real flutter_test gestures (longPress / startGesture) rather than
// mocking the AnimationController. The widget is its own TickerProvider, so
// pumping the test clock for the configured duration is enough to drive the
// gesture to completion.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _kHoldDuration = Duration(milliseconds: 200);

Future<void> _pumpButton(
  WidgetTester tester, {
  required VoidCallback onConfirmed,
  bool enabled = true,
  bool disableAnimations = false,
  Duration duration = _kHoldDuration,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Center(
            child: SizedBox(
              width: 240,
              height: 60,
              child: HoldToConfirmButton(
                duration: duration,
                enabled: enabled,
                onConfirmed: onConfirmed,
                confirmText: 'Hold to stop',
                child: Container(
                  color: Colors.red,
                  alignment: Alignment.center,
                  child: const Text('Stop'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // Suppress haptic-feedback channel errors in test environment — there's
  // no platform behind it. We still verify the calls happen by tracking
  // method invocations.
  final hapticCalls = <String>[];
  setUp(() {
    hapticCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            hapticCalls.add(call.arguments as String? ?? '');
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('quick tap does NOT fire onConfirmed', (tester) async {
    var confirmed = 0;
    await _pumpButton(tester, onConfirmed: () => confirmed++);

    await tester.tap(find.byType(HoldToConfirmButton));
    await tester.pumpAndSettle();

    expect(
      confirmed,
      0,
      reason: 'Single tap must never trigger destructive action.',
    );
  });

  testWidgets('hold released early does NOT fire onConfirmed', (tester) async {
    var confirmed = 0;
    await _pumpButton(tester, onConfirmed: () => confirmed++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    // Wait long enough to trigger the long-press recognizer (~500ms by
    // default in Flutter), plus half of our hold duration.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(_kHoldDuration ~/ 2);
    // Release before the ring completes.
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      confirmed,
      0,
      reason: 'Releasing before completion must cancel the gesture.',
    );
  });

  testWidgets('full-duration hold fires onConfirmed exactly once', (
    tester,
  ) async {
    var confirmed = 0;
    await _pumpButton(tester, onConfirmed: () => confirmed++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    // Wait for the long-press recognizer to fire.
    await tester.pump(const Duration(milliseconds: 600));
    // Pump well past the configured hold duration so the animation
    // controller reaches 1.0 and the status listener triggers.
    await tester.pump(_kHoldDuration);
    await tester.pump(_kHoldDuration);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      confirmed,
      1,
      reason: 'Full hold must trigger onConfirmed exactly once.',
    );
  });

  testWidgets('multiple sequential holds each trigger onConfirmed', (
    tester,
  ) async {
    var confirmed = 0;
    await _pumpButton(tester, onConfirmed: () => confirmed++);

    for (var i = 0; i < 3; i++) {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(HoldToConfirmButton)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(_kHoldDuration);
      await tester.pump(_kHoldDuration);
      await gesture.up();
      await tester.pumpAndSettle();
    }

    expect(
      confirmed,
      3,
      reason: 'Each completed hold should fire onConfirmed independently.',
    );
  });

  testWidgets('disabled button never fires onConfirmed', (tester) async {
    var confirmed = 0;
    await _pumpButton(tester, onConfirmed: () => confirmed++, enabled: false);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(_kHoldDuration);
    await tester.pump(_kHoldDuration);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(confirmed, 0, reason: 'enabled:false must block gestures.');
  });

  testWidgets('long-press cancel reverses the gesture', (tester) async {
    var confirmed = 0;
    await _pumpButton(tester, onConfirmed: () => confirmed++);

    // Start the press, get past the long-press recognizer's threshold, then
    // move the pointer far enough to trigger `onLongPressCancel` (we
    // simulate that by sending a move event that exceeds the slop after the
    // long press has not yet been recognized — easier path: just drag a
    // long distance from the start, which causes the long-press recognizer
    // to reject).
    final start = tester.getCenter(find.byType(HoldToConfirmButton));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    // Move far enough to defeat the long-press recognizer.
    await gesture.moveTo(start + const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(_kHoldDuration);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(confirmed, 0, reason: 'A cancelled long press must never confirm.');
  });

  testWidgets('animation controller is disposed when widget is removed', (
    tester,
  ) async {
    // We can't directly inspect the controller, but if it wasn't disposed
    // properly, the test framework's leak detector flags it at teardown.
    // We exercise the full hold cycle then unmount.
    var confirmed = 0;
    await _pumpButton(tester, onConfirmed: () => confirmed++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(_kHoldDuration ~/ 2);
    await gesture.up();
    await tester.pumpAndSettle();

    // Remove the widget.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    // No assertion error or pending-timer error == clean disposal.
    expect(confirmed, 0);
  });

  testWidgets('disableAnimations still requires full hold duration', (
    tester,
  ) async {
    var confirmed = 0;
    await _pumpButton(
      tester,
      onConfirmed: () => confirmed++,
      disableAnimations: true,
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    // Release early — should NOT fire even with animations disabled.
    await tester.pump(_kHoldDuration ~/ 4);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      confirmed,
      0,
      reason: 'Even with reduced motion, an early release must not confirm.',
    );

    // Now hold full duration — should fire.
    final g2 = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(_kHoldDuration);
    await tester.pump(_kHoldDuration);
    await g2.up();
    await tester.pumpAndSettle();
    expect(
      confirmed,
      1,
      reason: 'Reduced-motion path must still complete after duration.',
    );
  });

  testWidgets('full hold triggers heavy haptic feedback', (tester) async {
    var confirmed = 0;
    await _pumpButton(tester, onConfirmed: () => confirmed++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(_kHoldDuration);
    await tester.pump(_kHoldDuration);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(confirmed, 1);
    // We expect both an initial selectionClick AND a heavyImpact at
    // confirmation. The order matters: selectionClick first, then heavy.
    expect(
      hapticCalls,
      containsAllInOrder(<String>[
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.heavyImpact',
      ]),
      reason:
          'Hold start should fire a selection-click and confirmation should fire a heavy impact.',
    );
  });
}
