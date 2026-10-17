// Regression guard for: "Dashboard Widgets picker lists two different widgets
// both called 'Guiding'".
//
// The registry holds two generations of tiles that overlap in subject matter
// (guiding, weather, equipment) and the picker rendered them as one flat list,
// so the dialog offered two rows named "Guiding" — one 'RMS error and guiding
// graph', one 'RMS and guiding graph' — with no way to tell which one a
// checkbox toggled.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout_provider.dart';
import 'package:skotiq_app/screens/dashboard/widgets/dashboard_widget_registry.dart';
import 'package:skotiq_app/screens/dashboard/widgets/widget_picker_dialog.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _DefaultLayoutNotifier extends DashboardLayoutNotifier {
  @override
  Future<DashboardLayout> build() async => DashboardLayout.defaultLayout();
}

/// Every row title the picker actually renders, in order.
List<String> _renderedRowTitles(WidgetTester tester) {
  return tester
      .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
      .map((tile) => (tile.title! as Text).data!)
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no two registry tiles share a title', () {
    final titles = dashboardWidgetRegistry.map((d) => d.title).toList();
    final duplicates = titles.toSet().where(
          (title) => titles.where((other) => other == title).length > 1,
        );
    expect(duplicates, isEmpty,
        reason: 'the picker renders definition.title verbatim, so a repeated '
            'title is a row the operator cannot identify');
  });

  testWidgets('the picker renders one uniquely named row per tile',
      (tester) async {
    // Tall enough that the whole (lazily built) list is laid out at once.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 5200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          dashboardLayoutProvider.overrideWith(_DefaultLayoutNotifier.new),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: WidgetPickerDialog()),
        ),
      ),
    );
    await tester.pump();

    final titles = _renderedRowTitles(tester);
    expect(titles.length, dashboardWidgetRegistry.length,
        reason: 'the test viewport must hold every row for this to mean '
            'anything');
    expect(titles.toSet().length, titles.length,
        reason: 'two rows with the same name is the defect');
    expect(titles, contains('Guiding'));
    expect(titles, contains('Guiding (classic)'));
  });

  testWidgets('the picker separates the two tile families', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 5200);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          dashboardLayoutProvider.overrideWith(_DefaultLayoutNotifier.new),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: WidgetPickerDialog()),
        ),
      ),
    );
    await tester.pump();

    for (final group in DashboardWidgetGroup.values) {
      expect(find.text(group.label.toUpperCase()), findsOneWidget,
          reason: 'each family needs a heading so overlapping rows are placed');
    }

    // The classic cards must all sit under the classic heading, not be
    // interleaved with the cockpit panels.
    final titles = _renderedRowTitles(tester);
    final classicTitles = dashboardWidgetRegistry
        .where((d) => d.group == DashboardWidgetGroup.classic)
        .map((d) => d.title)
        .toList();
    final firstClassic = titles.indexOf(classicTitles.first);
    expect(firstClassic, greaterThan(0));
    expect(titles.sublist(firstClassic), classicTitles);
  });
}
