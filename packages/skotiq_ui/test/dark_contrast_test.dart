import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The dark palette's contrast floor, enforced instead of documented.
///
/// Dark was the one palette without this file, on the assumption that pale text
/// on a near-black canvas has room to spare. It does not: the Observatory
/// repaint took the whole tonal ladder DOWN — `background` #0A0C0F → #0B0D12,
/// `surface` → #12151B, plus a deeper `well` — while raising `surfaceOverlay`
/// to #222831 for dialogs and the command palette, and the roles are read on
/// the lifted surface, not the lowered one. `error` clears the floor there by
/// 0.23 and `textMuted` by 0.52. Both are close enough that the next tonal
/// adjustment should fail a build rather than a review.
///
/// The floors and the surface list are the ones
/// `docs/design/overhaul/tools/check_tokens.py` gates on the JSON side, so the
/// two ends of the mirror cannot disagree about what "passing" means.
void main() {
  const colors = SkotiqColors.dark;

  /// WCAG 2.x contrast ratio. [Color.computeLuminance] is the same relative
  /// luminance the standard defines, so the ratio is the standard's verbatim.
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Every surface a body of text can land on, read off the palette so a
  /// repainted surface re-measures itself instead of slipping past a stale hex.
  final surfaces = <String, Color>{
    'background': colors.background,
    'surface': colors.surface,
    'well': colors.well,
    'surfaceHover': colors.surfaceHover,
    'surfaceElevated': colors.surfaceElevated,
    'surfaceOverlay': colors.surfaceOverlay,
  };

  final textRoles = <String, Color>{
    'textPrimary': colors.textPrimary,
    'textSecondary': colors.textSecondary,
    'textMuted': colors.textMuted,
    'success': colors.success,
    'warning': colors.warning,
    'error': colors.error,
    'info': colors.info,
  };

  group('dark text contrast', () {
    for (final role in textRoles.entries) {
      test('${role.key} clears 4.5:1 on every surface level', () {
        for (final surface in surfaces.entries) {
          final ratio = contrast(role.value, surface.value);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                '${role.key} on ${surface.key} measures '
                '${ratio.toStringAsFixed(2)}:1, under the 4.5:1 floor this '
                'palette documents',
          );
        }
      });
    }

    /// `surfaceOverlay` is the dialog and command-palette ground: the LIGHTEST
    /// surface in a dark palette, and therefore the one that decides the floor
    /// for every role. Named so a regression report can go straight to it.
    test('surfaceOverlay is the deciding ground, and it holds', () {
      for (final role in textRoles.entries) {
        var worst = double.infinity;
        var worstOn = '';
        for (final surface in surfaces.entries) {
          final ratio = contrast(role.value, surface.value);
          if (ratio < worst) {
            worst = ratio;
            worstOn = surface.key;
          }
        }
        expect(
          worstOn,
          'surfaceOverlay',
          reason:
              '${role.key} is now worst on $worstOn (${worst.toStringAsFixed(2)}'
              ':1), not on surfaceOverlay. The tonal ladder has been reordered '
              'and every surface needs re-measuring, not just this one',
        );
      }
    });

    /// The three-level ladder only communicates if the levels stay in order.
    test('the text ladder stays strictly ordered', () {
      expect(
        colors.textPrimary.computeLuminance(),
        greaterThan(colors.textSecondary.computeLuminance()),
      );
      expect(
        colors.textSecondary.computeLuminance(),
        greaterThan(colors.textMuted.computeLuminance()),
      );
    });

    /// `well` is deeper than `surface`, which is what makes an inset read as
    /// inset without a border. If it ever rises above `surface` the whole
    /// "tone, not lines" rule stops working and panels need outlines again.
    test('well sits below surface, and surface below the elevated ladder', () {
      expect(
        colors.well.computeLuminance(),
        lessThan(colors.surface.computeLuminance()),
        reason: 'well must be the deepest step, or an inset reads as a lift',
      );
      expect(
        colors.surface.computeLuminance(),
        lessThan(colors.surfaceElevated.computeLuminance()),
      );
      expect(
        colors.surfaceElevated.computeLuminance(),
        lessThan(colors.surfaceOverlay.computeLuminance()),
      );
    });
  });

  group('dark fills', () {
    /// Every fill in this palette is a LIGHT tone, so the ink is the
    /// background rather than white — white on primary measured 2.94:1.
    test('onPrimary reads on primary and accent', () {
      expect(colors.onPrimary, colors.background);
      for (final fill in <String, Color>{
        'primary': colors.primary,
        'accent': colors.accent,
      }.entries) {
        final ratio = contrast(colors.onPrimary, fill.value);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              'dark ink on ${fill.key} measures '
              '${ratio.toStringAsFixed(2)}:1',
        );
      }
    });

    /// The status roles are also drawn as filled chips and buttons — the mount
    /// STOP is `error` — so the ink has to survive those too.
    test('onPrimary reads on every status fill', () {
      for (final role in <String, Color>{
        'success': colors.success,
        'warning': colors.warning,
        'error': colors.error,
        'info': colors.info,
      }.entries) {
        final ratio = contrast(colors.onPrimary, role.value);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              'dark ink on a ${role.key} fill measures '
              '${ratio.toStringAsFixed(2)}:1',
        );
      }
    });

    test('primary clears the floor as link text', () {
      for (final ground in <String, Color>{
        'background': colors.background,
        'surface': colors.surface,
      }.entries) {
        final ratio = contrast(colors.primary, ground.value);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              'primary as link text on ${ground.key} measures '
              '${ratio.toStringAsFixed(2)}:1',
        );
      }
    });

    test('onStart reads on startFill', () {
      final ratio = contrast(colors.onStart, colors.startFill);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'the Start button is the one irreversible control on Tonight; its '
            'label measures ${ratio.toStringAsFixed(2)}:1',
      );
    });
  });

  group('dark accent swatches', () {
    /// Settings offers these, so the app is responsible for them the same way
    /// it is responsible for its own primary. Each is checked twice: as a FILL
    /// under the ink [SkotiqColors] would pick for it, and as link TEXT on
    /// the two grounds a link is read on.
    test('every offered swatch works as a fill and as link text', () {
      for (final swatch in AppearanceAccents.dark) {
        // SkotiqColors._prefersDarkInk: 0.1791 is the WCAG crossover.
        final ink = swatch.computeLuminance() > 0.1791
            ? colors.background
            : const Color(0xFFFFFFFF);
        expect(
          contrast(ink, swatch),
          greaterThanOrEqualTo(4.5),
          reason: 'a label on the $swatch fill is under the floor',
        );
        expect(
          contrast(swatch, colors.background),
          greaterThanOrEqualTo(4.5),
          reason: '$swatch as link text on the canvas is under the floor',
        );
        expect(
          contrast(swatch, colors.surface),
          greaterThanOrEqualTo(4.5),
          reason: '$swatch as link text on a panel is under the floor',
        );
      }
    });

    /// A stored accent outlives a theme switch, and a dark-safe one is not
    /// light-safe. The fill keeps the user's colour; only the TEXT steps aside.
    test('an accent that fails the text floor gets a safe link colour', () {
      // Near-black: legible as a fill under white ink, illegible as text on
      // the dark canvas.
      const unreadable = Color(0xFF101418);
      final palette = SkotiqColors.darkWithAccent(unreadable);
      expect(palette.primary, unreadable, reason: 'the fill keeps the choice');
      expect(
        palette.link,
        isNot(unreadable),
        reason: 'link text must not take an accent it cannot be read in',
      );
      expect(
        contrast(palette.link, colors.background),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('an accent that passes is used for links unchanged', () {
      final chosen = AppearanceAccents.dark.last;
      final palette = SkotiqColors.darkWithAccent(chosen);
      expect(palette.link, chosen);
      expect(palette.linkOverride, isNull);
    });
  });
}
