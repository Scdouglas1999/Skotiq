// A run's Stop ends the run only on a completed hold; a tap does nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Future<int> pump(WidgetTester tester, {required bool enabled}) async {
    var stops = 0;
    VoidCallback? shown;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: HoldToStop(
            enabled: enabled,
            holdColor: Colors.red,
            confirmText: 'Hold to stop',
            semanticsLabel: 'Stop the sequence',
            onConfirmed: () => stops++,
            face: (onPressed) {
              shown = onPressed;
              return const Text('Stop');
            },
          ),
        ),
      ),
    );
    expect(shown == null, !enabled);
    shown?.call();
    await tester.tap(find.text('Stop'), warnIfMissed: false);
    await tester.pump(const Duration(seconds: 3));
    return stops;
  }

  testWidgets('a tap, or the drawn face, never stops', (tester) async {
    expect(await pump(tester, enabled: true), 0);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a completed hold stops once', (tester) async {
    var stops = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: HoldToStop(
            enabled: true,
            holdColor: Colors.red,
            confirmText: 'Hold to stop',
            semanticsLabel: 'Stop the sequence',
            onConfirmed: () => stops++,
            face: (_) => const SizedBox(width: 80, height: 40),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToStop)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2100));
    await gesture.up();
    await tester.pump(const Duration(seconds: 3));
    expect(stops, 1);
  });

  testWidgets('disabled, the face shows no press', (tester) async {
    expect(await pump(tester, enabled: false), 0);
    await tester.pump(const Duration(seconds: 3));
  });
}
