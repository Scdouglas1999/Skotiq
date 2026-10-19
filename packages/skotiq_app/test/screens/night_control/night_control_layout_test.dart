// The Tonight layout's column sets at the sizes that matter: the owner's
// window with the rail collapsed (1480) and expanded (1316), a medium window
// where the plan becomes a drawer (1000), a narrow desktop window (700) and a
// phone (390).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/night_control_layout.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'fixtures/night_fixtures.dart';

const _header = Key('header');
const _left = Key('left');
const _center = Key('center');
const _panel = Key('panel');

/// A slot body that behaves like the real ones: it scrolls itself in the
/// column modes and sizes to its content in the single column.
class _Slot extends StatelessWidget {
  const _Slot({super.key, required this.name, this.rows = 30});

  final String name;
  final int rows;

  @override
  Widget build(BuildContext context) {
    final density = NightControlDensity.of(context);
    final children = <Widget>[
      for (var i = 0; i < rows; i++)
        SizedBox(height: 24, child: Text('$name $i')),
    ];
    if (density.slotsScrollThemselves) {
      return ListView(children: children);
    }
    return Column(children: children);
  }
}

/// Records the density the layout published.
class _Probe extends StatelessWidget {
  const _Probe(this.onDensity);

  final ValueChanged<NightControlDensity> onDensity;

  @override
  Widget build(BuildContext context) {
    onDensity(NightControlDensity.of(context));
    return const SizedBox(height: 40, child: Text('Tonight'));
  }
}

Future<NightControlDensity> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late NightControlDensity density;
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
      supportedLocales: SkotiqLocalizations.supportedLocales,
      home: Scaffold(
        body: NightControlLayout(
          header: KeyedSubtree(
            key: _header,
            child: _Probe((d) => density = d),
          ),
          left: const _Slot(key: _left, name: 'plan'),
          center: const _Slot(key: _center, name: 'frame', rows: 12),
          panel: const _Slot(key: _panel, name: 'panel'),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
  return density;
}

Rect _rect(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));

bool _visible(WidgetTester tester, Key key) =>
    find.byKey(key).hitTestable().evaluate().isNotEmpty;

