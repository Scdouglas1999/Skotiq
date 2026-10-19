// The right panel: the six tabs over their bodies, the injected Mount, Guide
// and Solve bodies, keyboard selection, badges that never switch tabs, and
// every tab at the owner's 300 × 758 without overflow.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/night_control_layout.dart';
import 'package:skotiq_app/screens/night_control/panel/focus/focus_panel_vm.dart';
import 'package:skotiq_app/screens/night_control/panel/night_right_panel.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';
import 'panel_test_support.dart';

const _panel = NightRightPanel(
  mountTab: StubTab('Mount'),
  guideTab: StubTab('Guide'),
  solveTab: StubTab('Solve'),
);

/// The badges, switchable mid-test the way a live provider changes.
final _focusActive = StateProvider<bool>((ref) => false);
final _guideAlert = StateProvider<bool>((ref) => false);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  NightBoard? board,
  NightFocusPanelVm? focus,
  ThemeData? theme,
  Size size = const Size(300, 758),
  Widget child = _panel,
}) async {
  final container = ProviderContainer(
    overrides: <Override>[
      ...panelOverrides(
        board: board ?? NightFixtures.running(),
        focus: focus,
      ),
      nightFocusActiveProvider.overrideWith((ref) => ref.watch(_focusActive)),
      nightGuideAlertProvider.overrideWith((ref) => ref.watch(_guideAlert)),
    ],
  );
  addTearDown(container.dispose);
  await pumpPanel(
    tester,
    child: child,
    overrides: const <Override>[],
    container: container,
    size: size,
    theme: theme,
  );
  return container;
}

Finder _tab(String label) => find.descendant(
      of: find.byType(PanelTabStrip),
      matching: find.text(label),
    );

void main() {
  testWidgets('six tabs; the injected bodies show under theirs',
      (tester) async {
    final container = await _pump(tester);

    for (final label in <String>[
      'Overview',
      'Camera',
      'Focus',
      'Mount',
      'Guide',
      'Solve',
    ]) {
      expect(_tab(label), findsOneWidget);
    }
    expect(find.text('Last frame · #43'), findsOneWidget);

    await tester.tap(_tab('Guide'));
    await tester.pump();
    expect(container.read(nightPanelTabProvider), NightPanelTab.guide);
    expect(find.text('Guide body'), findsOneWidget);
    expect(find.text('Last frame · #43'), findsNothing);
  });

  testWidgets('the tab comes from nightPanelTabProvider', (tester) async {
    final container = await _pump(tester);
    container.read(nightPanelTabProvider.notifier).state = NightPanelTab.focus;
    await tester.pump();
    expect(find.text('Running · point 6 of 9'), findsOneWidget);
  });

  testWidgets('arrow keys move between tabs', (tester) async {
    final container = await _pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(container.read(nightPanelTabProvider), NightPanelTab.camera);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(container.read(nightPanelTabProvider), NightPanelTab.solve);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(container.read(nightPanelTabProvider), NightPanelTab.overview);
  });

  testWidgets('badges say what they mean in red night and never switch tabs',
      (tester) async {
    final container = await _pump(tester, theme: SkotiqTheme.redNight);
    expect(find.bySemanticsLabel('Focus'), findsOneWidget);

    container.read(_focusActive.notifier).state = true;
    container.read(_guideAlert.notifier).state = true;
    await tester.pump();

    // Both dots are red in red night, so the words carry the difference.
    expect(
      tester.getSemantics(find.bySemanticsLabel('Focus, autofocus running')),
      matchesSemantics(
        label: 'Focus, autofocus running',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    expect(
      find.bySemanticsLabel('Guide, the guider needs a look'),
      findsOneWidget,
    );
    expect(container.read(nightPanelTabProvider), NightPanelTab.overview);
    expect(find.text('Last frame · #43'), findsOneWidget);
  });

  testWidgets('a half-typed field survives a tab switch', (tester) async {
    await _pump(
      tester,
      board: NightFixtures.ready(),
      focus: PanelFixtures.focusIdle,
    );
    await tester.tap(_tab('Focus'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '45470');
    await tester.tap(_tab('Overview'));
    await tester.pump();
    await tester.tap(_tab('Focus'));
    await tester.pump();
    expect(find.text('45470'), findsOneWidget);
  });

  for (final (name, board) in <(String, NightBoard Function())>[
    ('running', NightFixtures.running),
    ('ready', NightFixtures.ready),
    ('autofocus', NightFixtures.autofocus),
  ]) {
    testWidgets('$name: every tab at 300 × 758 scrolls without overflow',
        (tester) async {
      final container = await _pump(tester, board: board());
      for (final tab in NightPanelTab.values.take(3)) {
        container.read(nightPanelTabProvider.notifier).state = tab;
        await tester.pump();
        final scrollable = find.byType(Scrollable).hitTestable().first;
        await tester.drag(scrollable, const Offset(0, -2000));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$tab');
        final position = tester.state<ScrollableState>(scrollable).position;
        expect(position.pixels, position.maxScrollExtent, reason: '$tab');
      }
    });
  }

  testWidgets('at 1.3× text the tabs still lay out', (tester) async {
    await _pump(
      tester,
      child: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.3),
          ),
          child: _panel,
        ),
      ),
    );
    for (final tab in <String>['Overview', 'Camera', 'Focus']) {
      await tester.tap(_tab(tab));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: tab);
    }
  });

  testWidgets('in the single column the panel sizes to the selected tab',
      (tester) async {
    await _pump(
      tester,
      size: const Size(390, 844),
      child: const NightControlLayout(
        header: SizedBox(height: 40),
        left: SizedBox(height: 40),
        center: SizedBox(height: 200),
        panel: _panel,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Last frame · #43'), findsOneWidget);
    await tester.tap(_tab('Mount'));
    await tester.pump();
    expect(find.text('Mount body'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
