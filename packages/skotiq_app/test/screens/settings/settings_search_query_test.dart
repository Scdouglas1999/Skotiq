// The Settings search box must answer the words a user actually types, and
// must not send them to a page the setting is not on.
//
// Three live-observed defects are pinned here.
//
// 1. RAW SUBSTRING MATCH. `SettingsSectionDef.matches` is `contains(query)`
//    over single indexed phrases, so "capture folder" — a phrase no one row
//    title contains — returned "No settings match your search." while "folder"
//    alone returned three sections. The app's own words for that feature
//    ("capture directory" on the Dashboard, "No save path" in the status bar,
//    "free space") all missed the page that owns it.
//
// 2. CROSS-PAGE INDEX BLEED. The generated index gave 'files-storage' ~40 of
//    the Autofocus page's row titles, because both pages are declared in
//    merged_sections.dart and the generator scanned whole files. Typing
//    "Backlash" ranked Files & Storage — which has no backlash control — above
//    Autofocus.
//
// 3. INDEXED TEXT THE USER CANNOT SEE. Confirmation-dialog titles ("Delete
//    Deep-Star Tiles", "Roll back this rig?") matched, while a heading rendered
//    on screen ("GLADE+ Galaxy Catalog") did not.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/settings_search_index.g.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = defaultOnError);
}

/// Types [query] into the real Settings search box and returns the labels the
/// sidebar shows, in order. Driving the screen (rather than calling `matches`)
/// is deliberate: the tokenising and ranking live at the call site, so a test
/// that called the predicate directly would pass with the screen unwired.
Future<List<String>> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).first, query);
  await tester.pumpAndSettle();
  final results = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final text = (element.widget as Text).data;
    if (text == null) continue;
    // Sidebar results only: the detail pane starts past the 260px sidebar.
    final box = element.renderObject as RenderBox?;
    if (box == null || !box.attached) continue;
    if (box.localToGlobal(Offset.zero).dx > 260) continue;
    results.add(text);
  }
  return results;
}

Future<void> _pump(WidgetTester tester) async {
  _swallowKnownOverflows();
  await pumpAppScreen(
    tester,
    const SettingsScreen(),
    size: const Size(1280, 900),
    extraOverrides: [
      appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
    ],
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a two-word phrase finds the page that owns the setting', (
    tester,
  ) async {
    await _pump(tester);
    for (final query in const [
      'capture folder',
      'capture directory',
      'save path',
      'free space',
      'disk space',
      // Bare 'disk' was its own live repro: the Dashboard empty state says
      // "track free space" and the status bar says "No save path", yet neither
      // word — nor 'disk' on its own — reached the page that owns the setting.
      'disk',
    ]) {
      final results = await _search(tester, query);
      expect(
        results,
        contains('Files & storage'),
        reason: '"$query" must reach the page that owns the capture directory',
      );
      expect(results, isNot(contains('No settings match')));
    }
  });

  testWidgets('every token still has to match something', (tester) async {
    await _pump(tester);
    final results = await _search(tester, 'folder zzzqqqnotasetting');
    expect(results, contains('No settings match'));
  });

  testWidgets('an autofocus term does not land on Files & Storage', (
    tester,
  ) async {
    await _pump(tester);
    for (final query in const [
      'backlash',
      'v-curve',
      'curve fitting strategy',
    ]) {
      final results = await _search(tester, query);
      expect(
        results,
        isNot(contains('Files & storage')),
        reason: '"$query" is an Autofocus setting; Files & Storage has none',
      );
    }
    expect(await _search(tester, 'backlash'), contains('Autofocus'));
  });

  testWidgets('the best match is listed first', (tester) async {
    await _pump(tester);
    // 'updates' matches About (a row title) and Appliance Updates (the section
    // itself). About sits earlier in the sidebar, so only ranking can put the
    // section a user asked for at the top.
    final results = await _search(tester, 'updates');
    expect(results, contains('About'));
    expect(
      results.indexOf('Appliance updates'),
      lessThan(results.indexOf('About')),
    );
  });

  testWidgets('a heading rendered on the page is findable', (tester) async {
    await _pump(tester);
    expect(await _search(tester, 'glade'), contains('Catalogs'));
  });

  test('the index carries no text that is only inside a dialog', () {
    final unreachable = <String>[];
    for (final entry in kSettingsSearchTerms.entries) {
      for (final term in entry.value) {
        // Every one of these was a ConfirmDialog/AlertDialog title: matching
        // them made the search look like it worked while pointing at text the
        // page never renders.
        if (const {
          'Delete deep-star tiles',
          'Roll back this rig?',
          'Restore remote backup?',
          'Clear logs?',
          'Could not load profiles',
          'PHD2 executable on imaging host',
          'ASTAP executable on imaging host',
        }.contains(term)) {
          unreachable.add('${entry.key}: $term');
        }
      }
    }
    expect(unreachable, isEmpty);
  });

  test('a heading the page renders is in the index', () {
    // Sentence case, exactly as `view_builders.dart` paints it: the index is
    // generated from the page's own strings, so a title-cased literal here
    // asserts a heading the operator never sees.
    expect(
      kSettingsSearchTerms['catalogs'],
      contains('GLADE+ galaxy catalog'),
    );
    // Equipment Profiles renders its rows from `part` files; the index used to
    // hold nothing but that page's two error strings.
    expect(kSettingsSearchTerms['equipment-profiles'],
        contains('Camera defaults'));
  });
}
