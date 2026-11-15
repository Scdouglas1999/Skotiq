// The kit pieces every screen package builds on (UI plan §1, package P0).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host(Widget child, {double width = 600}) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: child),
    ),
  ),
);

Future<void> _pumpAt(WidgetTester tester, Size size, Widget child) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(child);
  await tester.pumpAndSettle();
}

void main() {
  group('SkotiqSearchField', () {
    testWidgets('is 32px tall and clears back to an empty query', (
      tester,
    ) async {
      final queries = <String>[];
      await tester.pumpWidget(
        _host(
          SkotiqSearchField(hint: 'Search targets', onChanged: queries.add),
        ),
      );

      expect(
        tester.getSize(find.byType(SkotiqTextField)).height,
        SkotiqSearchField.height,
      );
      expect(SkotiqSearchField.height, 32);
      expect(find.byTooltip('Clear search'), findsNothing);

      await tester.enterText(find.byType(TextFormField), 'M74');
      await tester.pump();
      expect(find.byTooltip('Clear search'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(queries.last, '');
      expect(find.text('M74'), findsNothing);
      expect(find.byTooltip('Clear search'), findsNothing);
    });
  });

  group('SessionPicker', () {
    final entries = <SessionPickerEntry<int>>[
      const SessionPickerEntry(value: -1, name: 'Quick captures'),
      SessionPickerEntry(
        value: 7,
        name: 'NGC 891',
        start: DateTime(2026, 11, 3, 21, 4),
        count: '120 exposures',
      ),
      SessionPickerEntry(
        value: 9,
        name: 'M74',
        start: DateTime(2026, 11, 5, 19, 40),
        count: '8 exposures',
      ),
    ];

    testWidgets('shows the chosen session as name, date and count', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SessionPicker<int>(entries: entries, value: 7, onChanged: (_) {}),
        ),
      );

      expect(find.text('Session'), findsOneWidget);
      expect(
        find.text('NGC 891  ·  Nov 3, 2026 21:04 · 120 exposures'),
        findsOneWidget,
      );
    });

    testWidgets('an entry with no date or count shows its name alone', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SessionPicker<int>(entries: entries, value: -1, onChanged: (_) {}),
        ),
      );
      expect(find.text('Quick captures'), findsOneWidget);
    });

    testWidgets('reports the value of the entry chosen from the list', (
      tester,
    ) async {
      int? chosen;
      await tester.pumpWidget(
        _host(
          SessionPicker<int>(
            entries: entries,
            value: null,
            onChanged: (v) => chosen = v,
          ),
        ),
      );
      expect(find.text('Choose a session'), findsOneWidget);

      await tester.tap(find.text('Choose a session'));
      await tester.pumpAndSettle();
      expect(find.text('Nov 5, 2026 19:40 · 8 exposures'), findsOneWidget);

      await tester.tap(find.text('M74'));
      await tester.pumpAndSettle();
      expect(chosen, 9);
    });

    testWidgets('fits a phone without overflow', (tester) async {
      await _pumpAt(
        tester,
        const Size(390, 844),
        _host(
          width: 358,
          SessionPicker<int>(entries: entries, value: 7, onChanged: (_) {}),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('AdaptiveTabBar phone rule', () {
    // Short labels, so three of them fit 390 px whatever the test font.
    const shortTabs = <AdaptiveTab>[
      AdaptiveTab(label: 'Plan', icon: Icons.star),
      AdaptiveTab(label: 'Sky', icon: Icons.public),
      AdaptiveTab(label: 'Gear', icon: Icons.build),
      AdaptiveTab(label: 'Logs', icon: Icons.list),
      AdaptiveTab(label: 'Notes', icon: Icons.notes),
      AdaptiveTab(label: 'Frame', icon: Icons.crop),
      AdaptiveTab(label: 'Moon', icon: Icons.nightlight),
    ];

    Widget bar(List<AdaptiveTab> tabs, {int selected = 0}) => MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SizedBox(
          height: 48,
          child: AdaptiveTabBar(
            tabs: tabs,
            selectedIndex: selected,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    testWidgets('keeps every label at phone width when three tabs fit', (
      tester,
    ) async {
      await _pumpAt(tester, const Size(390, 844), bar(shortTabs));
      for (final tab in shortTabs) {
        expect(find.text(tab.label), findsOneWidget, reason: tab.label);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('the selected tab keeps its label when the others collapse', (
      tester,
    ) async {
      const wide = <AdaptiveTab>[
        AdaptiveTab(label: 'Observing conditions', icon: Icons.cloud),
        AdaptiveTab(label: 'Equipment inventory', icon: Icons.build),
        AdaptiveTab(label: 'Calibration library', icon: Icons.tune),
        AdaptiveTab(label: 'Diagnostics', icon: Icons.bug_report),
      ];
      await _pumpAt(tester, const Size(360, 640), bar(wide, selected: 2));

      expect(find.text('Calibration library'), findsOneWidget);
      expect(find.text('Observing conditions'), findsNothing);
      expect(find.byTooltip('Observing conditions'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('ListRow', () {
    testWidgets('a two-line row names itself with its facts line', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var opened = 0;
      var favorited = 0;
      await tester.pumpWidget(
        _host(
          ListRow(
            title: 'NGC 891 LRGB',
            subtitle: '6 steps · 4.5 h',
            trailing: 'Nov 3',
            onTap: () => opened++,
            actions: <Widget>[
              SkotiqIconButton(
                icon: Icons.star_border,
                tooltip: 'Favorite',
                size: IconButtonSize.sm,
                onPressed: () => favorited++,
              ),
            ],
          ),
        ),
      );

      expect(
        find.bySemanticsLabel('NGC 891 LRGB, 6 steps · 4.5 h'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Favorite'), findsOneWidget);

      await tester.tap(find.byTooltip('Favorite'));
      await tester.pump();
      expect(favorited, 1);
      expect(opened, 0, reason: 'an action is not also a tap on the row');

      await tester.tap(find.text('Nov 3'));
      await tester.pump();
      expect(opened, 1);
      handle.dispose();
    });

    testWidgets('a selected row draws the accent ring', (tester) async {
      await tester.pumpWidget(
        _host(ListRow(title: 'M74', selected: true, onTap: () {})),
      );
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(ListRow),
              matching: find.byType(Container),
            )
            .first,
      );
      final border = (box.decoration! as BoxDecoration).border! as Border;
      expect(border.top.width, greaterThan(0));
      expect(border.left.width, greaterThan(0));
    });
  });

  testWidgets('EmptyState.error offers Retry', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _host(
        EmptyState.error(
          body: 'The database could not be read.',
          onRetry: () => retried++,
        ),
      ),
    );
    expect(find.text('Could not load this'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);
  });

  testWidgets('a warning banner with an action works inside an AlertDialog', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: AlertDialog(
            content: SkotiqBanner(
              tone: BannerTone.warning,
              title: 'Star catalog not installed.',
              message: 'Showing the built-in list.',
              action: SkotiqButton(
                label: 'Install',
                size: ButtonSize.small,
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Install'), findsOneWidget);
  });
}
