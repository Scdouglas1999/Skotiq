import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../golden/golden_harness.dart';

DateTime _at(int hour, int minute) =>
    DateTime(2026, 10, hour < 12 ? 20 : 19, hour, minute);

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? SkotiqTheme.dark,
  home: Scaffold(body: Center(child: child)),
);

const _boardLabels = <NightTimelineLabel>[
  NightTimelineLabel('dark 19:48'),
  NightTimelineLabel('now 23:52', emphasized: true),
  NightTimelineLabel('M74 → 03:40'),
  NightTimelineLabel('NGC 891 → 05:30'),
  NightTimelineLabel('dawn 05:44'),
];

NightTimelineStrip _boardStrip({
  double? width = 360,
  DateTime? now,
  List<NightTimelineLabel> labels = _boardLabels,
}) => NightTimelineStrip(
  start: _at(18, 18),
  end: _at(7, 14),
  darkStart: _at(19, 48),
  darkEnd: _at(5, 44),
  now: now ?? _at(23, 52),
  width: width,
  spans: <NightTimelineSpan>[
    // Deliberately listed done first: the painter orders them itself.
    NightTimelineSpan(
      start: _at(19, 55),
      end: _at(23, 52),
      state: NightTimelineSpanState.done,
    ),
    NightTimelineSpan(
      start: _at(19, 55),
      end: _at(3, 40),
      state: NightTimelineSpanState.active,
    ),
    NightTimelineSpan(
      start: _at(3, 46),
      end: _at(5, 30),
      state: NightTimelineSpanState.planned,
    ),
  ],
  labels: labels,
  semanticLabel:
      'Night timeline from sunset 18:18 to sunrise 07:14, now 23:52; M74 '
      'imaged until 03:40, then NGC 891',
);

RenderBox _paintBox(WidgetTester tester) => tester.renderObject<RenderBox>(
  find.descendant(
    of: find.byType(NightTimelineStrip),
    matching: find.byType(CustomPaint),
  ),
);

void main() {
  group('NightTimelineStrip', () {
    test('fractionOf clamps to the strip', () {
      final strip = _boardStrip();
      expect(strip.fractionOf(_at(18, 18)), 0);
      expect(strip.fractionOf(_at(7, 14)), 1);
      expect(strip.fractionOf(_at(17, 0)), 0);
      expect(strip.fractionOf(_at(9, 0)), 1);
      expect(strip.fractionOf(_at(0, 46)), closeTo(0.5, 0.001));
    });

    test('an empty night places everything at the left edge', () {
      final strip = NightTimelineStrip(
        start: _at(20, 0),
        end: _at(20, 0),
        now: _at(21, 0),
        semanticLabel: 'x',
      );
      expect(strip.fractionOf(_at(21, 0)), 0);
    });

    testWidgets('reads as its one sentence and nothing else', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_boardStrip()));

      final node = tester.getSemantics(find.byType(NightTimelineStrip));
      expect(node.label, startsWith('Night timeline from sunset 18:18'));
      // The labels row is covered by the sentence, so it is not read twice.
      expect(find.bySemanticsLabel('dark 19:48'), findsNothing);
      handle.dispose();
    });

    testWidgets('paints track, dark band, windows in state order, then now', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_boardStrip()));
      final p = NightTimelinePalette.of(SkotiqColors.dark);

      expect(
        _paintBox(tester),
        paints
          ..rrect(color: p.track)
          ..rect(color: p.darkBand)
          ..rrect(color: p.planned)
          ..rrect(color: p.active)
          ..rrect(color: p.activeEdge, style: PaintingStyle.stroke)
          ..rrect(color: p.done)
          ..rect(color: p.halo)
          ..rrect(color: p.now),
      );
    });

    testWidgets('without both dark ends there is no dark band', (tester) async {
      await tester.pumpWidget(
        _host(
          NightTimelineStrip(
            start: _at(18, 18),
            end: _at(7, 14),
            darkStart: _at(19, 48),
            now: _at(23, 52),
            width: 360,
            semanticLabel: 'x',
          ),
        ),
      );
      final p = NightTimelinePalette.of(SkotiqColors.dark);
      expect(_paintBox(tester), isNot(paints..rect(color: p.darkBand)));
    });

    testWidgets('a now before sunset sits inside the left edge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          NightTimelineStrip(
            start: _at(18, 18),
            end: _at(7, 14),
            now: _at(16, 0),
            width: 360,
            semanticLabel: 'x',
          ),
        ),
      );
      final p = NightTimelinePalette.of(SkotiqColors.dark);
      expect(
        _paintBox(tester),
        paints
          ..rrect(color: p.track)
          ..rect(color: p.halo)
          ..rrect(
            color: p.now,
            rrect: RRect.fromRectAndRadius(
              const Rect.fromLTWH(
                NightTimelineStrip.nowHalo,
                0,
                NightTimelineStrip.nowWidth,
                NightTimelineStrip.stripHeight,
              ),
              const Radius.circular(NightTimelineStrip.nowWidth / 2),
            ),
          ),
      );
    });

    testWidgets('the strip sits inside a RepaintBoundary of its own', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_boardStrip()));
      final paint = find.descendant(
        of: find.byType(NightTimelineStrip),
        matching: find.byType(CustomPaint),
      );
      expect(
        find.ancestor(of: paint, matching: find.byType(RepaintBoundary)),
        findsWidgets,
      );
      expect(tester.getSize(paint).height, NightTimelineStrip.stripHeight);
    });

    group('at the header width, in the real fonts', () {
      testWidgets('all five board labels fit 360 px, none ellipsized', (
        tester,
      ) async {
        await GoldenHarness.ensureFonts();
        await tester.pumpWidget(_host(_boardStrip()));

        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(NightTimelineStrip)).width, 360);
        for (final label in _boardLabels) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(label.text),
          );
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: '"${label.text}" was cut short at 360 px',
          );
        }
      });

      testWidgets('too narrow, middle labels go and now stays', (tester) async {
        await GoldenHarness.ensureFonts();
        await tester.pumpWidget(_host(_boardStrip(width: 220)));

        expect(tester.takeException(), isNull);
        expect(find.text('dark 19:48'), findsOneWidget);
        expect(find.text('now 23:52'), findsOneWidget);
        expect(find.text('dawn 05:44'), findsOneWidget);
        expect(find.text('NGC 891 → 05:30'), findsNothing);
      });

      testWidgets('null width fills its parent', (tester) async {
        await GoldenHarness.ensureFonts();
        await tester.pumpWidget(
          _host(SizedBox(width: 500, child: _boardStrip(width: null))),
        );
        expect(tester.getSize(find.byType(NightTimelineStrip)).width, 500);
      });
    });

    testWidgets('renders under light and red night without error', (
      tester,
    ) async {
      for (final theme in <ThemeData>[
        SkotiqTheme.light,
        SkotiqTheme.redNight,
      ]) {
        await tester.pumpWidget(_host(_boardStrip(), theme: theme));
        // MaterialApp animates a theme change.
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      final p = NightTimelinePalette.of(SkotiqColors.redNight);
      expect(_paintBox(tester), paints..rrect(color: p.track));
    });
  });
}
