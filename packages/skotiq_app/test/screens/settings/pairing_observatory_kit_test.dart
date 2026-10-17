// The pairing screen was the last route-only screen still on the Material
// kit: a plain AppBar, two `Card`s, a full-width primary bar and Title Case
// copy. Wave 4 puts it on the Observatory kit. These assertions pin the parts
// a later edit is most likely to lose.
//
//   1. one 56px PageHeader ("Pairing" / context "Remote connection"), no
//      AppBar;
//   2. panels, not Material Cards;
//   3. exactly ONE primary button on the page (02 rule 4), and it is sized to
//      its label rather than stretched across the page;
//   4. the empty device list uses the single EmptyState pattern.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_screen.dart';
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
      const PairingScreen(),
      size: const Size(1280, 800),
      extraOverrides: [pairingProvider.overrideWith((ref) => notifier)],
    );
  }

  testWidgets('wears the page header, not a Material AppBar', (tester) async {
    await pumpPairing(tester);

    expect(find.byType(AppBar), findsNothing,
        reason: '04 §4 gives a screen one 56px page header');
    final header = tester.widget<PageHeader>(find.byType(PageHeader));
    expect(header.title, 'Pairing');
    expect(header.context, 'Remote connection');
  });

  testWidgets('is built from panels with one primary, sized to its label',
      (tester) async {
    await pumpPairing(tester);

    expect(find.byType(SkotiqPanel), findsNWidgets(2),
        reason: '"Pair new device" and "Paired devices" are panels');
    expect(find.byType(Card), findsNothing,
        reason: 'SkotiqPanel replaces Card for untappable containers');

    final primaries = tester
        .widgetList<SkotiqButton>(find.byType(SkotiqButton))
        .where((b) => b.variant == ButtonVariant.primary)
        .toList();
    expect(primaries.length, 1, reason: '02 rule 4: one primary per page');
    expect(primaries.single.label, 'Start pairing');

    // It was a stretched bar spanning the whole page. A button that wide reads
    // as a banner, so the fix is worth pinning: the rendered width must stay
    // well under the page.
    final width = tester
        .getSize(find.widgetWithText(SkotiqButton, 'Start pairing'))
        .width;
    expect(width, lessThan(320),
        reason: 'the primary is sized to its label, not to the page');
  });

  testWidgets('an empty device list uses the one empty-state pattern',
      (tester) async {
    await pumpPairing(tester);

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('No paired devices'), findsOneWidget);
  });
}
