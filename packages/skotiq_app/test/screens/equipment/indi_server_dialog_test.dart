// Focused tests for [IndiServerDialog] — the INDI server host/port
// configuration surface reachable from Settings → Connection → Discovery.
//
// These lock in the connection-truth fixes:
//   * host/port are validated (no silent coercion of a malformed port to
//     7624, no blank host, no out-of-range port),
//   * a late settings hydration must not clobber an edit the operator made
//     while the load was in flight,
//   * a successful save persists the address and returns it to the caller.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/indi_server_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// Overrides [AppSettingsNotifier.build] to return a fixed state after an
/// optional [gate] resolves. The gate lets a test hold hydration open so it
/// can prove that a late-arriving load does not overwrite user edits.
class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial, {Future<void>? gate}) : _gate = gate;
  final AppSettingsState _initial;
  final Future<void>? _gate;

  @override
  Future<AppSettingsState> build() async {
    if (_gate != null) {
      await _gate;
    }
    return _initial;
  }
}

/// A host with a button that opens [IndiServerDialog] as a real pushed route
/// (so `Navigator.pop` on save behaves like production). Captures the dialog
/// result for save-path assertions.
class _DialogHost extends StatelessWidget {
  const _DialogHost({required this.onResult});
  final void Function(Map<String, dynamic>?) onResult;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(
        onPressed: () async {
          final result = await showDialog<Map<String, dynamic>>(
            context: context,
            builder: (_) => const IndiServerDialog(),
          );
          onResult(result);
        },
        child: const Text('open-indi'),
      ),
    );
  }
}

Finder get _hostField => find.byKey(const ValueKey('indi-host-field'));
Finder get _portField => find.byKey(const ValueKey('indi-port-field'));

/// The value currently in [field]. The key sits on the design system's
/// `SkotiqTextField`, so the controller is read from the [TextField] it
/// builds underneath rather than from the keyed widget itself.
String _text(WidgetTester tester, Finder field) => tester
    .widget<TextField>(
      find.descendant(of: field, matching: find.byType(TextField)),
    )
    .controller!
    .text;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<HarnessHandle> openDialog(
    WidgetTester tester, {
    required AppSettingsState initial,
    Future<void>? gate,
    void Function(Map<String, dynamic>?)? onResult,
  }) async {
    final handle = await pumpAppScreen(
      tester,
      _DialogHost(onResult: onResult ?? (_) {}),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(initial, gate: gate),
        ),
      ],
      // A gated hydration never settles; a bare pump keeps the test in control.
      settle: gate == null,
    );
    await tester.tap(find.text('open-indi'));
    await tester.pump();
    return handle;
  }

  testWidgets('rejects a blank host without persisting or closing',
      (tester) async {
    await openDialog(
      tester,
      initial: const AppSettingsState(
          indiServerHost: 'localhost', indiServerPort: 7624),
    );
    await tester.pumpAndSettle();

    await tester.enterText(_hostField, '   ');
    await tester.enterText(_portField, '7624');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a host name or IP address.'), findsOneWidget);
    // Still open — a failed validation must not dismiss the dialog.
    expect(find.byType(IndiServerDialog), findsOneWidget);
  });

  testWidgets('rejects an out-of-range port instead of coercing to 7624',
      (tester) async {
    await openDialog(
      tester,
      initial: const AppSettingsState(
          indiServerHost: 'localhost', indiServerPort: 7624),
    );
    await tester.pumpAndSettle();

    await tester.enterText(_hostField, 'indi.local');
    await tester.enterText(_portField, '70000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Port must be between 1 and 65535.'), findsOneWidget);
    expect(find.byType(IndiServerDialog), findsOneWidget);
  });

  testWidgets('rejects a non-numeric port', (tester) async {
    await openDialog(
      tester,
      initial: const AppSettingsState(
          indiServerHost: 'localhost', indiServerPort: 7624),
    );
    await tester.pumpAndSettle();

    await tester.enterText(_hostField, 'indi.local');
    await tester.enterText(_portField, 'abc');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Port must be a whole number.'), findsOneWidget);
    expect(find.byType(IndiServerDialog), findsOneWidget);
  });

  testWidgets('late settings hydration does not overwrite user edits',
      (tester) async {
    final gate = Completer<void>();
    await openDialog(
      tester,
      // Persisted values differ from what the user is about to type; if the
      // late load clobbered edits, we would see these instead.
      initial: const AppSettingsState(
          indiServerHost: 'persisted.host', indiServerPort: 1234),
      gate: gate.future,
    );

    // Hydration is still pending: the fields show the initial defaults.
    expect(_text(tester, _hostField), 'localhost');

    // The operator types while the load is in flight.
    await tester.enterText(_hostField, 'user.typed.host');
    await tester.enterText(_portField, '9000');
    await tester.pump();

    // Settings finally arrive.
    gate.complete();
    await tester.pumpAndSettle();

    expect(_text(tester, _hostField), 'user.typed.host',
        reason: 'A late settings load must not overwrite a user edit.');
    expect(_text(tester, _portField), '9000');
  });

  testWidgets('a valid save persists the address and returns it',
      (tester) async {
    Map<String, dynamic>? result;
    final handle = await openDialog(
      tester,
      initial: const AppSettingsState(
          indiServerHost: 'localhost', indiServerPort: 7624),
      onResult: (r) => result = r,
    );
    await tester.pumpAndSettle();

    await tester.enterText(_hostField, '192.168.1.50');
    await tester.enterText(_portField, '7625');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Dialog closed and returned the saved values.
    expect(find.byType(IndiServerDialog), findsNothing);
    expect(result, {'host': '192.168.1.50', 'port': 7625});

    // Persisted into settings state.
    final settings = handle.container.read(appSettingsProvider).valueOrNull;
    expect(settings?.indiServerHost, '192.168.1.50');
    expect(settings?.indiServerPort, 7625);
  });
}
