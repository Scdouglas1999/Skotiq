// Once a device consumes the pairing code, the desktop must stop showing it
// counting down and the paired-device list must not stay a manual refresh
// behind. POST /api/pairing/verify returns 200, the server destroys the code (a
// second verify returns invalid_pairing_code) and paired_devices goes 13 -> 14,
// so a screen still reading "Enter this code on your device: ... / Expires in
// 04:18" over 13 rows is stale.
//
// The HTTP pairing endpoint runs against the same database FILE from its own
// PairingDatabase instance, so there is no Drift stream to listen to; the
// screen has to ask. These tests drive a real in-memory PairingDatabase and let
// a second TokenManager play the server, exactly as the two instances behave in
// production.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_screen.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a consumed code stops counting down and names the device that paired',
      () async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    final notifier = PairingNotifier.withDatabase(database);
    addTearDown(() async {
      notifier.dispose();
      await database.close();
    });

    expect(await notifier.startPairing(), isTrue);
    final code = notifier.state.pairingCode;
    expect(code, isNotNull);

    // The HTTP surface completes the pairing from its own TokenManager over the
    // same file, exactly as the headless server does.
    final server = TokenManager(database);
    final result = await server.verifyPairing(
      pairingCode: code!,
      deviceId: 'audit-probe-rss',
      deviceName: 'Audit Probe',
      deviceType: 'browser',
    );
    expect(result, PairingResult.success);

    await Future<void>.delayed(const Duration(milliseconds: 1300));

    expect(
      notifier.state.pairingCode,
      isNull,
      reason: 'a destroyed credential must not keep counting down',
    );
    expect(notifier.state.expiresAt, isNull);
    expect(notifier.state.lastPairedDevice?.deviceId, 'audit-probe-rss');
    expect(
      notifier.state.pairedDevices.map((d) => d.deviceId),
      contains('audit-probe-rss'),
      reason: 'the list must not wait for a manual refresh',
    );
  });

  test('a device that re-pairs is still identified as the one that connected',
      () async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    final notifier = PairingNotifier.withDatabase(database);
    addTearDown(() async {
      notifier.dispose();
      await database.close();
    });

    final server = TokenManager(database);

    // Pair once so the device id is already known...
    expect(await notifier.startPairing(), isTrue);
    await server.verifyPairing(
      pairingCode: notifier.state.pairingCode!,
      deviceId: 'returning-phone',
      deviceName: 'Returning Phone',
    );
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(notifier.state.lastPairedDevice?.deviceId, 'returning-phone');

    // ...then pair it again. Joining on identity (deviceId + pairedAt) has to
    // find it; a "new id" or list-length test would miss it entirely.
    expect(await notifier.startPairing(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await server.verifyPairing(
      pairingCode: notifier.state.pairingCode!,
      deviceId: 'returning-phone',
      deviceName: 'Returning Phone',
    );
    await Future<void>.delayed(const Duration(milliseconds: 1300));

    expect(notifier.state.pairingCode, isNull);
    expect(notifier.state.lastPairedDevice?.deviceId, 'returning-phone');
  });

  test('an untouched code keeps its countdown', () async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    final notifier = PairingNotifier.withDatabase(database);
    addTearDown(() async {
      notifier.dispose();
      await database.close();
    });

    expect(await notifier.startPairing(), isTrue);
    final code = notifier.state.pairingCode;
    await Future<void>.delayed(const Duration(milliseconds: 1300));

    expect(notifier.state.pairingCode, code);
    expect(notifier.state.lastPairedDevice, isNull);
  });

  testWidgets('the screen swaps the dead code for a "<name> paired" banner',
      (tester) async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    late PairingNotifier notifier;
    await pumpAppScreen(
      tester,
      const PairingScreen(),
      size: const Size(900, 1400),
      settle: false,
      extraOverrides: [
        pairingProvider.overrideWith((ref) {
          notifier = PairingNotifier.withDatabase(database);
          return notifier;
        }),
      ],
    );
    addTearDown(() async => database.close());

    await tester.runAsync(() => notifier.startPairing());
    await tester.pump();
    final code = notifier.state.pairingCode!;
    expect(find.text(code), findsOneWidget);

    await tester.runAsync(
      () => TokenManager(database).verifyPairing(
        pairingCode: code,
        deviceId: 'bench-phone',
        deviceName: 'Bench Phone',
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1300)),
    );
    await tester.pump();

    expect(find.text(code), findsNothing);
    expect(find.text('Bench Phone paired'), findsOneWidget);
    expect(find.text('Bench Phone'), findsWidgets);
  });
}
