// Pairing is a part of Settings > Remote access, in the Settings template:
//
//   1. two groups, "Pair a device" and "Paired devices", no page header or
//      AppBar of its own;
//   2. no primary button: a Settings page acts through its rows, and Start
//      pairing is a secondary sized to its label;
//   3. the empty device list uses the single EmptyState pattern.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/paired_devices.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPairing(WidgetTester tester) async {
    final database = PairingDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final notifier = PairingNotifier.withDatabase(database);
    expect(await notifier.loadPairedDevices(), isTrue);

    await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: PairingSettings()),
      size: const Size(1280, 800),
      extraOverrides: [pairingProvider.overrideWith((ref) => notifier)],
    );
  }

  testWidgets('is two Settings groups with no header of its own',
      (tester) async {
    await pumpPairing(tester);

    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(PageHeader), findsNothing);
    expect(find.byType(SettingsSection), findsNWidgets(2));
    expect(find.text('PAIR A DEVICE'), findsOneWidget);
    expect(find.text('PAIRED DEVICES'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('has no primary, and Start pairing is sized to its label',
      (tester) async {
    await pumpPairing(tester);

    final primaries = tester
        .widgetList<SkotiqButton>(find.byType(SkotiqButton))
        .where((b) => b.variant == ButtonVariant.primary);
    expect(primaries, isEmpty);

    final start = find.widgetWithText(SkotiqButton, 'Start pairing');
    expect(tester.widget<SkotiqButton>(start).variant,
        ButtonVariant.secondary);
    expect(tester.getSize(start).width, lessThan(320));
  });

  testWidgets('an empty device list uses the one empty-state pattern',
      (tester) async {
    await pumpPairing(tester);

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('No paired devices'), findsOneWidget);
  });
}
