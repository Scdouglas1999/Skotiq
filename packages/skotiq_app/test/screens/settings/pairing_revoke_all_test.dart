// Revoke-all. A fresh install can inherit a long list of paired devices from a
// machine-wide store, most of them allowed to control the rig, and with only the
// per-row menu to revoke one device at a time "take my rig off the network now"
// is thirteen dialogs deep.
//
// These tests drive the real notifier against a real in-memory pairing
// database, so a revoke-all that only repaints — and leaves rows the auth
// middleware still accepts — fails here.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_screen.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../../harness/harness.dart';

Future<PairingDatabase> _databaseWithThreeDevices() async {
  final database = PairingDatabase.forTesting(NativeDatabase.memory());
  await database.addPairedDevice(
    deviceId: 'phone-one',
    deviceName: 'Android companion',
    sessionToken: 'ab' * 32,
    deviceType: 'android',
  );
  await database.addPairedDevice(
    deviceId: 'phone-two',
    deviceName: 'Old iPhone',
    sessionToken: 'cd' * 32,
    deviceType: 'ios',
  );
  await database.addPairedDevice(
    deviceId: 'browser-one',
    deviceName: 'Dashboard',
    sessionToken: 'ef' * 32,
    deviceType: 'browser',
    authGrantSpec: 'admin',
  );
  return database;
}

Future<void> _pumpPairing(
  WidgetTester tester,
  PairingNotifier notifier,
) async {
  await pumpAppScreen(
    tester,
    const PairingScreen(),
    size: const Size(1200, 1600),
    extraOverrides: [
      pairingProvider.overrideWith((ref) => notifier),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('one confirmed action revokes every paired device',
      (tester) async {
    final database = await _databaseWithThreeDevices();
    addTearDown(database.close);

    // Not disposed here: the ProviderScope owns it once installed below.
    final notifier = PairingNotifier.withDatabase(database);
    expect(await notifier.loadPairedDevices(), isTrue);

    await _pumpPairing(tester, notifier);
    expect(find.text('Dashboard'), findsOneWidget);

    await tester.tap(find.text('Revoke all'));
    await tester.pumpAndSettle();

    // Destructive and irreversible for every device at once, so it asks first
    // and says how many it is about to cut off.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('3'), findsWidgets);

    await tester.tap(find.text('Revoke all access'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);

    // The stored rows are what the auth middleware trusts: every one of them
    // must be inactive, not merely absent from the painted list.
    final stillActive = await database.getActivePairedDevices();
    expect(stillActive, isEmpty,
        reason: 'Revoke All must deauthorize the stored rows, not just clear '
            'the list on screen.');
    expect(find.text('Dashboard'), findsNothing);
  });

  testWidgets('cancelling the confirmation revokes nothing', (tester) async {
    final database = await _databaseWithThreeDevices();
    addTearDown(database.close);

    final notifier = PairingNotifier.withDatabase(database);
    expect(await notifier.loadPairedDevices(), isTrue);

    await _pumpPairing(tester, notifier);

    await tester.tap(find.text('Revoke all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(await database.getActivePairedDevices(), hasLength(3));
  });

  testWidgets('with nothing paired there is nothing to revoke', (tester) async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final notifier = PairingNotifier.withDatabase(database);
    expect(await notifier.loadPairedDevices(), isTrue);

    await _pumpPairing(tester, notifier);

    expect(find.text('Revoke all'), findsNothing,
        reason: 'An enabled-looking control with nothing to act on is the '
            'silent-no-op class.');
  });
}