void main() {
  for (final size in const <Size>[Size(1480, 806), Size(1316, 806)]) {
    testWidgets('${size.width.toInt()}x${size.height.toInt()}: three columns',
        (tester) async {
      final density = await _pump(tester, size);

      expect(density.mode, NightControlMode.threeColumn);
      expect(density.openPlanDrawer, isNull);
      expect(density.compactHeight, isFalse);
      expect(density.slotsScrollThemselves, isTrue);
      expect(density.centerWidth, size.width - 272 - 300);

      final header = _rect(tester, _header);
      final left = _rect(tester, _left);
      final center = _rect(tester, _center);
      final panel = _rect(tester, _panel);
      expect(left.left, 0);
      expect(left.width, NightControlLayout.leftWidth);
      expect(panel.width, NightControlLayout.panelWidth);
      expect(panel.right, size.width);
      expect(center.left, left.right);
      expect(center.right, panel.left);
      expect(left.top, greaterThanOrEqualTo(header.bottom));
      expect(left.bottom, size.height);
      expect(_visible(tester, _left), isTrue);
    });
  }

  testWidgets('1316 wide: the owner window leaves a 744 px center',
      (tester) async {
    final density = await _pump(tester, const Size(1316, 806));
    expect(density.centerWidth, 744);
    expect(density.collapseActionHint, isTrue);
    expect(density.hideActionSubLabels, isTrue);
    expect(density.chartRowHeight, NightControlLayout.chartRowHeight);
  });

  testWidgets('a body under 720 px tall shrinks the chart row', (tester) async {
    final density = await _pump(tester, const Size(1316, 700));
    expect(density.compactHeight, isTrue);
    expect(density.chartRowHeight, NightControlLayout.compactChartRowHeight);
  });

  testWidgets('1000x806: the plan becomes a drawer', (tester) async {
    var density = await _pump(tester, const Size(1000, 806));

    expect(density.mode, NightControlMode.planDrawer);
    expect(density.planDrawerOpen, isFalse);
    expect(density.centerWidth, 700);
    expect(_visible(tester, _left), isFalse);
    expect(_rect(tester, _center).left, 0);
    expect(_rect(tester, _panel).width, NightControlLayout.panelWidth);

    density.openPlanDrawer!();
    await tester.pump();
    await tester.pump();
    density = NightControlDensity.of(
      tester.element(find.byKey(_header)),
    );
    expect(density.planDrawerOpen, isTrue);
    expect(_visible(tester, _left), isTrue);
    expect(_rect(tester, _left).width, NightControlLayout.leftWidth);
    expect(find.bySemanticsLabel('Close plan'), findsOneWidget);

    // Escape closes it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_visible(tester, _left), isFalse);

    // So does a tap on the scrim beside it.
    NightControlDensity.of(tester.element(find.byKey(_header)))
        .openPlanDrawer!();
    await tester.pump();
    await tester.tapAt(const Offset(600, 400));
    await tester.pump();
    expect(_visible(tester, _left), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the drawer closes itself when the window widens',
      (tester) async {
    final density = await _pump(tester, const Size(1000, 806));
    density.openPlanDrawer!();
    await tester.pump();

    tester.view.physicalSize = const Size(1316, 806);
    await tester.pump();
    expect(find.bySemanticsLabel('Close plan'), findsNothing);
    expect(_rect(tester, _left).left, 0);
    expect(_visible(tester, _left), isTrue);
  });

  for (final size in const <Size>[Size(700, 800), Size(390, 844)]) {
    testWidgets(
        '${size.width.toInt()}x${size.height.toInt()}: one scrolling column',
        (tester) async {
      final density = await _pump(tester, size);

      expect(density.mode, NightControlMode.singleColumn);
      expect(density.slotsScrollThemselves, isFalse);
      expect(density.openPlanDrawer, isNull);
      expect(density.centerWidth, size.width);

      // Header, center, panel, then the plan, each full width.
      final header = _rect(tester, _header);
      final center = _rect(tester, _center);
      final panel = _rect(tester, _panel);
      final left = _rect(tester, _left);
      expect(header.top, lessThan(center.top));
      expect(center.top, lessThan(panel.top));
      expect(panel.top, lessThan(left.top));
      for (final r in <Rect>[center, panel, left]) {
        expect(r.width, size.width);
      }

      // The page scrolls down to the plan.
      await tester.dragUntilVisible(
        find.text('plan 29'),
        find.byType(SingleChildScrollView),
        const Offset(0, -300),
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('the board fixtures build and compare by value', () {
    for (final build in <NightBoard Function()>[
      NightFixtures.running,
      NightFixtures.ready,
      NightFixtures.autofocus,
    ]) {
      final a = build();
      final b = build();
      expect(a.header, b.header);
      expect(a.header.hashCode, b.header.hashCode);
      expect(a.timeline, b.timeline);
      expect(a.target, b.target);
      expect(a.plan, b.plan);
      expect(a.steps, b.steps);
      expect(a.frameSeries, b.frameSeries);
      expect(a.lastFrame, b.lastFrame);
      expect(a.actions, b.actions);
    }
    expect(NightFixtures.running().header, isNot(NightFixtures.ready().header));
    expect(
      NightFixtures.autofocus().header.pausedFor,
      ManualActionId.autofocus,
    );
  });

  test('every action selects the tab the plan names', () {
    expect(ManualActionId.autofocus.panelTab, NightPanelTab.focus);
    expect(ManualActionId.solveSync.panelTab, NightPanelTab.solve);
    expect(ManualActionId.center.panelTab, NightPanelTab.solve);
    expect(ManualActionId.dither.panelTab, NightPanelTab.guide);
    expect(ManualActionId.flip.panelTab, NightPanelTab.mount);
    expect(ManualActionId.snapshot.panelTab, NightPanelTab.camera);
    expect(ManualActionId.loop.panelTab, NightPanelTab.camera);
  });
}
