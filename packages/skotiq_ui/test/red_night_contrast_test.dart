import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The red-night palette's contrast floors, enforced instead of documented.
///
/// Red night is pure red (G == B == 0). One channel caps contrast on these
/// surfaces near 5:1, so the floors are per role, as in `check_tokens.py`
/// RED_NIGHT_FLOORS: textPrimary, warning and error 4.5:1; textSecondary,
/// success and info 3.5:1; textMuted the 3:1 non-text floor.
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

  const floors = <String, double>{
    'textPrimary': 4.5,
    'warning': 4.5,
    'error': 4.5,
    'textSecondary': 3.5,
    'success': 3.5,
    'info': 3.5,
    'textMuted': 3.0,
  };

  /// Every surface a body of text can land on in this palette.
  ///
  /// `well` is the Observatory inset — the ground under a chart, an image area
  /// or a number field — and on a dark palette it is the DEEPEST surface, so it
  /// is the easy one; it is measured anyway, because the floor is a floor on
  /// every surface and not on the ones that were convenient to check.
  const surfaces = <String, Color>{
    'background': Color(0xFF0A0000),
    'surface': Color(0xFF140000),
    'well': Color(0xFF0F0000),
    'surfaceAlt': Color(0xFF1C0000),
    'surfaceHover': Color(0xFF240000),
    'surfaceElevated': Color(0xFF280000),
    'surfaceOverlay': Color(0xFF300000),
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
      final floor = floors[role.key]!;
      test('${role.key} clears $floor:1 on every surface level', () {
        for (final surface in surfaces.entries) {
          final ratio = contrast(role.value, surface.value);
          expect(
            ratio,
            greaterThanOrEqualTo(floor),
            reason:
                '${role.key} on ${surface.key} measures '
                '${ratio.toStringAsFixed(2)}:1, under the $floor:1 floor this '
                'palette documents',
          );
        }
      });
    }

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
    /// .statusChip` fills at [SkotiqTokens.opacityStatusFill], which lifts the
    /// background toward the text. In one hue the fill costs about a tenth of
    /// the ratio, so chips on the two card surfaces are held to 3.5:1.
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
            greaterThanOrEqualTo(3.5),
            reason:
                '$role on its status chip over $key measures '
                '${ratio.toStringAsFixed(2)}:1',
          );
        }
      });
    }
  });

  group('red night wavelength rule', () {
    /// Rods peak near 507nm, so any green or blue a pixel emits is spent from
    /// the operator's dark adaptation. Every token is pure red.
    final tokens = <String, Color>{
      ...textRoles,
      'primary': colors.primary,
      'accent': colors.accent,
      'brandWarm': colors.brandWarm,
      'startFill': colors.startFill,
      'onStart': colors.onStart,
      'border': colors.border,
      'borderHighlight': colors.borderHighlight,
      'bandDusk': colors.bandDusk,
      'bandTwilight': colors.bandTwilight,
      'bandDark': colors.bandDark,
      'bandDawn': colors.bandDawn,
      for (final surface in surfaces.entries) surface.key: surface.value,
    };

    for (final token in tokens.entries) {
      test('${token.key} is pure red', () {
        expect(token.value.g, 0, reason: '${token.key} emits green');
        expect(token.value.b, 0, reason: '${token.key} emits blue');
      });
    }

    test('the text ladder is strictly ordered', () {
      expect(
        colors.textPrimary.computeLuminance(),
        greaterThan(colors.textSecondary.computeLuminance()),
      );
      expect(
        colors.textSecondary.computeLuminance(),
        greaterThan(colors.textMuted.computeLuminance()),
      );
    });
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
    /// than white. It is held to each role's own floor.
    test('onPrimary reads on the status fills', () {
      expect(colors.onPrimary, colors.background);
      for (final role in ['success', 'warning', 'error', 'info']) {
        final ratio = contrast(colors.onPrimary, textRoles[role]!);
        expect(
          ratio,
          greaterThanOrEqualTo(floors[role]!),
          reason:
              'dark ink on a $role fill measures ${ratio.toStringAsFixed(2)}:1',
        );
      }
    });
  });
}
