// Help & Tutorials speaks ONE dialect. Beyond the verb (every row starts
// something, so every button says "Start"), two splits are easy to reintroduce:
//
//   (a) row titles mixing Title Case and sentence case in one list —
//       "First Night Walkthrough", "Capture your first light",
//       "Re-run equipment setup", "Re-run onboarding tour",
//       "Generate Diagnostic Dump";
//   (b) two button treatments for that one verb — the five Tutorial Tours rows
//       rendering FILLED BLUE "Start" buttons directly beneath the five OUTLINE
//       "Start" buttons of Guided Flows.
//
// Both are asserted on the RENDERED page, and (a) is additionally guarded
// mechanically over the widget's own source so a new row cannot reintroduce the
// split by adding a sixth Title Case title.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/settings/settings_search_index.g.dart';
import 'package:skotiq_app/screens/settings/widgets/help_tutorials_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

SkotiqDatabase _newInMemoryDb() =>
    SkotiqDatabase.forTesting(NativeDatabase.memory());

Future<ProviderContainer> _pumpHelpScreen(
  WidgetTester tester, {
  required SkotiqDatabase db,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 1400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => TestBackendNotifier(ref, mockBackend()),
      ),
      databaseProvider.overrideWithValue(db),
      appVersionProvider.overrideWithValue(
        const AppVersionInfo(version: '0.0.0-test', buildNumber: 0),
      ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: '/help',
    routes: [
      GoRoute(
        path: '/help',
        builder: (context, state) =>
            const Scaffold(body: HelpTutorialsSettings()),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(seconds: 5));
  return container;
}

/// The verbs a row uses for "run this thing". All of them must be drawn the
/// same way on one page.
const Set<String> _runVerbs = {'Start', 'Resume', 'Restart'};

/// Title Case = two or more capitalised words. Words that are capitalised
/// because they are proper nouns of the product are exempt.
const Set<String> _properNouns = {
  'Skotiq',
  'PHD2',
  'ASCOM',
  'INDI',
  'Alpaca',
};

bool _isTitleCase(String title) {
  final words =
      title.split(RegExp(r'[\s/]+')).where((w) => w.isNotEmpty).toList();
  if (words.length < 2) return false;
  var capitalised = 0;
  for (var i = 1; i < words.length; i++) {
    final w = words[i];
    if (_properNouns.contains(w)) continue;
    if (w[0] == w[0].toUpperCase() && w[0] != w[0].toLowerCase()) {
      capitalised++;
    }
  }
  return capitalised > 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every row title on the page is in one case register', (
    tester,
  ) async {
    final db = _newInMemoryDb();
    addTearDown(() async => db.close());
    await _pumpHelpScreen(tester, db: db);

    for (final title in const [
      'First night walkthrough',
      'Capture your first light',
      'Re-run equipment setup',
      'Re-run onboarding tour',
      'Generate diagnostic dump',
      'Equipment setup',
      'Target planning',
      'Automated imaging',
      'Calibration frames',
      'Advanced features',
      'Reset all progress',
      'Enable tutorials',
    ]) {
      expect(find.text(title), findsOneWidget, reason: 'missing row "$title"');
    }
    // These are the OLD Title Case forms, held here as NEGATIVES: the page
    // must not have drifted back into a second register. My sentence-case
    // sweep's mechanical finder repair rewrote them into the sentence forms
    // the list above already asserts, which made the test contradict itself.
    for (final shouted in const [
      'First Night Walkthrough',
      'Generate Diagnostic Dump',
      'Equipment Setup',
      'Calibration Frames',
      'Reset All Progress',
    ]) {
      expect(
        find.text(shouted),
        findsNothing,
        reason: '"$shouted" is a second register',
      );
    }
  });

  testWidgets('one verb is drawn one way across the whole page', (
    tester,
  ) async {
    final db = _newInMemoryDb();
    addTearDown(() async => db.close());
    await _pumpHelpScreen(tester, db: db);

    final buttons = tester
        .widgetList<SkotiqButton>(find.byType(SkotiqButton))
        .where((b) => _runVerbs.contains(b.label))
        .toList();
    expect(
      buttons.length,
      greaterThanOrEqualTo(10),
      reason: 'five Guided Flows rows + five Tutorial Tours rows',
    );
    final variants = buttons.map((b) => b.variant).toSet();
    expect(
      variants,
      hasLength(1),
      reason: 'the Tutorial Tours "Start" must not render filled-primary '
          'directly beneath the secondary "Start" of Guided flows',
    );
    expect(variants.single, ButtonVariant.secondary);
  });

  test('no row title in the widget source is Title Case', () {
    final source = File(
      'lib/screens/settings/widgets/help_tutorials_settings.dart',
    ).readAsStringSync();
    final offenders = <String>[];
    for (final match in RegExp(
      r"^\s*title: '([^']+)',",
      multiLine: true,
    ).allMatches(source)) {
      final title = match.group(1)!;
      if (_isTitleCase(title)) offenders.add(title);
    }
    // The four SECTION headers used to be the allowed exceptions, on the
    // grounds that headers stayed Title Case app-wide. 06's copy rules ended
    // that — sentence case everywhere, headers included — so the list is now
    // empty and there is no exception left to enumerate.
    expect(
      offenders,
      isEmpty,
      reason: 'sentence case everywhere (06 §Copy rules), headers included',
    );
  });

  test('the generated settings search index carries the new titles', () {
    final help = kSettingsSearchTerms['help'];
    expect(help, isNotNull, reason: 'the Help section must be indexed');
    expect(help, contains('First night walkthrough'));
    expect(help, contains('Generate diagnostic dump'));
    expect(
      help,
      isNot(contains('First Night Walkthrough')),
      reason: 'a stale index makes the row unfindable by its visible name',
    );
  });
}
