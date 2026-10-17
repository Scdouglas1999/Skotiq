// The Paired Devices list must be a list the operator can tell apart. Every
// phone pairs under a fixed per-platform name ("Android companion" —
// apps/mobile/lib/services/mobile_pairing_service.dart), so a household with
// three handsets gets three byte-identical rows and revoking the phone that was
// sold is guesswork. The host owns the name column, so the host is where that is
// settled: these tests drive the real notifier against a real in-memory pairing
// database, so a rename that only repaints — and never reaches the row that
// survives a restart — fails here.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_screen.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../../harness/harness.dart';

Future<PairingDatabase> _databaseWithTwoIdenticalPhones() async {
  final database = PairingDatabase.forTesting(NativeDatabase.memory());
  await database.addPairedDevice(
    deviceId: 'phone-one',
    deviceName: 'Android companion',
    sessionToken: 'ab' * 32,
    deviceType: 'android',
  );
  await database.addPairedDevice(
    deviceId: 'phone-two',
    deviceName: 'Android companion',
    sessionToken: 'cd' * 32,
    deviceType: 'android',
  );
  return database;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a paired device can be renamed, and the new name persists',
      (tester) async {
    final database = await _databaseWithTwoIdenticalPhones();
    addTearDown(database.close);

    // Not disposed here: the ProviderScope owns it once it is installed below.
    final notifier = PairingNotifier.withDatabase(database);
    expect(await notifier.loadPairedDevices(), isTrue);

    await pumpAppScreen(
      tester,
      const PairingScreen(),
      size: const Size(1200, 1600),
      extraOverrides: [
        pairingProvider.overrideWith((ref) => notifier),
      ],
    );

    expect(find.text('Android companion'), findsNWidgets(2));

    // Open the row menu on the FIRST device and rename it.
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Rename device'), findsOneWidget);
    await tester.tap(find.text('Rename device'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), "Sean's Pixel");
    // Return commits: this dialog is one pre-filled field, and reaching for the
    // mouse to leave it is the thing that makes it slow.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // The dialog is gone and the list now distinguishes the two rows.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text("Sean's Pixel"), findsOneWidget);
    expect(find.text('Android companion'), findsOneWidget);

    // And it is the stored row that changed, not just the painted one.
    final stored = await database.getPairedDevice('phone-one');
    expect(stored!.deviceName, "Sean's Pixel");
    // The rename is cosmetic: the token and grant a live connection depends on
    // are untouched.
    expect(stored.sessionToken, 'ab' * 32);
    expect(stored.authGrantSpec, 'control');
    final untouched = await database.getPairedDevice('phone-two');
    expect(untouched!.deviceName, 'Android companion');
  });

  testWidgets('an empty name is refused rather than written', (tester) async {
    final database = await _databaseWithTwoIdenticalPhones();
    addTearDown(database.close);

    final notifier = PairingNotifier.withDatabase(database);
    expect(await notifier.loadPairedDevices(), isTrue);

    await pumpAppScreen(
      tester,
      const PairingScreen(),
      size: const Size(1200, 1600),
      extraOverrides: [
        pairingProvider.overrideWith((ref) => notifier),
      ],
    );

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename device'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // Still open, and the row is unchanged: a blank label would be less
    // identifiable than the duplicate it was meant to fix.
    expect(find.byType(AlertDialog), findsOneWidget);
    final stored = await database.getPairedDevice('phone-one');
    expect(stored!.deviceName, 'Android companion');
  });
}
