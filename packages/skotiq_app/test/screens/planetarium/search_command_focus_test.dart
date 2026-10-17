// Regression test for the planetarium command bar's "Search ⌘K" control.
//
// Live repro: clicking it (or pressing Ctrl/Cmd+K) opened the right-hand plan
// panel on whatever tab it was last left on and stopped there. The caret was
// never placed in "Search objects, names...", so typing "Albireo" immediately
// afterwards entered nothing anywhere. Finding an object by name is the single
// most common thing anyone does in a planetarium, and it took three clicks
// before the first keystroke landed.
//
// The whole point is the WIRING, so this drives the real screen: tap the real
// command-bar control, then assert on rendered state (which tab the panel's
// controller is on, which node holds primary focus, and that typed text
// actually reaches the field).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/planetarium_screen.dart';
import 'package:skotiq_app/screens/planetarium/widgets/search_header.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../harness/harness.dart';

/// Index of the Search tab in the plan panel (Tonight/Catalog/Lists/Search/Info).
const int _searchTab = 3;

Finder get _searchField => find.descendant(
      of: find.byType(SearchHeader),
      matching: find.byType(TextField),
    );

TabController _panelTabs(WidgetTester tester) =>
    DefaultTabController.of(tester.element(find.byType(TabBarView)));

/// Harness-only noise from pumping the whole planetarium: one static GlobalKey
/// on the sky view can be momentarily double-held across a synchronous rebuild,
/// and several planetarium providers run never-stopping clocks.
bool _isHarnessArtifact(String s) =>
    s.contains('used the same GlobalKey') ||
    s.contains('after `dispose` was called') ||
    s.contains('A Timer is still pending');

void _rethrowRealFailures(WidgetTester tester) {
  final error = tester.takeException();
  if (error == null) return;
  if (_isHarnessArtifact(error.toString())) return;
  throw error;
}

/// Pumps the desktop planetarium and runs [body] against it.
Future<void> _withPlanetarium(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  SharedPreferences.setMockInitialValues(const {});
  // Wide enough that the shell takes its desktop branch (docked panels, full
  // "Search ⌘K" entry) rather than the phone sheets.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1600, 900);

  final priorOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (_isHarnessArtifact(details.exceptionAsString())) return;
    priorOnError?.call(details);
  };

  final database = mockDatabase();
  final backend = mockBackend();
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith((ref) => TestBackendNotifier(ref, backend)),
      databaseProvider.overrideWithValue(database),
      appVersionProvider.overrideWithValue(
        const AppVersionInfo(version: '0.0.0-test', buildNumber: 0),
      ),
    ],
  );

  try {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: PlanetariumScreen()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await body();
    });
    // runAsync swallows whatever [body] threw into the binding's pending
    // exception. Taking it unconditionally (as the capture harness does, where
    // only rendering noise is expected) would turn a failed assertion into a
    // PASSING test — so anything that is not known harness noise is rethrown.
    _rethrowRealFailures(tester);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await database.close();
      container.dispose();
    });
    _rethrowRealFailures(tester);
  } finally {
    FlutterError.onError = priorOnError;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

Future<void> _tapSearchCommand(WidgetTester tester) async {
  // The wide command-bar entry: an InkWell labelled "Search" carrying the
  // platform's own shortcut badge (Ctrl+K on Linux/Windows, ⌘K on macOS).
  final entry = find.ancestor(
    of: find.text(shortcutLabel('K')),
    matching: find.byType(InkWell),
  );
  expect(entry, findsOneWidget,
      reason: 'command bar should offer the Search shortcut control on '
          'desktop');
  await tester.tap(entry.first);
  // One frame to open the panel, one for the post-frame focus/tab request, and
  // one for the tab animation to commit. The bounded extra frames keep the
  // assertions off the critical path of whatever async provider work the
  // planetarium kicks off on a loaded machine.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  for (var i = 0; i < 10 && _searchField.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets(
      'the Search command opens the panel ON the Search tab with the '
      'caret in the field', (tester) async {
    await _withPlanetarium(tester, () async {
      expect(_searchField, findsNothing,
          reason: 'plan panel starts closed on desktop');

      await _tapSearchCommand(tester);

      expect(_searchField, findsOneWidget);
      expect(_panelTabs(tester).index, _searchTab,
          reason: 'a control labelled Search must land on the Search tab');
      expect(
        tester.widget<TextField>(_searchField).focusNode?.hasPrimaryFocus,
        isTrue,
        reason: 'the caret must be in the search field, ready for typing',
      );
    });
  });

  testWidgets('typing straight after the Search command reaches the field',
      (tester) async {
    await _withPlanetarium(tester, () async {
      await _tapSearchCommand(tester);

      // testTextInput.enterText types into whatever holds the text-input
      // connection, exactly like a real keyboard. tester.enterText would focus
      // the field first and so could never reproduce this.
      tester.testTextInput.enterText('Albireo');
      await tester.pump();

      expect(
          tester.widget<TextField>(_searchField).controller?.text, 'Albireo');
      expect(find.text('Albireo'), findsWidgets);
    });
  });

  testWidgets(
      'pressing Search again while the panel sits on another tab '
      'returns to Search', (tester) async {
    await _withPlanetarium(tester, () async {
      await _tapSearchCommand(tester);
      _panelTabs(tester).index = 0;
      await tester.pump();
      expect(_panelTabs(tester).index, 0);

      await _tapSearchCommand(tester);
      expect(_panelTabs(tester).index, _searchTab);
      expect(
        tester.widget<TextField>(_searchField).focusNode?.hasPrimaryFocus,
        isTrue,
      );
    });
  });
}
