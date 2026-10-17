// The Paired Devices list must say what a device's token is allowed to DO — the
// host stores it in `paired_devices.auth_grant_spec`. Rendering every row
// identically (name, device-type label, paired-on date) makes a phone holding
// 'admin' look exactly like a view-only browser, which is precisely the
// distinction you need at the moment you are deciding which row to revoke.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_screen.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('each paired device shows what its token is allowed to do',
      (tester) async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.addPairedDevice(
      deviceId: 'phone-admin',
      deviceName: 'Android companion',
      sessionToken: 'ab' * 32,
      deviceType: 'android',
      authGrantSpec: 'admin',
    );
    await database.addPairedDevice(
      deviceId: 'phone-view',
      deviceName: 'Android companion',
      sessionToken: 'cd' * 32,
      deviceType: 'android',
      authGrantSpec: 'view',
    );
    await database.addPairedDevice(
      deviceId: 'browser-custom',
      deviceName: 'Android companion',
      sessionToken: 'ef' * 32,
      deviceType: 'android',
      authGrantSpec: 'imaging:control,sequencer:view',
    );

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

    // Three rows that are otherwise word-for-word identical.
    expect(find.text('Android companion'), findsNWidgets(3));
    expect(find.text('Full access'), findsOneWidget);
    expect(find.text('View only'), findsOneWidget);
    expect(find.text('Custom access'), findsOneWidget);
  });
}
