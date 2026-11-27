import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  // TalkBack read each Sequencer tab twice
  // ("Templates Templates"): the tab's label and its visible text.
  testWidgets('a tab is announced once, with its count', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: AdaptiveTabBar(
            tabs: const [
              AdaptiveTab(label: 'Builder'),
              AdaptiveTab(label: 'Saved', count: '3'),
            ],
            selectedIndex: 0,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Builder'), findsOneWidget);
    expect(find.bySemanticsLabel('Saved, 3'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Builder.*Builder', dotAll: true)),
      findsNothing,
    );
    handle.dispose();
  });
}
