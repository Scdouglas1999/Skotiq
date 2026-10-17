// Mobile Companion — Internet Reachability via Tailscale (P3).
//
// Widget tests for TailscaleSetupSheet:
//   * a tailnet host + port + scheme + token returns a TailscaleSetupResult.
//   * a non-tailnet host is rejected inline (no result popped).
//   * the https segment selects the https scheme.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/widgets/tailscale_setup_sheet.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<TailscaleSetupResult?> _showAndCapture(
  WidgetTester tester, {
  required Future<void> Function(WidgetTester) interact,
}) async {
  TailscaleSetupResult? captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: const [SkotiqColors.dark]),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await TailscaleSetupSheet.show(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await interact(tester);
  await tester.pumpAndSettle();
  return captured;
}

/// Scroll the "Connect" action into view (the sheet content can exceed the
/// 600px test viewport once the keyboard inset is applied) and tap it.
Future<void> _tapConnect(WidgetTester tester) async {
  final connect = find.text('Connect');
  await tester.ensureVisible(connect);
  await tester.pumpAndSettle();
  await tester.tap(connect);
}

void main() {
  testWidgets('valid tailnet host returns a result with the entered fields', (
    tester,
  ) async {
    final result = await _showAndCapture(
      tester,
      interact: (t) async {
        // Host field is the first SkotiqTextField (url keyboard).
        await t.enterText(find.byType(TextField).first, '100.101.102.103');
        await _tapConnect(t);
      },
    );
    expect(result, isNotNull);
    expect(result!.host, '100.101.102.103');
    expect(result.port, 8080);
    expect(result.scheme, 'http');
    expect(result.authToken, isNull);
  });

  testWidgets('https segment selects the https scheme', (tester) async {
    final result = await _showAndCapture(
      tester,
      interact: (t) async {
        await t.enterText(
          find.byType(TextField).first,
          'my-rig.tailnet.ts.net',
        );
        await t.tap(find.text('HTTPS'));
        await t.pump();
        await _tapConnect(t);
      },
    );
    expect(result, isNotNull);
    expect(result!.scheme, 'https');
    expect(result.host, 'my-rig.tailnet.ts.net');
  });

  testWidgets('a non-tailnet host is rejected inline (no result)', (
    tester,
  ) async {
    final result = await _showAndCapture(
      tester,
      interact: (t) async {
        await t.enterText(find.byType(TextField).first, '192.168.1.10');
        await _tapConnect(t);
      },
    );
    expect(
      result,
      isNull,
      reason: 'a LAN/public host must not produce a Tailscale result',
    );
    // The sheet stays open with an inline error.
    expect(find.textContaining('Not a Tailscale address'), findsOneWidget);
  });

  testWidgets('an entered token is carried through', (tester) async {
    final result = await _showAndCapture(
      tester,
      interact: (t) async {
        final fields = find.byType(TextField);
        await t.enterText(fields.first, '100.64.0.9');
        // Token field is the last SkotiqTextField in the form.
        await t.enterText(fields.last, 'bearer-xyz');
        await _tapConnect(t);
      },
    );
    expect(result, isNotNull);
    expect(result!.authToken, 'bearer-xyz');
  });
}
