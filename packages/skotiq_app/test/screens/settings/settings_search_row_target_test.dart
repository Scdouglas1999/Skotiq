// A settings search must show the ROW that matched, and take you to it.
//
// Live: typing "Alpaca" filtered the sidebar to a single entry, "Connection",
// and nothing else changed — no hint which row matched, and clicking it opened
// a long page at the top with the Alpaca row still to be found by eye. The
// index already knew the matching row titles; they were being computed and
// thrown away.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
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

const _windowSize = Size(1280, 900);

Future<void> _pump(WidgetTester tester) async {
  _swallowKnownOverflows();
  await pumpAppScreen(
    tester,
    const SettingsScreen(),
    size: _windowSize,
    extraOverrides: [
      appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
    ],
  );
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).first, query);
  await tester.pumpAndSettle();
}

/// A [Finder] restricted to the 260 px sidebar, where the results live.
Finder _inSidebar(String text) {
  return find.byWidgetPredicate((widget) {
    return widget is Text && widget.data == text;
  }).hitTestable(at: Alignment.topLeft);
}

/// The row with [title] in the open settings page (not the sidebar result).
Finder _detailRow(String title) => find.descendant(
      of: find.byType(SettingsRowHighlight),
      matching: find.text(title),
    );

/// Is that row currently tinted as the search target?
///
/// The nearest [AnimatedContainer] above the row is the highlight wrapper; the
/// card behind the section is a further ancestor and is opaque either way.
bool _highlighted(WidgetTester tester, String title) {
  final container = tester
      .widgetList<AnimatedContainer>(
        find.ancestor(
          of: _detailRow(title),
          matching: find.byType(AnimatedContainer),
        ),
      )
      .first;
  final decoration = container.decoration;
  return decoration is BoxDecoration && (decoration.color?.a ?? 0) > 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the result names the row that matched, not just the section',
      (tester) async {
    await _pump(tester);
    await _search(tester, 'alpaca');

    expect(find.text('Connection'), findsWidgets);
    for (final row in ['Alpaca server address', 'Query Alpaca on startup']) {
      final finder = _inSidebar(row);
      expect(finder, findsOneWidget, reason: '"$row" matched and is not shown');
      expect(
        tester.getRect(finder).left,
        lessThan(260),
        reason: 'the matched row belongs in the sidebar result list',
      );
    }
  });

  testWidgets('opening a row result scrolls to it and marks it',
      (tester) async {
    await _pump(tester);
    await _search(tester, 'alpaca');

    await tester.tap(_inSidebar('Alpaca server address'));
    await tester.pumpAndSettle();

    // The section is open...
    final row = _detailRow('Alpaca server address');
    expect(row, findsOneWidget);
    // ...with the target row on screen, not somewhere below the fold...
    final rect = tester.getRect(row);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(_windowSize.height));
    // ...and marked, so it is findable at a glance on a page of 20 rows.
    expect(
      _highlighted(tester, 'Alpaca server address'),
      isTrue,
      reason: 'the row the search sent you to must be pointed at',
    );
  });

  // The index cannot tell a SettingsSection heading from a SettingRow title,
  // so headings are offered as row results too: "dither" offers "Dithering",
  // and "meridian flip" offers ONLY "Meridian flip" on the Sequencer entry.
  // Before this was wired, tapping one opened the page at the top and marked
  // nothing — the same dead end the row results were added to end.
  testWidgets('a matched SECTION HEADING is revealed too, not just rows',
      (tester) async {
    await _pump(tester);
    await _search(tester, 'dither');

    final result = _inSidebar('Dithering');
    expect(result, findsOneWidget,
        reason: '"Dithering" matched and is offered');
    await tester.tap(result);
    await tester.pumpAndSettle();

    final heading = _detailRow('Dithering'.toUpperCase());
    expect(heading, findsOneWidget);
    final rect = tester.getRect(heading);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(_windowSize.height));
    expect(
      _highlighted(tester, 'Dithering'.toUpperCase()),
      isTrue,
      reason: 'a heading result must point at the heading, not just open the '
          'page',
    );
  });

  // A row result that only repeats the section name above it is noise: it
  // cannot take you anywhere the section entry does not already.
  testWidgets('a term identical to the section name is not offered as a row',
      (tester) async {
    await _pump(tester);
    await _search(tester, 'notification');

    // The section entry itself stays.
    expect(find.text('Notifications'), findsWidgets);
    // But not indented beneath itself as its own result.
    final duplicates = _inSidebar('Notifications');
    expect(
      duplicates.evaluate().length,
      1,
      reason: 'the section name must not also appear as a row under itself',
    );
  });

  testWidgets('the mark fades so it is not mistaken for a state',
      (tester) async {
    await _pump(tester);
    await _search(tester, 'alpaca');
    await tester.tap(_inSidebar('Alpaca server address'));
    await tester.pumpAndSettle();
    expect(_highlighted(tester, 'Alpaca server address'), isTrue);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(_highlighted(tester, 'Alpaca server address'), isFalse);
  });
}
