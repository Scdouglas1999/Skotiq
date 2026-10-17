// Tests for the SavedServersScreen rename / notes / tailscale edit dialogs.
//
// Each dialog wraps its TextEditingController in a try/finally so the
// controller is disposed on every exit path. These tests guard the two ways
// that arrangement can go wrong:
//   * the controller must still be live while the dialog is open (so the typed
//     value is read on Save) — i.e. the finally must NOT dispose early; and
//   * disposal must run cleanly so a second open of the same dialog does not
//     trip a use-after-dispose.
//
// A direct "disposed exactly once" assertion would require package-wide
// leak_tracker wiring (a flutter_test_config.dart), which is out of scope for
// this screen; these behavioral round-trips exercise the new control flow end
// to end instead.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/screens/servers/saved_servers_screen.dart';
import 'package:skotiq_mobile/services/saved_servers_service.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(
  WidgetTester tester, {
  required SavedServersService service,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [savedServersServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        theme: ThemeData(extensions: const [SkotiqColors.dark]),
        home: const SavedServersScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedServersStorageKeys.migrated: true,
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  testWidgets('notes dialog saves the typed value, then reopens prefilled', (
    tester,
  ) async {
    final service = SavedServersService();
    await service.add(
      displayName: 'Observatory',
      host: '10.0.0.10',
      port: 8080,
    );
    await _pump(tester, service: service);

    // First open: type + save. If the controller were disposed before Save
    // read its text, the persisted value would be wrong / the tap would throw.
    await tester.longPress(find.text('Observatory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit notes'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Permanent pier');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Permanent pier'), findsOneWidget);
    expect((await service.loadAll()).single.notes, 'Permanent pier');

    // Second open: a clean disposal on the first close must let the dialog
    // rebuild with a fresh controller seeded from the saved notes.
    await tester.longPress(find.text('Observatory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit notes'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Permanent pier'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    // Cancel leaves the notes untouched.
    expect((await service.loadAll()).single.notes, 'Permanent pier');
  });

  testWidgets('tailscale dialog saves a valid tailnet host', (tester) async {
    final service = SavedServersService();
    await service.add(
      displayName: 'Observatory',
      host: '10.0.0.10',
      port: 8080,
    );
    await _pump(tester, service: service);

    await tester.longPress(find.text('Observatory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Tailscale address'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my-rig.tail1a2b.ts.net');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      (await service.loadAll()).single.tailscaleHost,
      'my-rig.tail1a2b.ts.net',
    );
  });

  testWidgets('rename dialog cancel leaves the display name unchanged', (
    tester,
  ) async {
    final service = SavedServersService();
    await service.add(displayName: 'Old name', host: '10.0.0.30', port: 8080);
    await _pump(tester, service: service);

    // Exercise the early-return (cancel) path through the finally so a
    // premature dispose would surface as a crash here.
    await tester.longPress(find.text('Old name'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Discarded edit');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Old name'), findsOneWidget);
    expect((await service.loadAll()).single.displayName, 'Old name');
  });
}
