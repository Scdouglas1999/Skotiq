// The Connection Status modal must not open clipped by the bottom of the
// window.
//
// Opened from the title bar at 1600x900, a panel anchored to the BOTTOM edge
// puts only its top ~75px on screen — the title, the line "Not connected to a
// server", no bottom edge and no visible control — and 1750x1040 is the same,
// because it is positioning rather than window size. Every other modal in the
// build centres.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/remote_connection_indicator.dart';

import '../harness/pump_app_screen.dart';

const _viewport = Size(1600, 900);

Future<void> _openDetails(WidgetTester tester) async {
  await pumpAppScreen(
    tester,
    const Align(
      alignment: Alignment.topRight,
      child: RemoteConnectionIndicator(compact: true),
    ),
    size: _viewport,
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 100));

  await tester.tap(find.byType(RemoteConnectionIndicator));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('connection details open as a centred dialog, fully on screen',
      (tester) async {
    await _openDetails(tester);

    expect(find.text('Connection Status'), findsOneWidget);
    expect(
      find.byType(Dialog),
      findsOneWidget,
      reason: 'a modal opened from the title bar cannot be welded to the '
          'opposite edge of the window',
    );

    final card = tester.getRect(find.byType(Dialog));
    expect(card.top, greaterThanOrEqualTo(0));
    expect(card.bottom, lessThanOrEqualTo(_viewport.height));
    expect(
      (card.center.dy - _viewport.height / 2).abs(),
      lessThan(_viewport.height * 0.1),
      reason: 'the dialog should sit near the middle, not on an edge',
    );
  });

  testWidgets('the details modal always offers a way out', (tester) async {
    await _openDetails(tester);

    expect(find.text('Close'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Connection Status'), findsNothing);
  });
}
