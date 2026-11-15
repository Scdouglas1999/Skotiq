// The Sequencer header carries the selected tab's own save action, and every
// tab in its strip has an icon.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpOn(WidgetTester tester, SequencerTab tab) async {
    final notifier = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    notifier.state = Sequence.create(name: 'Open plan');
    await pumpAppScreen(
      tester,
      SequencerScreen(initialTab: tab),
      size: const Size(1600, 1000),
      settle: false,
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => notifier),
        savedSequenceSummariesProvider
            .overrideWith((ref) async => const <SequenceSummary>[]),
        ledgerClockProvider
            .overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
    );
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('Saved offers Save current in the header', (tester) async {
    await pumpOn(tester, SequencerTab.sequences);
    expect(find.widgetWithText(SkotiqButton, 'Save current'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Save as template'), findsNothing);
  });

  testWidgets('Templates offers Save as template in the header',
      (tester) async {
    await pumpOn(tester, SequencerTab.templates);
    expect(
      find.widgetWithText(SkotiqButton, 'Save as template'),
      findsOneWidget,
    );
    expect(find.widgetWithText(SkotiqButton, 'Save current'), findsNothing);
  });

  testWidgets('the Builder header has neither save action, and every tab has '
      'its icon', (tester) async {
    await pumpOn(tester, SequencerTab.builder);
    expect(find.widgetWithText(SkotiqButton, 'Save current'), findsNothing);
    expect(find.widgetWithText(SkotiqButton, 'Save as template'), findsNothing);
    final strip = find.byType(AdaptiveTabBar);
    for (final tab in SequencerTab.values) {
      expect(
        find.descendant(of: strip, matching: find.byIcon(tab.icon)),
        findsOneWidget,
        reason: tab.label,
      );
    }
  });
}
