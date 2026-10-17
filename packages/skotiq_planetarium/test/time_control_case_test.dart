// Every button label on the planetarium time transport uses the same register
// as the rest of the build: "Start Tour", "Maybe Later", "New Project" — never
// `button: NOW` or `button: TONIGHT`.
//
// The assertion is deliberately not "these two strings are Title case". It
// scans every button label the panel publishes and fails on ANY multi-letter
// all-caps word, so the next shouted label added to this transport fails here
// too.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/widgets/time_control_panel.dart';

Future<ProviderContainer> _pumpTransport(WidgetTester tester) async {
  final container = ProviderContainer();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: Center(child: TimeControlPanel())),
      ),
    ),
  );
  await tester.pump();
  return container;
}

List<SemanticsData> _tree(WidgetTester tester) {
  // ignore: deprecated_member_use
  final root = tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
  final out = <SemanticsData>[];
  void visit(SemanticsNode node) {
    out.add(node.getSemanticsData());
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return out;
}

/// A word of two or more letters, entirely upper case. Acronyms the app uses
/// legitimately in readouts (RA, FOV, UTC) are exempted, and this only ever
/// looks at BUTTON labels, where none of them appear.
final RegExp _shoutedWord = RegExp(r'\b[A-Z]{2,}\b');
const Set<String> _allowedAcronyms = {
  'RA',
  'DEC',
  'FOV',
  'UTC',
  'LST',
  'AM',
  'PM',
};

void main() {
  testWidgets('the jump-to-now and jump-to-tonight buttons are not shouted', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final container = await _pumpTransport(tester);

    expect(find.text('Now'), findsOneWidget);
    expect(find.text('Tonight'), findsOneWidget);
    expect(find.text('NOW'), findsNothing);
    expect(find.text('TONIGHT'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    handle.dispose();
  });

  testWidgets('no button on the time transport shouts its label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final container = await _pumpTransport(tester);

    final shouted = <String>[];
    for (final data in _tree(tester)) {
      if (!data.hasFlag(SemanticsFlag.isButton)) continue;
      if (data.label.isEmpty) continue;
      for (final match in _shoutedWord.allMatches(data.label)) {
        final word = match.group(0)!;
        if (_allowedAcronyms.contains(word)) continue;
        shouted.add('${data.label} (word "$word")');
      }
    }
    expect(
      shouted,
      isEmpty,
      reason: 'every other button in the build is Title or sentence case',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    handle.dispose();
  });
}
