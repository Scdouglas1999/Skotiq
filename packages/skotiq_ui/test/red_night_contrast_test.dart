import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The red-night palette's contrast floor, enforced instead of documented.
///
/// [SkotiqColors.redNight] states the rule in prose — the red-only
/// constraint is about WAVELENGTH, not dimness, so every colour drawn as text
/// still clears 4.5:1 — and two of the seven drifted under it anyway: `success`
/// measured 2.93:1 on `surfaceAlt` and 2.79:1 on its own status chip, `warning`
/// 3.93:1, both sampled off the running app. A prose floor cannot fail a build,
/// so the arithmetic lives here.
void main() {
  const colors = SkotiqColors.redNight;

  /// WCAG 2.x contrast ratio. [Color.computeLuminance] is the same relative
  /// luminance the standard defines, so the ratio is the standard's verbatim.
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Share of the emitted light carried by the green and blue channels.
  ///
  /// Rods peak near 507nm, so this — not the hue name — is what red night is
  /// actually spending when a colour is made brighter.
  double greenBlueShare(Color c) => (c.g + c.b) / (c.r + c.g + c.b);

  /// Every surface a body of text can land on in this palette.
  ///
  /// `well` is the Observatory inset — the ground under a chart, an image area
  /// or a number field — and on a dark palette it is the DEEPEST surface, so it
  /// is the easy one; it is measured anyway, because the floor is a floor on
  /// every surface and not on the ones that were convenient to check.
  const surfaces = <String, Color>{
    'background': Color(0xFF0A0000),
    'surface': Color(0xFF140808),
    'well': Color(0xFF0F0404),
    'surfaceAlt': Color(0xFF1C0C0C),
    'surfaceHover': Color(0xFF241010),
    'surfaceElevated': Color(0xFF281212),
    'surfaceOverlay': Color(0xFF301616),
  };

  /// The tokens this palette hands to a `Text` or `Icon` colour: the three-level
  /// text ladder plus the four status semantics. `primary` and `accent` are
  /// fill tokens, paired with [SkotiqColors.onPrimary] rather than a
  /// surface, and are covered by the onPrimary assertions instead.
  final textRoles = <String, Color>{
    'textPrimary': colors.textPrimary,
    'textSecondary': colors.textSecondary,
    'textMuted': colors.textMuted,
    'success': colors.success,
    'warning': colors.warning,
    'error': colors.error,
    'info': colors.info,
  };

  group('red night text contrast', () {
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

    /// The two surfaces the audit sampled off the running app, named
    /// explicitly so a regression report can be compared to it directly.
    test('the sampled surfaces #1C0C0C and #140808 are covered', () {
      expect(surfaces['surfaceAlt'], const Color(0xFF1C0C0C));
      expect(surfaces['surface'], const Color(0xFF140808));
    });

    /// The map above is pinned as hex so the audit's numbers stay quotable.
    /// That is only safe while the hex IS the palette — a repainted surface
    /// with a stale copy here would measure the colour it used to be and pass.
    test('the pinned surfaces are the palette\'s own', () {
      expect(surfaces['background'], colors.background);
      expect(surfaces['surface'], colors.surface);
      expect(surfaces['well'], colors.well);
      // ignore: deprecated_member_use
      expect(surfaces['surfaceAlt'], colors.surfaceAlt);
      expect(surfaces['surfaceHover'], colors.surfaceHover);
      expect(surfaces['surfaceElevated'], colors.surfaceElevated);
      expect(surfaces['surfaceOverlay'], colors.surfaceOverlay);
    });
  });

  group('red night status chips', () {
    /// A status word usually sits ON its own colour: `SkotiqDecorations
    /// .statusChip` fills at [SkotiqTokens.opacityStatusFill], which lifts
    /// the background toward the text and eats contrast. The System Health
    /// pill is exactly this composition, and it is where `success` measured
    /// 2.79:1 on the running app — worse than the 2.93:1 the bare surface gave.
    ///
    /// The two card surfaces are the ones held to the floor, because they are
    /// where the audit sampled and where cards draw. On the three deeper
    /// surfaces the 15% fill costs more than the token can pay: `warning` runs
    /// 4.37 / 4.24 / 4.00 and `error` 4.32 / 4.18 / 3.93, which is the fill's
    /// alpha talking, not the colour, and is stated here rather than widened
    /// away.
    const cardSurfaces = ['surface', 'surfaceAlt'];

    for (final role in ['success', 'warning', 'error', 'info']) {
      test('$role stays legible on its own status-chip fill', () {
        final color = textRoles[role]!;
        for (final key in cardSurfaces) {
          final fill = Color.alphaBlend(
            color.withValues(alpha: SkotiqTokens.opacityStatusFill),
            surfaces[key]!,
          );
          final ratio = contrast(color, fill);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                '$role on its status chip over $key measures '
                '${ratio.toStringAsFixed(2)}:1',
          );
        }
      });
    }
  });

  group('red night wavelength rule', () {
    /// Raising a colour's luminance is the only way to clear the floor on a
    /// near-black surface, and the cheap way to do it is to add green and
    /// blue. That would buy legibility with the operator's dark adaptation —
    /// the one thing this palette exists to protect — so the ceiling is the
    /// share textPrimary already spends.
    final ceiling = greenBlueShare(colors.textPrimary);

    for (final role in textRoles.entries) {
      test('${role.key} stays on the red axis', () {
        final c = role.value;
        expect(
          c.r,
          greaterThan(c.g),
          reason: '${role.key} is no longer red-dominant',
        );
        expect(
          ((c.g - c.b) * 255).abs(),
          lessThanOrEqualTo(8.0),
          reason:
              '${role.key} has drifted off the red axis — green and blue must '
              'stay together or the hue turns orange or magenta',
        );
        expect(
          greenBlueShare(c),
          lessThanOrEqualTo(ceiling),
          reason:
              '${role.key} emits a larger green+blue share than textPrimary, '
              'so it costs more dark adaptation than the palette already does',
        );
      });
    }

    /// The status trio is held to the stricter rule the chart layer already
    /// enforces — red keeps over half the emitted energy — because these three
    /// reach `SkotiqChartColors`: `success` is the scrubber's selected
    /// frame bar via `selectedFrame`, painted raw rather than through
    /// `forTheme`.
    for (final role in ['success', 'warning', 'error']) {
      test('$role keeps red dominant', () {
        final c = textRoles[role]!;
        expect(
          c.r / (c.r + c.g + c.b),
          greaterThan(0.5),
          reason: '$role no longer keeps red over half the emitted energy',
        );
      });
    }
  });

  group('red night component outlines', () {
    /// The floor above is about TEXT. WCAG 1.4.11 sets a second one, 3:1, for
    /// the visual boundary of a UI COMPONENT — and this palette failed that one
    /// harder than it ever failed the text floor: `border` measures 1.03:1 on
    /// `surfaceElevated`, which is the surface a dialog draws on, and an
    /// unchecked [SkotiqCheckbox] in the delivery destination editor was
    /// therefore a label with nothing beside it. Nothing said so, because a
    /// prose floor cannot fail a build and this file only measured text.
    ///
    /// `border` itself is NOT widened to clear 3:1. It is the divider weight —
    /// card edges, table rules, the bar under this very screen — and a 3:1
    /// divider on a near-black surface is a cage. The repair is per component:
    /// a control that carries its state in a line draws that line in a token the
    /// palette already holds to a text floor. This asserts the rule from the
    /// other end: the divider stays quiet, and the components that must not are
    /// listed with what they use instead.
    const nonTextFloor = 3.0;

    test('the divider token is quiet, and that is why it is not an outline', () {
      final ratio = contrast(colors.border, surfaces['surfaceElevated']!);
      expect(
        ratio,
        lessThan(nonTextFloor),
        reason:
            'border measures ${ratio.toStringAsFixed(2)}:1 on surfaceElevated. '
            'If it has been widened to clear the component floor, this test is '
            'the wrong shape now — but every control that reached for it must '
            'still be checked, because a token that is legal for one is not '
            'automatically legal for the other',
      );
    });

    /// The outline tokens a control is allowed to reach for, and the control
    /// that reaches for each. `skotiq_checkbox.dart` `_uncheckedOutline`.
    final outlineRoles = <String, Color>{
      'textSecondary (unchecked checkbox)': colors.textSecondary,
      'primary (checked / focused checkbox)': colors.primary,
    };

    for (final role in outlineRoles.entries) {
      test('${role.key} clears 3:1 on every surface level', () {
        for (final surface in surfaces.entries) {
          final ratio = contrast(role.value, surface.value);
          expect(
            ratio,
            greaterThanOrEqualTo(nonTextFloor),
            reason:
                '${role.key} on ${surface.key} measures '
                '${ratio.toStringAsFixed(2)}:1, under the 3:1 floor WCAG '
                '1.4.11 sets for a component boundary',
          );
        }
      });
    }
  });

  group('red night fills', () {
    /// [SkotiqColors.onPrimary] is the ink this palette declares for a
    /// filled control, and `useDarkOnPrimary` makes that the background rather
    /// than white. Brightening success and warning moves them further into the
    /// range where that pairing is the correct one.
    test('onPrimary reads on the status fills', () {
      expect(colors.onPrimary, colors.background);
      for (final role in ['success', 'warning', 'error', 'info']) {
        final ratio = contrast(colors.onPrimary, textRoles[role]!);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              'dark ink on a $role fill measures ${ratio.toStringAsFixed(2)}:1',
        );
      }
    });
  });
}
