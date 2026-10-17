import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The light palette's contrast floor, enforced instead of documented.
///
/// The four status roles were tuned against `surface` — plain white, the
/// LIGHTEST thing they ever land on — and the roles that passed there failed on
/// every card. Sampled off the running app in the Darkroom, the light theme's
/// "Applied by the last render" measured `#2A7F4F` on the step card at 4.36:1,
/// under the 4.5:1 AA floor for text below 18.66px, with `info` at 4.27 and
/// `error` at 4.11 on the same surface. Dark and red night both cleared it on
/// the same string, so this was the palette and not the screen.
///
/// The arithmetic lives here, in the shape `red_night_contrast_test.dart`
/// already established: a prose floor cannot fail a build. The floors match
/// `docs/design/overhaul/tools/check_tokens.py`, which gates the same numbers
/// on the JSON side.
void main() {
  const colors = SkotiqColors.light;

  /// WCAG 2.x contrast ratio. [Color.computeLuminance] is the same relative
  /// luminance the standard defines, so the ratio is the standard's verbatim.
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Every surface a body of text can land on in this palette, READ OFF the
  /// palette rather than pinned as hex — a repainted surface must re-measure
  /// itself, not slip past a stale copy of its old value.
  ///
  /// `well` is the inset a chart, an image area or a number field sits in, and
  /// on light it is the DARKEST ground under body text after `surfaceHover`,
  /// so it belongs in the list. `surfaceHover` is here because `SkotiqCard`
  /// paints it under a hovered card's whole contents: the text on a hovered
  /// card is the same text.
  final surfaces = <String, Color>{
    'background': colors.background,
    'surface': colors.surface,
    'well': colors.well,
    'surfaceHover': colors.surfaceHover,
    'surfaceElevated': colors.surfaceElevated,
    'surfaceOverlay': colors.surfaceOverlay,
  };

  /// The tokens this palette hands to a `Text` or `Icon` colour: the three-level
  /// text ladder plus the four status semantics. `primary` and `accent` are
  /// fill tokens, paired with [SkotiqColors.onPrimary] rather than a
  /// surface, and are measured separately below.
  final textRoles = <String, Color>{
    'textPrimary': colors.textPrimary,
    'textSecondary': colors.textSecondary,
    'textMuted': colors.textMuted,
    'success': colors.success,
    'warning': colors.warning,
    'error': colors.error,
    'info': colors.info,
  };

  group('light text contrast', () {
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

    /// The exact composition the audit sampled, pinned so a regression report
    /// can be compared to it directly rather than re-derived. The step card's
    /// ground is now the `well` inset; the surface it used to be was #EEF1F4
    /// and `well` is #EEF1F5, so the measurement is the same one.
    test('the sampled pair — success on the step card — is measured', () {
      final ratio = contrast(colors.success, colors.well);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'the Darkroom step card\'s "Applied by the last render" '
            'measured 4.36:1 here before this floor existed; it is now '
            '${ratio.toStringAsFixed(2)}:1',
      );
    });

    /// The status roles are the ones that moved, so their direction is stated:
    /// each one is DARKER than the ground it is read on, in a light palette,
    /// and none of them drifted into another role's hue while being fixed.
    test('the status roles stay distinguishable from each other', () {
      final statuses = <String, Color>{
        'success': colors.success,
        'warning': colors.warning,
        'error': colors.error,
        'info': colors.info,
      };
      for (final a in statuses.entries) {
        expect(
          a.value.computeLuminance(),
          lessThan(surfaces['surfaceHover']!.computeLuminance()),
          reason: '${a.key} is drawn as ink on a light ground',
        );
        for (final b in statuses.entries) {
          if (a.key == b.key) continue;
          expect(
            a.value,
            isNot(b.value),
            reason:
                '${a.key} and ${b.key} would state two different '
                'outcomes in one colour',
          );
        }
      }
    });
  });

  group('light fills', () {
    /// A filled control pairs its label with [SkotiqColors.onPrimary], not
    /// with a surface. In a light palette hover DARKENS: lightening an already
    /// light accent is what put white ink on the old #3A9BC4 at 3.15:1.
    test('onPrimary reads on primary and on the hover accent', () {
      for (final fill in <String, Color>{
        'primary': colors.primary,
        'accent': colors.accent,
      }.entries) {
        final ratio = contrast(colors.onPrimary, fill.value);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              'white ink on ${fill.key} measures '
              '${ratio.toStringAsFixed(2)}:1',
        );
      }
      expect(
        colors.accent.computeLuminance(),
        lessThan(colors.primary.computeLuminance()),
        reason:
            'the light hover accent must be DARKER than primary; a lighter '
            'one buys the hover state with the label',
      );
    });

    /// `primary` is also read as TEXT — links, the selected rail label, the
    /// "now" marker — which is a different job from filling a button and a
    /// stricter one on a light ground.
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

    /// Start is the night's committing action and gets its own fill.
    test('onStart reads on startFill', () {
      final ratio = contrast(colors.onStart, colors.startFill);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });
  });
}
