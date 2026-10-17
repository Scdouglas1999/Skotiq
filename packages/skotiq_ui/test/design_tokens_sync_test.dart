import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// `design-tokens.json` is the source of truth for the Observatory palette and
/// this file is the reason that sentence is true rather than aspirational.
///
/// The JSON drives the HTML mockups, `check_tokens.py`'s contrast gate and the
/// generated `mockups/tokens.css`; Dart drives the app. Nothing else connects
/// them, so a value edited in one place and not the other would leave the
/// spec, the reference renders and the shipped UI quietly disagreeing — which
/// is precisely the failure the whole overhaul exists to end. Every mirrored
/// value is asserted here, in both directions: no Dart constant may drift from
/// the JSON, and no JSON key may go unmirrored.
///
/// The name map is `docs/design/overhaul/03-tokens.md` §0. The JSON uses short
/// CSS-friendly keys; the Dart names differ, and they are joined by that table,
/// never by key name.
void main() {
  /// Path is relative to the PACKAGE, which is the cwd `flutter test` uses.
  final tokensFile = File('../../docs/design/overhaul/design-tokens.json');

  late Map<String, dynamic> tokens;
  late Map<String, dynamic> palettes;

  setUpAll(() {
    expect(
      tokensFile.existsSync(),
      isTrue,
      reason:
          'design-tokens.json is missing at ${tokensFile.path}. If the design '
          'folder moved, this test moves with it — do not delete it.',
    );
    tokens = json.decode(tokensFile.readAsStringSync()) as Map<String, dynamic>;
    palettes = tokens['palettes'] as Map<String, dynamic>;
  });

  Color parseHex(String hex) {
    final clean = hex.replaceFirst('#', '');
    expect(
      clean.length,
      6,
      reason: '$hex is not a #RRGGBB literal; the mirror only handles those',
    );
    return Color(int.parse('FF$clean', radix: 16));
  }

  /// 03 §0, the colour rows: JSON key -> the field of [SkotiqColors] it
  /// mirrors. `onPrimary` is deliberately absent — it is DERIVED from
  /// `useDarkOnPrimary` rather than stored, and is asserted separately below.
  /// `accentSwatches` and `bands` are nested and are asserted separately too.
  Map<String, Color Function(SkotiqColors)> colorMap() => {
    'bg': (c) => c.background,
    'surface': (c) => c.surface,
    'well': (c) => c.well,
    'surfaceHover': (c) => c.surfaceHover,
    'surfaceElevated': (c) => c.surfaceElevated,
    'surfaceOverlay': (c) => c.surfaceOverlay,
    'border': (c) => c.border,
    'borderStrong': (c) => c.borderHighlight,
    'textPrimary': (c) => c.textPrimary,
    'textSecondary': (c) => c.textSecondary,
    'textMuted': (c) => c.textMuted,
    'primary': (c) => c.primary,
    'accent': (c) => c.accent,
    'success': (c) => c.success,
    'warning': (c) => c.warning,
    'error': (c) => c.error,
    'info': (c) => c.info,
    'brandWarm': (c) => c.brandWarm,
    'startFill': (c) => c.startFill,
    'onStart': (c) => c.onStart,
  };

  Map<String, Color Function(SkotiqColors)> bandMap() => {
    'dusk': (c) => c.bandDusk,
    'twilight': (c) => c.bandTwilight,
    'dark': (c) => c.bandDark,
    'dawn': (c) => c.bandDawn,
  };

  /// JSON palette name -> the Dart constant it mirrors.
  const dartPalettes = <String, SkotiqColors>{
    'dark': SkotiqColors.dark,
    'light': SkotiqColors.light,
    'redNight': SkotiqColors.redNight,
  };

  group('design-tokens.json mirrors SkotiqColors', () {
    test('the JSON declares exactly the three palettes Dart holds', () {
      expect(palettes.keys.toSet(), dartPalettes.keys.toSet());
    });

    for (final entry in dartPalettes.entries) {
      final name = entry.key;
      final dart = entry.value;

      test('$name: every colour matches the JSON', () {
        final json = palettes[name] as Map<String, dynamic>;
        for (final field in colorMap().entries) {
          final expected = parseHex(json[field.key] as String);
          expect(
            field.value(dart).toARGB32(),
            expected.toARGB32(),
            reason:
                '$name.${field.key} is ${json[field.key]} in '
                'design-tokens.json but a different colour in '
                'SkotiqColors.$name',
          );
        }
      });

      test('$name: the night band matches the JSON', () {
        final json = palettes[name] as Map<String, dynamic>;
        final bands = json['bands'] as Map<String, dynamic>;
        expect(bands.keys.toSet(), bandMap().keys.toSet());
        for (final band in bandMap().entries) {
          expect(
            band.value(dart).toARGB32(),
            parseHex(bands[band.key] as String).toARGB32(),
            reason: '$name band ${band.key} drifted from design-tokens.json',
          );
        }
      });

      test('$name: the two flags and the derived onPrimary match', () {
        final json = palettes[name] as Map<String, dynamic>;
        expect(dart.useDarkOnPrimary, json['useDarkOnPrimary']);
        expect(dart.isRedNight, json['isRedNight']);
        // onPrimary is not a field: it is `background` or white, chosen by
        // useDarkOnPrimary. The JSON writes the resolved value, so this
        // asserts the derivation as well as the colour.
        expect(
          dart.onPrimary.toARGB32(),
          parseHex(json['onPrimary'] as String).toARGB32(),
          reason:
              '$name.onPrimary resolves to something other than the JSON says',
        );
      });

      test('$name: the accent swatches match the JSON', () {
        final json = palettes[name] as Map<String, dynamic>;
        final expected = (json['accentSwatches'] as List<dynamic>)
            .cast<String>()
            .map(parseHex)
            .map((c) => c.toARGB32())
            .toList();
        final mode = switch (name) {
          'dark' => AppThemeMode.dark,
          'light' => AppThemeMode.light,
          _ => AppThemeMode.redNight,
        };
        expect(
          AppearanceAccents.forTheme(mode).map((c) => c.toARGB32()).toList(),
          expected,
          reason:
              'the Settings > Appearance swatches for $name are not the ones '
              'check_tokens.py validated',
        );
      });
    }

    /// The mirror is only worth having if it is exhaustive. Every colour-valued
    /// key in the JSON must be claimed by the map above, so adding a token to
    /// the JSON and forgetting the Dart side fails HERE rather than in a
    /// screenshot review three waves later.
    test('no colour key in the JSON is left unmirrored', () {
      final claimed = colorMap().keys.toSet()
        ..addAll(<String>['onPrimary', 'useDarkOnPrimary', 'isRedNight'])
        ..addAll(<String>['accentSwatches', 'bands']);
      for (final entry in palettes.entries) {
        final json = entry.value as Map<String, dynamic>;
        final unmirrored = json.keys.toSet().difference(claimed);
        expect(
          unmirrored,
          isEmpty,
          reason:
              '${entry.key} carries $unmirrored in design-tokens.json with no '
              'SkotiqColors field behind it. Add the field and the row in '
              '03-tokens.md §0, or remove the key.',
        );
      }
    });
  });

  group('red night stays on the red axis', () {
    /// The wavelength rule, asserted against the SOURCE rather than the Dart
    /// copy: red dominant and green exactly equal to blue, for every colour in
    /// the palette including the night band. Anything with green ≠ blue has a
    /// hue — orange or magenta — and a hue is light the operator's rods can
    /// see, which is the one thing this mode may not spend.
    test('every red-night colour has G == B', () {
      final json = palettes['redNight'] as Map<String, dynamic>;
      final entries = <String, String>{};
      for (final e in json.entries) {
        if (e.value is String) entries[e.key] = e.value as String;
      }
      for (final b in (json['bands'] as Map<String, dynamic>).entries) {
        entries['bands.${b.key}'] = b.value as String;
      }
      expect(
        entries.length,
        greaterThan(15),
        reason: 'the sweep found almost nothing; the JSON shape has changed',
      );
      for (final e in entries.entries) {
        final c = parseHex(e.value);
        final r = (c.r * 255).round();
        final g = (c.g * 255).round();
        final b = (c.b * 255).round();
        expect(
          g,
          b,
          reason:
              'redNight.${e.key} is ${e.value}: green $g and blue $b differ, '
              'so it carries a hue off the red axis',
        );
        expect(
          r,
          greaterThanOrEqualTo(g),
          reason: 'redNight.${e.key} is ${e.value}: red is not dominant',
        );
      }
    });

    test('the Dart palette carries the same rule', () {
      const dart = SkotiqColors.redNight;
      final colors = <String, Color>{
        'background': dart.background,
        'surface': dart.surface,
        'well': dart.well,
        'surfaceHover': dart.surfaceHover,
        'surfaceElevated': dart.surfaceElevated,
        'surfaceOverlay': dart.surfaceOverlay,
        'border': dart.border,
        'borderHighlight': dart.borderHighlight,
        'textPrimary': dart.textPrimary,
        'textSecondary': dart.textSecondary,
        'textMuted': dart.textMuted,
        'primary': dart.primary,
        'accent': dart.accent,
        'success': dart.success,
        'warning': dart.warning,
        'error': dart.error,
        'info': dart.info,
        'brandWarm': dart.brandWarm,
        'startFill': dart.startFill,
        'onStart': dart.onStart,
        'onPrimary': dart.onPrimary,
        'bandDusk': dart.bandDusk,
        'bandTwilight': dart.bandTwilight,
        'bandDark': dart.bandDark,
        'bandDawn': dart.bandDawn,
      };
      for (final e in colors.entries) {
        expect(
          (e.value.g * 255).round(),
          (e.value.b * 255).round(),
          reason: 'redNight.${e.key} has drifted off the red axis',
        );
      }
    });
  });

  group('the non-colour tokens mirror too', () {
    test('the radius scale matches the JSON', () {
      final radius = tokens['radius'] as Map<String, dynamic>;
      expect(SkotiqTokens.radiusXs, (radius['xs'] as num).toDouble());
      expect(SkotiqTokens.radiusSm, (radius['sm'] as num).toDouble());
      expect(SkotiqTokens.radiusMd, (radius['md'] as num).toDouble());
      expect(SkotiqTokens.radiusLg, (radius['lg'] as num).toDouble());
      expect(SkotiqTokens.radiusXl, (radius['xl'] as num).toDouble());
      expect(SkotiqTokens.radiusFull, (radius['full'] as num).toDouble());
      // radiusButton is an alias of Sm, and the migration aliases fold onto
      // the scale; wave 4 deletes them, and until then they must not drift.
      expect(SkotiqTokens.radiusButton, SkotiqTokens.radiusSm);
      expect(SkotiqTokens.radiusInline2, SkotiqTokens.radiusXs);
      expect(SkotiqTokens.radiusInline4, SkotiqTokens.radiusXs);
      expect(SkotiqTokens.radiusInline8, SkotiqTokens.radiusLg);
      expect(SkotiqTokens.radiusInline9, SkotiqTokens.radiusLg);
      expect(SkotiqTokens.radiusInline11, SkotiqTokens.radiusXl);
    });

    test('the spacing scale matches the JSON', () {
      final space = tokens['space'] as Map<String, dynamic>;
      expect(SkotiqTokens.spaceXs, (space['1'] as num).toDouble());
      expect(SkotiqTokens.spaceSm, (space['2'] as num).toDouble());
      expect(SkotiqTokens.spaceMd, (space['3'] as num).toDouble());
      expect(SkotiqTokens.spaceLg, (space['4'] as num).toDouble());
      expect(SkotiqTokens.spaceXl, (space['5'] as num).toDouble());
      expect(SkotiqTokens.space2xl, (space['6'] as num).toDouble());
      expect(SkotiqTokens.space3xl, (space['8'] as num).toDouble());
      expect(SkotiqTokens.space4xl, (space['12'] as num).toDouble());
    });

    test('the motion durations match the JSON', () {
      final motion = tokens['motion'] as Map<String, dynamic>;
      expect(SkotiqTokens.durationFast.inMilliseconds, motion['hoverMs']);
      expect(SkotiqTokens.durationNormal.inMilliseconds, motion['stateMs']);
      expect(SkotiqTokens.durationSmooth.inMilliseconds, motion['panelMs']);
      // `cubic-bezier(0.215, 0.61, 0.355, 1)` IS easeOutCubic, and every named
      // curve in the app points at it: no bounce, no overshoot, no spring.
      expect(motion['easing'], 'cubic-bezier(0.215, 0.61, 0.355, 1)');
      for (final curve in <Curve>[
        SkotiqTokens.curveStandard,
        SkotiqTokens.curveDecelerate,
        SkotiqTokens.curveAccelerate,
        SkotiqTokens.curveBounce,
        SkotiqTokens.curveSharp,
        SkotiqTokens.curveSnappy,
        SkotiqTokens.curvePrecise,
        SkotiqTokens.curveSettle,
      ]) {
        expect(curve, same(Curves.easeOutCubic));
      }
    });

    test('the opacity tokens match the JSON', () {
      final opacity = tokens['opacity'] as Map<String, dynamic>;
      expect(SkotiqTokens.opacityAccentTint, opacity['accentTint']);
      expect(SkotiqTokens.opacityAccentTintHover, opacity['accentTintHover']);
      expect(SkotiqTokens.opacityStatusFill, opacity['statusFill']);
      expect(SkotiqTokens.opacityDisabled, opacity['disabled']);
      expect(SkotiqTokens.opacityHairline, opacity['hairline']);
      expect(SkotiqTokens.opacityHairlineStrong, opacity['hairlineStrong']);
      expect(SkotiqTokens.opacityPanelOutline, opacity['panelOutline']);
      expect(SkotiqTokens.opacitySelectedRing, opacity['selectedRing']);
      expect(SkotiqTokens.opacityLiveHalo, opacity['liveHalo']);
    });

    test('the icon-button sizes match the JSON', () {
      final shell = tokens['shell'] as Map<String, dynamic>;
      expect(
        SkotiqTokens.iconButtonSize,
        (shell['iconButtonSize'] as num).toDouble(),
      );
      expect(
        SkotiqTokens.iconButtonSizeSm,
        (shell['iconButtonSizeSm'] as num).toDouble(),
      );
      expect(
        SkotiqTokens.iconButtonSizeStrip,
        (shell['iconButtonSizeStrip'] as num).toDouble(),
      );
    });

    /// The component sizes wave 2 applied and wave 4 promoted onto
    /// [SkotiqTokens]. They are held to the JSON for the same reason the
    /// colours are: a height that only exists in Dart drifts from the mockups
    /// the moment someone edits one of them.
    test('the component sizes match the JSON', () {
      final shell = tokens['shell'] as Map<String, dynamic>;
      expect(
        SkotiqTokens.buttonHeight,
        (shell['buttonHeight'] as num).toDouble(),
      );
      expect(
        SkotiqTokens.buttonHeightSm,
        (shell['buttonHeightSm'] as num).toDouble(),
      );
      expect(
        SkotiqTokens.buttonHeightLg,
        (shell['buttonHeightLg'] as num).toDouble(),
      );
      expect(
        SkotiqTokens.inputHeight,
        (shell['inputHeight'] as num).toDouble(),
      );
      expect(
        SkotiqTokens.inputHeightSm,
        (shell['inputHeightSm'] as num).toDouble(),
      );
      expect(
        SkotiqTokens.sidebarCollapsed,
        (shell['railWidthCollapsed'] as num).toDouble(),
      );
      expect(
        SkotiqTokens.sidebarExpanded,
        (shell['railWidthExpanded'] as num).toDouble(),
      );
      expect(
        ShellChromeMetrics.sidePanelWidth,
        (shell['sidePanelWidth'] as num).toDouble(),
      );
      expect(
        ShellChromeMetrics.sidePanelStripWidth,
        (shell['sidePanelStripWidth'] as num).toDouble(),
      );
    });

    /// The type scale, by the same rule as the colours. `body`, `bodySm`,
    /// `caption`, `button` and `buttonSm` predate the overhaul and carry line
    /// heights and tracking from the old scale; wave 0 does not move them,
    /// because changing a line height moves every screen. Only the styles the
    /// overhaul INTRODUCED are held to the JSON here — the rest are wave 2's,
    /// alongside the components that read them.
    test('the new type styles match the JSON exactly', () {
      final styles =
          (tokens['typography'] as Map<String, dynamic>)['styles']
              as Map<String, dynamic>;
      final mirrored = <String, TextStyle>{
        'display': SkotiqTypography.display,
        'pageTitle': SkotiqTypography.pageTitle,
        'sectionTitle': SkotiqTypography.sectionTitle,
        'eyebrow': SkotiqTypography.eyebrow,
        'bodyStrong': SkotiqTypography.bodyStrong,
        'readoutLg': SkotiqTypography.readoutLg,
        'readoutMd': SkotiqTypography.readoutMd,
        'readoutSm': SkotiqTypography.readoutSm,
        'readoutXs': SkotiqTypography.readoutXs,
        'readoutBadge': SkotiqTypography.readoutBadge,
        'readoutLabel': SkotiqTypography.readoutLabel,
        'monoCaption': SkotiqTypography.monoCaption,
        'buttonLg': SkotiqTypography.buttonLg,
      };
      for (final entry in mirrored.entries) {
        final spec = styles[entry.key] as Map<String, dynamic>;
        final style = entry.value;
        expect(
          style.fontSize,
          (spec['size'] as num).toDouble(),
          reason: '${entry.key} size',
        );
        expect(
          style.fontWeight!.value,
          spec['weight'],
          reason: '${entry.key} weight',
        );
        expect(
          style.height,
          (spec['lineHeight'] as num).toDouble(),
          reason: '${entry.key} line height',
        );
        expect(
          style.letterSpacing,
          (spec['letterSpacing'] as num).toDouble(),
          reason: '${entry.key} tracking',
        );
        expect(
          style.fontFamily,
          spec['family'] == 'mono'
              ? SkotiqTypography.fontFamilyMono
              : SkotiqTypography.fontFamily,
          reason: '${entry.key} family',
        );
        final tabular = spec['tabular'] == true;
        expect(
          style.fontFeatures?.any((f) => f.feature == 'tnum') ?? false,
          tabular,
          reason:
              '${entry.key} ${tabular ? "must" : "must not"} carry tabular '
              'figures — a readout that reflows as its digits change is the '
              'reason this feature exists',
        );
      }
    });
  });
}
