import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../golden/golden_harness.dart';

const _tabs = <PanelTabItem>[
  PanelTabItem('Overview'),
  PanelTabItem('Camera'),
  PanelTabItem(
    'Focus',
    badge: PanelTabBadge.active,
    semanticLabel: 'Focus, autofocus running',
  ),
  PanelTabItem('Mount'),
  PanelTabItem('Guide', badge: PanelTabBadge.alert),
  PanelTabItem('Solve'),
];

/// Holds the selection, the way the screen's provider does.
class _Harness extends StatefulWidget {
  const _Harness({this.initial = 0, this.log});

  final int initial;
  final List<int>? log;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late int _selected = widget.initial;

  @override
  Widget build(BuildContext context) => PanelTabStrip(
    tabs: _tabs,
    selectedIndex: _selected,
    onSelected: (i) {
      widget.log?.add(i);
      setState(() => _selected = i);
    },
    semanticLabel: 'Panel',
  );
}

Widget _host(Widget child, {double width = 300, ThemeData? theme}) =>
    MaterialApp(
      theme: theme ?? SkotiqTheme.dark,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

SemanticsNode _tabNode(WidgetTester tester, String label) =>
    tester.getSemantics(find.bySemanticsLabel(label));

void main() {
  group('PanelTabStrip semantics', () {
    testWidgets('each tab is an enabled button; only one is selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const _Harness(initial: 3)));

      for (final label in <String>[
        'Overview',
        'Camera',
        'Focus, autofocus running',
        'Mount',
        'Guide',
        'Solve',
      ]) {
        expect(
          _tabNode(tester, label),
          matchesSemantics(
            label: label,
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasSelectedState: true,
            isSelected: label == 'Mount',
            hasTapAction: true,
          ),
        );
      }
      expect(find.bySemanticsLabel('Panel'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a semantic tap selects the tab', (tester) async {
      final handle = tester.ensureSemantics();
      final log = <int>[];
      await tester.pumpWidget(_host(_Harness(log: log)));

      tester.semantics.tap(find.semantics.byLabel('Solve'));
      await tester.pump();
      expect(log, <int>[5]);
      expect(_tabNode(tester, 'Solve'), isSemantics(isSelected: true));
      handle.dispose();
    });
  });

  group('PanelTabStrip input', () {
    testWidgets('a tap selects', (tester) async {
      final log = <int>[];
      await tester.pumpWidget(_host(_Harness(log: log)));
      await tester.tap(find.text('Guide'));
      expect(log, <int>[4]);
    });

    testWidgets('Left and Right move the selection and wrap', (tester) async {
      final log = <int>[];
      await tester.pumpWidget(_host(_Harness(log: log)));

      // The strip is one stop in traversal.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(log, <int>[1, 2, 1]);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(log.last, 5, reason: 'Left from the first tab wraps to the last');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(log.last, 0, reason: 'Right from the last tab wraps to the first');
    });

    testWidgets('Home and End jump to the ends', (tester) async {
      final log = <int>[];
      await tester.pumpWidget(_host(_Harness(initial: 2, log: log)));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(log, <int>[5, 0]);
    });

    testWidgets('arrow keys do nothing until the strip has focus', (
      tester,
    ) async {
      final log = <int>[];
      await tester.pumpWidget(_host(_Harness(log: log)));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(log, isEmpty);
    });

    testWidgets('keyboard focus rings the selected tab', (tester) async {
      await tester.pumpWidget(_host(const _Harness(initial: 1)));
      Iterable<Container> ringed() => tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.foregroundDecoration != null);
      expect(ringed(), isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final ring = ringed().single;
      expect(
        find.descendant(of: find.byWidget(ring), matching: find.text('Camera')),
        findsOneWidget,
      );
    });
  });

  group('PanelTabStrip look', () {
    testWidgets('badges are dots in their tone; none means no dot', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const _Harness()));
      const colors = SkotiqColors.dark;
      final dots = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.shape == BoxShape.circle)
          .map((d) => d.color)
          .toList();
      expect(dots, <Color>[colors.success, colors.warning]);
    });

    testWidgets('the selected tab is tinted and its label is primary text', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const _Harness(initial: 4)));
      const colors = SkotiqColors.dark;
      final guide = tester.widget<Text>(find.text('Guide'));
      final mount = tester.widget<Text>(find.text('Mount'));
      expect(guide.style?.color, colors.textPrimary);
      expect(mount.style?.color, colors.textMuted);
      final fills = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.shape == BoxShape.rectangle && d.color != null)
          .map((d) => d.color)
          .toList();
      expect(fills, <Color>[PanelTabStrip.selectedFill(colors)]);
    });

    testWidgets('the six tabs fit 300 px in the real fonts', (tester) async {
      await GoldenHarness.ensureFonts();
      await tester.pumpWidget(
        _host(
          const _Harness(),
          // With a pointer: on touch the strip grows to the touch floor.
          theme: SkotiqTheme.dark.copyWith(platform: TargetPlatform.linux),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(PanelTabStrip)),
        const Size(300, PanelTabStrip.height),
      );
      for (final item in _tabs) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(item.label),
        );
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '"${item.label}" was cut short at 300 px',
        );
      }
      // The tabs fill the strip edge to edge, inside its padding.
      final first = tester.getTopLeft(find.bySemanticsLabel('Overview'));
      final last = tester.getTopRight(find.bySemanticsLabel('Solve'));
      expect(first.dx, PanelTabStrip.horizontalPadding);
      expect(last.dx, closeTo(300 - PanelTabStrip.horizontalPadding, 0.5));
    });

    testWidgets('on a touch platform each tab is a full touch target', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const _Harness(),
          theme: SkotiqTheme.dark.copyWith(platform: TargetPlatform.android),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(PanelTabStrip)).height,
        SkotiqTokens.minTouchTarget,
      );
      expect(
        tester.getSize(find.bySemanticsLabel('Overview')).height,
        greaterThanOrEqualTo(SkotiqTokens.minTouchTarget),
      );
    });

    testWidgets('too narrow for the words, the labels ellipsize cleanly', (
      tester,
    ) async {
      await GoldenHarness.ensureFonts();
      await tester.pumpWidget(_host(const _Harness(), width: 180));
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders under light and red night', (tester) async {
      for (final theme in <ThemeData>[
        SkotiqTheme.light,
        SkotiqTheme.redNight,
      ]) {
        await tester.pumpWidget(_host(const _Harness(), theme: theme));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      final overview = tester.widget<Text>(find.text('Overview'));
      expect(overview.style?.color, SkotiqColors.redNight.textPrimary);
    });
  });
}
