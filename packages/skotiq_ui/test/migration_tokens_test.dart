import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Pins the migration tokens added so the per-directory screen migration could
/// swap `BorderRadius.circular(8)` / `fontSize: 13` for a NAMED token. The
/// font-size half is still value-preserving and still locked below.
///
/// The RADIUS half no longer is. The Observatory design pass those tokens were
/// waiting for has landed (`docs/design/overhaul/03-tokens.md` §3.2): there are
/// four radii — 4, 6, 8, 12 — and every `radiusInline*` now forwards to the one
/// it maps to, so the 979 call sites take the new value without an edit. What
/// this group locks is therefore no longer "each token equals its old literal"
/// but "each token equals the scale value it folds onto", which is what wave 4
/// will sed-replace them with.
///
/// Mapping table of record: docs/design/overhaul/03-tokens.md §3.2.
void main() {
  group('In-use radius tokens fold onto the Observatory scale', () {
    test('the scale is the four values and nothing else', () {
      expect(SkotiqTokens.radiusXs, 4.0);
      expect(SkotiqTokens.radiusSm, 6.0);
      expect(SkotiqTokens.radiusMd, 6.0);
      expect(SkotiqTokens.radiusButton, 6.0);
      expect(SkotiqTokens.radiusLg, 8.0);
      expect(SkotiqTokens.radiusXl, 12.0);
      expect(SkotiqTokens.radiusFull, 999.0);
    });

    test('every migration alias equals its wave-4 replacement', () {
      expect(SkotiqTokens.radiusInline2, SkotiqTokens.radiusXs);
      expect(SkotiqTokens.radiusInline4, SkotiqTokens.radiusXs);
      expect(SkotiqTokens.radiusInline8, SkotiqTokens.radiusLg);
      expect(SkotiqTokens.radiusInline9, SkotiqTokens.radiusLg);
      expect(SkotiqTokens.radiusInline11, SkotiqTokens.radiusXl);
    });

    test('convenience BorderRadius objects match their double tokens', () {
      expect(
        SkotiqTokens.borderRadiusInline2,
        BorderRadius.circular(SkotiqTokens.radiusInline2),
      );
      expect(
        SkotiqTokens.borderRadiusInline4,
        BorderRadius.circular(SkotiqTokens.radiusInline4),
      );
      expect(
        SkotiqTokens.borderRadiusInline8,
        BorderRadius.circular(SkotiqTokens.radiusInline8),
      );
      expect(
        SkotiqTokens.borderRadiusInline9,
        BorderRadius.circular(SkotiqTokens.radiusInline9),
      );
      expect(
        SkotiqTokens.borderRadiusInline11,
        BorderRadius.circular(SkotiqTokens.radiusInline11),
      );
    });
  });

  group('In-use font-size tokens are exact-valued', () {
    test('every in-use fontSize literal has an exact token', () {
      expect(SkotiqTypography.fontSize8, 8.0);
      expect(SkotiqTypography.fontSize9, 9.0);
      expect(SkotiqTypography.fontSize9_5, 9.5);
      expect(SkotiqTypography.fontSize10, 10.0);
      expect(SkotiqTypography.fontSize11, 11.0);
      expect(SkotiqTypography.fontSize11_5, 11.5);
      expect(SkotiqTypography.fontSize12, 12.0);
      expect(SkotiqTypography.fontSize12_5, 12.5);
      expect(SkotiqTypography.fontSize13, 13.0);
      expect(SkotiqTypography.fontSize14, 14.0);
      expect(SkotiqTypography.fontSize15, 15.0);
      expect(SkotiqTypography.fontSize16, 16.0);
      expect(SkotiqTypography.fontSize17, 17.0);
      expect(SkotiqTypography.fontSize18, 18.0);
      expect(SkotiqTypography.fontSize20, 20.0);
      expect(SkotiqTypography.fontSize22, 22.0);
      expect(SkotiqTypography.fontSize24, 24.0);
      expect(SkotiqTypography.fontSize26, 26.0);
      expect(SkotiqTypography.fontSize28, 28.0);
    });

    test(
      'numeric tokens agree with the named styles that share their size',
      () {
        // The mapping table says these named styles ARE these sizes; keep that
        // true so a migration can pick either form interchangeably.
        expect(
          SkotiqTypography.overline.fontSize,
          SkotiqTypography.fontSize10,
        );
        expect(
          SkotiqTypography.captionSm.fontSize,
          SkotiqTypography.fontSize11,
        );
        expect(
          SkotiqTypography.caption.fontSize,
          SkotiqTypography.fontSize12,
        );
        expect(
          SkotiqTypography.bodySm.fontSize,
          SkotiqTypography.fontSize13,
        );
        expect(
          SkotiqTypography.body.fontSize,
          SkotiqTypography.fontSize14,
        );
        expect(
          SkotiqTypography.h4.fontSize,
          SkotiqTypography.fontSize16,
        );
        expect(
          SkotiqTypography.telemetryMd.fontSize,
          SkotiqTypography.fontSize18,
        );
        expect(
          SkotiqTypography.h3.fontSize,
          SkotiqTypography.fontSize20,
        );
        expect(
          SkotiqTypography.telemetryLg.fontSize,
          SkotiqTypography.fontSize22,
        );
        expect(
          SkotiqTypography.h2.fontSize,
          SkotiqTypography.fontSize24,
        );
      },
    );

    test('semibold-small inline combos fold onto named roles', () {
      // The migration map folds inline TextStyle(fontSize:, fontWeight:) combos
      // onto these roles; lock the (size + weight) of the two NEW roles added
      // for the semibold-small gap so the fold target stays correct.
      expect(
        SkotiqTypography.labelStrong.fontSize,
        SkotiqTypography.fontSize13,
      );
      expect(SkotiqTypography.labelStrong.fontWeight, FontWeight.w600);
      expect(
        SkotiqTypography.labelStrongSm.fontSize,
        SkotiqTypography.fontSize11,
      );
      expect(SkotiqTypography.labelStrongSm.fontWeight, FontWeight.w600);
    });
  });

  group('Semantic color coverage for migration', () {
    test('standard semantic roles exist on every built-in palette', () {
      for (final colors in [
        SkotiqColors.dark,
        SkotiqColors.light,
        SkotiqColors.redNight,
      ]) {
        // The migration map maps raw Colors.* onto these roles; they must all
        // be present (compile-time guaranteed by the type, asserted for intent).
        expect(colors.error, isA<Color>());
        expect(colors.warning, isA<Color>());
        expect(colors.success, isA<Color>());
        expect(colors.info, isA<Color>());
        expect(colors.textPrimary, isA<Color>());
        expect(colors.textSecondary, isA<Color>());
        expect(colors.textMuted, isA<Color>());
        expect(colors.accent, isA<Color>());
        expect(colors.surface, isA<Color>());
        expect(colors.border, isA<Color>());
      }
    });
  });
}
