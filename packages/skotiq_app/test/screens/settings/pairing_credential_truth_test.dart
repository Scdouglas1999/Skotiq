// Three claims the Manage Pairing page has to get right.
//
// 1. The pairing credential must reach ACCESSIBILITY. A SelectableText
//    publishes its text as a semantic value rather than a name, so a screen
//    reader is told a code exists and never told what it is — and the QR is an
//    image, so this text is the only non-visual path to pairing a phone.
// 2. The green "<name> paired" banner must not survive revoking that device,
//    which would put "… paired" above "No paired devices".
// 3. The revoke confirmation must agree with the count: "all 1 paired devices"
//    is not a sentence about one device.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_screen.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../../harness/harness.dart';

/// Every accessible NAME published anywhere in the tree.
List<String> _semanticLabels(WidgetTester tester) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    final label = node.getSemanticsData().label;
    if (label.isNotEmpty) labels.add(label);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return labels;
}

Future<PairingNotifier> _pumpPairing(
  WidgetTester tester,
  PairingDatabase database,
) async {
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
  await tester.pump();
  return notifier;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the pairing code is readable by a screen reader',
      (tester) async {
    final handle = tester.ensureSemantics();
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => database.close());

    final notifier = await _pumpPairing(tester, database);
    await tester.runAsync(notifier.startPairing);
    await tester.pump();

    final code = notifier.state.pairingCode!;
    expect(find.text(code), findsOneWidget, reason: 'it is on screen');
    expect(
      _semanticLabels(tester).where((l) => l.contains(code)),
      isNotEmpty,
      reason: 'the credential must have an accessible name, not only a value',
    );
    handle.dispose();
  });

  testWidgets('revoking the device takes its banner with it', (tester) async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => database.close());

    final notifier = await _pumpPairing(tester, database);
    await tester.runAsync(notifier.startPairing);
    await tester.pump();

    await tester.runAsync(
      () => TokenManager(database).verifyPairing(
        pairingCode: notifier.state.pairingCode!,
        deviceId: 'waved-test-phone',
        deviceName: 'WaveD Test Phone',
        deviceType: 'android',
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1300)),
    );
    await tester.pump();
    expect(find.text('WaveD Test Phone paired'), findsOneWidget);

    await tester.runAsync(notifier.revokeAll);
    await tester.pump();

    expect(
      find.text('WaveD Test Phone paired'),
      findsNothing,
      reason: 'the page cannot say a device is paired beside "No paired '
          'devices"',
    );
    expect(find.text('No paired devices'), findsOneWidget);
  });

  testWidgets('one device is not "all 1 paired devices"', (tester) async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    await database.addPairedDevice(
      deviceId: 'phone-one',
      deviceName: 'WaveD Test Phone',
      sessionToken: 'ab' * 32,
      deviceType: 'android',
    );
    addTearDown(() async => database.close());

    final notifier = await _pumpPairing(tester, database);
    expect(await tester.runAsync(notifier.loadPairedDevices), isTrue);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Revoke all'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('all 1 paired devices'), findsNothing);
    expect(find.textContaining('WaveD Test Phone'), findsWidgets);
    // The action behind it is unchanged — revoking every row — and is covered
    // by pairing_revoke_all_test.dart; what is under test here is the sentence
    // the operator has to agree to.
    expect(find.text('Revoke access'), findsOneWidget);
  });

  testWidgets('the plural form survives for a real "all"', (tester) async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    for (final id in const ['one', 'two', 'three']) {
      await database.addPairedDevice(
        deviceId: id,
        deviceName: 'Phone $id',
        sessionToken: id.padRight(64, '0'),
        deviceType: 'android',
      );
    }
    addTearDown(() async => database.close());

    final notifier = await _pumpPairing(tester, database);
    expect(await tester.runAsync(notifier.loadPairedDevices), isTrue);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Revoke all'));
    await tester.pumpAndSettle();
    expect(find.textContaining('all 3 paired devices'), findsOneWidget);
  });
}
