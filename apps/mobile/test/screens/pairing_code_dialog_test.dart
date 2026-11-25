// Submitting an EMPTY pairing code must tell the operator why nothing
// happened.
//
// A "Pair" button that renders enabled but does nothing on an empty code
// leaves a user who taps Pair before typing (or after a paste that silently
// failed) no way to tell whether the app is broken, busy, or ignoring them.
//
// A wrong-but-non-empty code surfaces the host's "The pairing code is not
// recognised." in the connect screen's error box, so only the empty case is
// pinned here — plus the happy path, so "always show an error" would not
// pass.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/main.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Pumps the dialog inside a route so `Navigator.pop` has somewhere to go, and
/// captures whatever the dialog pops.
Future<PairingDialogResult?> _pumpDialog(WidgetTester tester) async {
  PairingDialogResult? popped;
  late BuildContext ctx;

  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Builder(
        builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );

  unawaited(
    showDialog<PairingDialogResult>(
      context: ctx,
      builder: (_) => const PairingCodeDialog(host: '192.168.1.20', port: 8080),
    ).then((value) => popped = value),
  );

  await tester.pumpAndSettle();
  return popped;
}

/// The exact inline-validation string the dialog shows for a blank submit.
/// Deliberately distinct from the dialog's descriptive blurb so the finder
/// cannot accidentally match the instructions instead of the error.
const String _kEmptyCodeError = 'Enter the pairing code before tapping Pair.';

Finder _pairButton() => find.widgetWithText(SkotiqButton, 'Pair');

void main() {
  group('PairingCodeDialog empty-code validation', () {
    testWidgets('tapping Pair with a blank code shows an inline error', (
      tester,
    ) async {
      await _pumpDialog(tester);

      expect(find.byType(PairingCodeDialog), findsOneWidget);
      expect(
        find.text(_kEmptyCodeError),
        findsNothing,
        reason: 'no error before the user submits anything',
      );

      await tester.tap(_pairButton());
      await tester.pumpAndSettle();

      expect(
        find.byType(PairingCodeDialog),
        findsOneWidget,
        reason: 'an empty submit must not dismiss the dialog',
      );
      expect(
        find.text(_kEmptyCodeError),
        findsOneWidget,
        reason: 'the operator must be told why nothing happened',
      );
    });

    testWidgets('the error clears as soon as the user types', (tester) async {
      await _pumpDialog(tester);

      await tester.tap(_pairButton());
      await tester.pumpAndSettle();

      final errorFinder = find.text(_kEmptyCodeError);
      expect(errorFinder, findsOneWidget);

      await tester.enterText(find.byType(TextField), 'M');
      await tester.pumpAndSettle();

      expect(
        errorFinder,
        findsNothing,
        reason: 'stale validation must not linger while the user corrects it',
      );
    });

    testWidgets('a real code still pops the trimmed value', (tester) async {
      PairingDialogResult? popped;
      late BuildContext ctx;

      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      unawaited(
        showDialog<PairingDialogResult>(
          context: ctx,
          builder: (_) =>
              const PairingCodeDialog(host: '192.168.1.20', port: 8080),
        ).then((value) => popped = value),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '  MOON-PLUTO-7005  ');
      await tester.pumpAndSettle();
      await tester.tap(_pairButton());
      await tester.pumpAndSettle();

      expect(find.byType(PairingCodeDialog), findsNothing);
      expect(popped?.code, 'MOON-PLUTO-7005');
      expect(
        popped?.admin,
        isTrue,
        reason: 'a phone pairs with full control unless switched off',
      );
      expect(popped?.scan, isFalse);
    });
  });

  group('PairingCodeDialog choices', () {
    Future<PairingDialogResult?> open(WidgetTester tester) async {
      PairingDialogResult? popped;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      unawaited(
        showDialog<PairingDialogResult>(
          context: ctx,
          builder: (_) =>
              const PairingCodeDialog(host: '192.168.1.20', port: 8080),
        ).then((value) => popped = value),
      );
      await tester.pumpAndSettle();
      return popped;
    }

    testWidgets('Scan QR code hands off to the scanner', (tester) async {
      PairingDialogResult? popped;
      await open(tester);
      final route = ModalRoute.of(
        tester.element(find.byType(PairingCodeDialog)),
      )!;
      unawaited(route.popped.then((v) => popped = v as PairingDialogResult?));
      await tester.tap(find.widgetWithText(SkotiqButton, 'Scan QR code'));
      await tester.pumpAndSettle();
      expect(find.byType(PairingCodeDialog), findsNothing);
      expect(popped?.scan, isTrue);
    });

    testWidgets('switching full control off pairs with control only', (
      tester,
    ) async {
      PairingDialogResult? popped;
      await open(tester);
      final route = ModalRoute.of(
        tester.element(find.byType(PairingCodeDialog)),
      )!;
      unawaited(route.popped.then((v) => popped = v as PairingDialogResult?));
      await tester.tap(find.byType(SkotiqSwitch));
      await tester.enterText(find.byType(TextField), 'MOON-PLUTO-7005');
      await tester.pumpAndSettle();
      await tester.tap(_pairButton());
      await tester.pumpAndSettle();
      expect(popped?.code, 'MOON-PLUTO-7005');
      expect(popped?.admin, isFalse);
    });
  });

  testWidgets('names the computer it is pairing with', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    unawaited(
      showDialog<PairingDialogResult>(
        context: ctx,
        builder: (_) => const PairingCodeDialog(
          host: '192.168.1.32',
          port: 8080,
          serverName: 'Observatory PC',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Observatory PC · 192.168.1.32'), findsOneWidget);
  });
}
