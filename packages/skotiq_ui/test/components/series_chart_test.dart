import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Records what a painter draws, so a test can look at the paths themselves.
class _RecordingCanvas implements Canvas {
  final paths = <(Path, Paint)>[];
  final circles = <(Offset, double, Paint)>[];
  final lines = <(Offset, Offset, Paint)>[];

  @override
  void drawPath(Path path, Paint paint) => paths.add((path, paint));

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      circles.add((c, radius, paint));

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lines.add((p1, p2, paint));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _size = Size(240, 70);
const _colors = SkotiqColors.dark;
final _t0 = DateTime(2026, 10, 19, 22);

DateTime _min(int m) => _t0.add(Duration(minutes: m));

List<(DateTime, double?)> _points(List<double?> ys) => <(DateTime, double?)>[
  for (var i = 0; i < ys.length; i++) (_min(i), ys[i]),
];

SeriesChartPainter _painter(
  List<SeriesChartLine> lines, {
  List<SeriesChartMarker> markers = const <SeriesChartMarker>[],
  List<SeriesChartHighlight> highlights = const <SeriesChartHighlight>[],
  DateTime? from,
  DateTime? to,
  double? zeroLineY,
  SkotiqColors colors = _colors,
}) => SeriesChartPainter(
  colors: colors,
  lines: lines,
  markers: markers,
  highlights: highlights,
  from: from,
  to: to,
  zeroLineY: zeroLineY,
);

_RecordingCanvas _paint(SeriesChartPainter painter) {
  final canvas = _RecordingCanvas();
  painter.paint(canvas, _size);
  return canvas;
}

Color _tone(SeriesChartTone tone) => SeriesChart.colorFor(tone, _colors);

/// Paint stores its color as float32, so compare packed ARGB, not Color.==.
bool _same(Color a, Color b) => a.toARGB32() == b.toARGB32();

Iterable<(Path, Paint)> _pathsIn(_RecordingCanvas c, SeriesChartTone tone) =>
    c.paths.where((p) => _same(p.$2.color, _tone(tone)));

const _top = SeriesChart.verticalInset;
const _bottom = 70 - SeriesChart.verticalInset;

void main() {
  group('SeriesChart gaps', () {
    test('a null y breaks the line into two runs', () {
      final canvas = _paint(
        _painter(<SeriesChartLine>[
          SeriesChartLine(
            points: _points(<double?>[1, 2, null, 3, 4]),
            tone: SeriesChartTone.primary,
          ),
        ]),
      );
      final line = _pathsIn(canvas, SeriesChartTone.primary).single.$1;
      final runs = line.computeMetrics().toList();
      expect(runs, hasLength(2), reason: 'the gap was bridged');
      // The second run starts at the 4th sample, not the 2nd.
      final secondStart = runs[1].getTangentForOffset(0)!.position;
      expect(secondStart.dx, closeTo(240 * 3 / 4, 0.01));
    });

    test('a point alone between gaps is drawn as a dot', () {
      final canvas = _paint(
        _painter(<SeriesChartLine>[
          SeriesChartLine(
            points: _points(<double?>[1, null, 2, null, 3]),
            tone: SeriesChartTone.tertiary,
          ),
        ]),
      );
      final line = _pathsIn(canvas, SeriesChartTone.tertiary).single.$1;
      expect(
        line.computeMetrics().where((m) => m.length > 0),
        isEmpty,
        reason: 'no two samples are adjacent, so nothing may be joined',
      );
      final dots = canvas.circles
          .where((c) => _same(c.$3.color, _tone(SeriesChartTone.tertiary)))
          .toList();
      expect(dots, hasLength(3));
      expect(dots.first.$2, SeriesChart.strokeWidth);
    });

    test('a line of nothing but gaps draws nothing and does not throw', () {
      final painter = _painter(<SeriesChartLine>[
        SeriesChartLine(
          points: _points(<double?>[null, null, null]),
          tone: SeriesChartTone.primary,
        ),
      ]);
      expect(painter.valueRange(SeriesChartAxis.left), isNull);
      final canvas = _paint(painter);
      expect(canvas.circles, isEmpty);
      expect(
        _pathsIn(
          canvas,
          SeriesChartTone.primary,
        ).single.$1.computeMetrics().where((m) => m.length > 0),
        isEmpty,
      );
    });

    test('no lines at all paints nothing', () {
      final canvas = _paint(_painter(const <SeriesChartLine>[]));
      expect(canvas.paths, isEmpty);
      expect(canvas.circles, isEmpty);
    });
  });

  group('SeriesChart markers and highlights', () {
    test('a marker is a dashed vertical at its time', () {
      final canvas = _paint(
        _painter(
          <SeriesChartLine>[
            SeriesChartLine(
              points: _points(<double?>[1, 2, 3, 4, 5]),
              tone: SeriesChartTone.primary,
            ),
          ],
          markers: <SeriesChartMarker>[SeriesChartMarker(_min(2))],
        ),
      );
      final dashes = _pathsIn(canvas, SeriesChartTone.muted).toList();
      expect(dashes.length, greaterThan(1), reason: 'drawn solid, not dashed');
      for (final dash in dashes) {
        final bounds = dash.$1.getBounds();
        expect(bounds.left, closeTo(120, 0.01));
        expect(bounds.right, closeTo(120, 0.01));
        expect(
          bounds.height,
          lessThanOrEqualTo(SeriesChart.dashLength + 0.001),
        );
      }
      // Together the dashes span the chart's height.
      final top = dashes.map((d) => d.$1.getBounds().top).reduce(math.min);
      final bottom = dashes
          .map((d) => d.$1.getBounds().bottom)
          .reduce(math.max);
      expect(top, 0);
      expect(bottom, greaterThan(70 - SeriesChart.dashLength - 1));
      expect(dashes.first.$2.strokeWidth, SeriesChart.markerWidth);
    });

    test('a marker in its own tone', () {
      final canvas = _paint(
        _painter(
          <SeriesChartLine>[
            SeriesChartLine(
              points: _points(<double?>[1, 2]),
              tone: SeriesChartTone.primary,
            ),
          ],
          markers: <SeriesChartMarker>[
            SeriesChartMarker(_min(1), tone: SeriesChartTone.secondary),
          ],
        ),
      );
      expect(_pathsIn(canvas, SeriesChartTone.secondary), isNotEmpty);
    });

    test('a marker outside the time range is not drawn', () {
      final canvas = _paint(
        _painter(
          <SeriesChartLine>[
            SeriesChartLine(
              points: _points(<double?>[1, 2]),
              tone: SeriesChartTone.primary,
            ),
          ],
          markers: <SeriesChartMarker>[SeriesChartMarker(_min(30))],
        ),
      );
      expect(_pathsIn(canvas, SeriesChartTone.muted), isEmpty);
    });

    test('a highlight is a dot on its point, in its tone', () {
      final canvas = _paint(
        _painter(
          <SeriesChartLine>[
            SeriesChartLine(
              points: _points(<double?>[1, 2, 3]),
              tone: SeriesChartTone.primary,
            ),
          ],
          highlights: <SeriesChartHighlight>[SeriesChartHighlight(_min(2), 3)],
        ),
      );
      final dot = canvas.circles.single;
      expect(dot.$1.dx, closeTo(240, 0.01));
      expect(dot.$1.dy, closeTo(_top, 0.01));
      expect(dot.$2, SeriesChart.highlightRadius);
      expect(_same(dot.$3.color, _tone(SeriesChartTone.error)), isTrue);
    });
  });

  group('SeriesChart scales', () {
    test('a right-axis line gets its own scale', () {
      final painter = _painter(<SeriesChartLine>[
        SeriesChartLine(
          points: _points(<double?>[2, 3]),
          tone: SeriesChartTone.primary,
        ),
        SeriesChartLine(
          points: _points(<double?>[1000, 1200]),
          tone: SeriesChartTone.secondary,
          axis: SeriesChartAxis.right,
        ),
      ]);
      expect(painter.valueRange(SeriesChartAxis.left), (2.0, 3.0));
      expect(painter.valueRange(SeriesChartAxis.right), (1000.0, 1200.0));
      // Both lines run bottom-left to top-right, each on its own scale.
      for (final (axis, lo, hi) in <(SeriesChartAxis, double, double)>[
        (SeriesChartAxis.left, 2, 3),
        (SeriesChartAxis.right, 1000, 1200),
      ]) {
        expect(painter.yOf(lo, axis, 70), closeTo(_bottom, 0.01));
        expect(painter.yOf(hi, axis, 70), closeTo(_top, 0.01));
      }
    });

    test('a fixed range wins over the data', () {
      final painter = _painter(<SeriesChartLine>[
        SeriesChartLine(
          points: _points(<double?>[0, 0.5]),
          tone: SeriesChartTone.tertiary,
          minY: -1,
          maxY: 1,
        ),
      ]);
      expect(painter.valueRange(SeriesChartAxis.left), (-1.0, 1.0));
      expect(painter.yOf(0, SeriesChartAxis.left, 70), closeTo(35, 0.01));
    });

    test('a flat series sits in the middle', () {
      final painter = _painter(<SeriesChartLine>[
        SeriesChartLine(
          points: _points(<double?>[-10, -10, -10]),
          tone: SeriesChartTone.warning,
        ),
      ]);
      expect(painter.yOf(-10, SeriesChartAxis.left, 70), closeTo(35, 0.01));
    });

    test('from and to set the time range, and data outside is clipped', () {
      final painter = _painter(
        <SeriesChartLine>[
          SeriesChartLine(
            points: _points(<double?>[1, 2, 3, 4, 5]),
            tone: SeriesChartTone.primary,
          ),
        ],
        from: _min(2),
        to: _min(4),
      );
      expect(painter.xOf(_min(2), 240), 0);
      expect(painter.xOf(_min(4), 240), 240);
      expect(painter.xOf(_min(3), 240), 120);
    });

    test('the zero line is drawn at zero on the left axis', () {
      final canvas = _paint(
        _painter(<SeriesChartLine>[
          SeriesChartLine(
            points: _points(<double?>[-0.5, 1.5]),
            tone: SeriesChartTone.tertiary,
          ),
        ], zeroLineY: 0),
      );
      final line = canvas.lines.single;
      const expected = _top + (1 - 0.5 / 2) * (_bottom - _top);
      expect(line.$1.dy, closeTo(expected, 0.01));
      expect(line.$1.dx, 0);
      expect(line.$2.dx, 240);
    });

    test('a stepped line holds, then jumps', () {
      final canvas = _paint(
        _painter(<SeriesChartLine>[
          SeriesChartLine(
            points: _points(<double?>[1, 2]),
            tone: SeriesChartTone.primary,
            stepped: true,
          ),
        ]),
      );
      final metric = _pathsIn(
        canvas,
        SeriesChartTone.primary,
      ).single.$1.computeMetrics().single;
      expect(metric.length, closeTo(240 + (_bottom - _top), 0.01));
      final corner = metric.getTangentForOffset(240)!.position;
      expect(corner.dx, closeTo(240, 0.01));
      expect(corner.dy, closeTo(_bottom, 0.01));
    });

    test('a dashed line is drawn in pieces', () {
      final canvas = _paint(
        _painter(<SeriesChartLine>[
          SeriesChartLine(
            points: _points(<double?>[1, 1, 1]),
            tone: SeriesChartTone.warning,
            dashed: true,
          ),
        ]),
      );
      expect(_pathsIn(canvas, SeriesChartTone.warning).length, greaterThan(10));
    });
  });

  group('SeriesChart repaint', () {
    List<SeriesChartLine> lines(double last) => <SeriesChartLine>[
      SeriesChartLine(
        points: _points(<double?>[1, 2, last]),
        tone: SeriesChartTone.primary,
      ),
    ];

    test('equal data does not repaint; changed data or palette does', () {
      final a = _painter(lines(3));
      expect(_painter(lines(3)).shouldRepaint(a), isFalse);
      expect(_painter(lines(4)).shouldRepaint(a), isTrue);
      expect(
        _painter(lines(3), colors: SkotiqColors.light).shouldRepaint(a),
        isTrue,
      );
      expect(
        _painter(
          lines(3),
          markers: <SeriesChartMarker>[SeriesChartMarker(_min(1))],
        ).shouldRepaint(a),
        isTrue,
      );
      expect(_painter(lines(3), zeroLineY: 0).shouldRepaint(a), isTrue);
    });
  });

  group('SeriesChart widget', () {
    Widget host(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme ?? SkotiqTheme.dark,
      home: Scaffold(
        body: Center(child: SizedBox(width: 240, child: child)),
      ),
    );

    final chart = SeriesChart(
      lines: <SeriesChartLine>[
        SeriesChartLine(
          points: _points(<double?>[2.1, null, 2.2, 2.0]),
          tone: SeriesChartTone.primary,
        ),
      ],
      markers: <SeriesChartMarker>[SeriesChartMarker(_min(1))],
      semanticLabel: 'HFR across the session, steady near 2.1',
    );

    testWidgets('lays out at 240 x 70 and reads as its sentence', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(chart));

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SeriesChart)), _size);
      expect(
        find.bySemanticsLabel('HFR across the session, steady near 2.1'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the painter sits inside its own RepaintBoundary', (
      tester,
    ) async {
      await tester.pumpWidget(host(chart));
      final paint = find.descendant(
        of: find.byType(SeriesChart),
        matching: find.byType(CustomPaint),
      );
      final boundary = find.descendant(
        of: find.byType(SeriesChart),
        matching: find.byType(RepaintBoundary),
      );
      expect(boundary, findsOneWidget);
      expect(find.descendant(of: boundary, matching: paint), findsOneWidget);
    });

    testWidgets('paints in the active theme', (tester) async {
      await tester.pumpWidget(host(chart, theme: SkotiqTheme.redNight));
      await tester.pumpAndSettle();
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byType(SeriesChart),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as SeriesChartPainter;
      expect(painter.colors, SkotiqColors.redNight);
    });

    test('more than three lines is refused', () {
      final line = SeriesChartLine(
        points: _points(<double?>[1]),
        tone: SeriesChartTone.primary,
      );
      expect(
        () => SeriesChart(
          lines: <SeriesChartLine>[line, line, line, line],
          semanticLabel: 'x',
        ),
        throwsAssertionError,
      );
    });
  });
}
