import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The night-control kit's colors, measured in every palette.
///
/// Text roles are held to 4.5:1 like `dark_contrast_test.dart`; lines, dots,
/// markers and timeline windows are graphics and are held to the WCAG 1.4.11
/// non-text floor of 3:1 against whatever they are drawn on. Every color is
/// read through the widgets' own public resolvers, so a change to a mapping
/// re-measures itself.
void main() {
  /// WCAG 2.x contrast ratio, as in `dark_contrast_test.dart`.
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  const palettes = <String, SkotiqColors>{
    'dark': SkotiqColors.dark,
    'light': SkotiqColors.light,
    'red night': SkotiqColors.redNight,
  };

  for (final palette in palettes.entries) {
    final name = palette.key;
    final colors = palette.value;

    /// The grounds these widgets are placed on: the header (background), the
    /// side panel and chart strip (surface), and an inset (well).
    final grounds = <String, Color>{
      'background': colors.background,
      'surface': colors.surface,
      'well': colors.well,
      'surfaceElevated': colors.surfaceElevated,
    };

    void expectFloor(
      Color ink,
      Map<String, Color> on,
      double floor,
      String what,
    ) {
      for (final ground in on.entries) {
        final ratio = contrast(ink, ground.value);
        expect(
          ratio,
          greaterThanOrEqualTo(floor),
          reason:
              '$name: $what on ${ground.key} measures '
              '${ratio.toStringAsFixed(2)}:1, under $floor:1',
        );
      }
    }

    group('$name SeriesChart', () {
      test('every tone clears 3:1 as a line on every ground', () {
        for (final tone in SeriesChartTone.values) {
          expectFloor(
            SeriesChart.colorFor(tone, colors),
            grounds,
            3,
            'the ${tone.name} line',
          );
        }
      });
    });

    group('$name NightTimelineStrip', () {
      final p = NightTimelinePalette.of(colors);

      final windowGrounds = <String, Color>{
        'track': p.track,
        'dark band': p.darkBand,
      };

      test('every window clears 3:1 on the track and on the dark band', () {
        // The active window reads by its outline; its fill is a tint.
        final windows = <String, Color>{
          'done': p.done,
          'planned': p.planned,
          'active edge': p.activeEdge,
        };
        for (final window in windows.entries) {
          for (final under in windowGrounds.entries) {
            final drawn = Color.alphaBlend(window.value, under.value);
            final ratio = contrast(drawn, under.value);
            expect(
              ratio,
              greaterThanOrEqualTo(3),
              reason:
                  '$name: a ${window.key} window on the ${under.key} '
                  'measures ${ratio.toStringAsFixed(2)}:1',
            );
          }
        }
      });

      test('the done fill is told apart from the active tint', () {
        for (final under in windowGrounds.entries) {
          final ratio = contrast(
            p.done,
            Color.alphaBlend(p.active, under.value),
          );
          expect(
            ratio,
            greaterThanOrEqualTo(1.5),
            reason:
                '$name: done against the active tint on the ${under.key} '
                'measures ${ratio.toStringAsFixed(2)}:1',
          );
        }
      });

      test('the now marker clears 3:1 on its halo', () {
        expect(p.halo, colors.background);
        expectFloor(p.now, <String, Color>{'halo': p.halo}, 3, 'the marker');
      });

      test('the dark band is darker than the track', () {
        expect(
          p.darkBand.computeLuminance(),
          lessThan(p.track.computeLuminance()),
        );
      });

      test('the labels clear 4.5:1', () {
        expectFloor(colors.textMuted, grounds, 4.5, 'a label');
        expectFloor(colors.textPrimary, grounds, 4.5, 'the now label');
      });
    });

    group('$name PanelTabStrip', () {
      final panel = <String, Color>{
        'surface': colors.surface,
        'surfaceElevated': colors.surfaceElevated,
      };

      test('an unselected label clears 4.5:1 on the panel', () {
        expectFloor(
          PanelTabStrip.labelStyle(colors, selected: false).color!,
          panel,
          4.5,
          'an unselected tab label',
        );
      });

      test('the selected label clears 4.5:1 on its tinted fill', () {
        final fills = <String, Color>{
          for (final ground in panel.entries)
            'the selected fill on ${ground.key}': Color.alphaBlend(
              PanelTabStrip.selectedFill(colors),
              ground.value,
            ),
        };
        expectFloor(
          PanelTabStrip.labelStyle(colors, selected: true).color!,
          fills,
          4.5,
          'the selected tab label',
        );
      });

      test('every badge clears 3:1 on the panel and on a selected tab', () {
        final under = <String, Color>{
          ...panel,
          for (final ground in panel.entries)
            'the selected fill on ${ground.key}': Color.alphaBlend(
              PanelTabStrip.selectedFill(colors),
              ground.value,
            ),
        };
        for (final badge in PanelTabBadge.values) {
          final color = PanelTabStrip.badgeColor(badge, colors);
          if (badge == PanelTabBadge.none) {
            expect(color, isNull);
            continue;
          }
          expectFloor(color!, under, 3, 'the ${badge.name} badge');
        }
      });
    });

    group('$name MetricGrid', () {
      test('every value and delta tone clears 4.5:1 as text', () {
        for (final tone in MetricGridTone.values) {
          expectFloor(
            MetricGrid.valueColor(tone, colors),
            grounds,
            4.5,
            'a ${tone.name} value',
          );
          expectFloor(
            MetricGrid.deltaColor(tone, colors),
            grounds,
            4.5,
            'a ${tone.name} delta',
          );
        }
      });
    });
  }

  group('red night keeps to the red axis', () {
    const colors = SkotiqColors.redNight;

    /// Green and blue equal, as `red_night_contrast_test.dart` requires:
    /// the hue never leans toward the channels that cost dark adaptation.
    void expectRedAxis(Color c, String what) {
      expect(
        (c.g - c.b).abs(),
        lessThan(1.5 / 255),
        reason: '$what is off the red axis: $c',
      );
      expect(c.r, greaterThan(c.g), reason: '$what is not red-dominant: $c');
    }

    test('every chart tone, window and badge', () {
      for (final tone in SeriesChartTone.values) {
        expectRedAxis(SeriesChart.colorFor(tone, colors), 'the ${tone.name}');
      }
      final p = NightTimelinePalette.of(colors);
      for (final state in NightTimelineSpanState.values) {
        expectRedAxis(p.forState(state), 'a ${state.name} window');
      }
      for (final badge in PanelTabBadge.values) {
        final color = PanelTabStrip.badgeColor(badge, colors);
        if (color != null) expectRedAxis(color, 'the ${badge.name} badge');
      }
    });

    /// One hue leaves lightness as the only way to tell two lines apart. The
    /// pairs are the ones the Tonight charts draw together.
    test('paired lines differ in lightness', () {
      final pairs = <(SeriesChartTone, SeriesChartTone)>[
        (SeriesChartTone.primary, SeriesChartTone.secondary),
        (SeriesChartTone.tertiary, SeriesChartTone.error),
        (SeriesChartTone.muted, SeriesChartTone.primary),
      ];
      for (final (a, b) in pairs) {
        final ratio = contrast(
          SeriesChart.colorFor(a, colors),
          SeriesChart.colorFor(b, colors),
        );
        expect(
          ratio,
          greaterThanOrEqualTo(1.25),
          reason:
              'the ${a.name} and ${b.name} lines measure '
              '${ratio.toStringAsFixed(2)}:1 against each other',
        );
      }
    });
  });
}
