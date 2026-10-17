import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/rendering/sprite_atlas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SkySpriteAtlas.bake', () {
    test('bakes star + DSO sprites at the expected sizes', () {
      final atlas = SkySpriteAtlas.bake(dpr: 2.0, softness: 1.5, spikes: true);
      addTearDown(atlas.dispose);

      // Star sprite is 128 logical px * dpr, square, both variants share size.
      expect(atlas.starSpriteSize, 128 * 2.0);
      expect(atlas.starPlain.width, 256);
      expect(atlas.starPlain.height, 256);
      expect(atlas.starSpiked.width, 256);
      expect(atlas.starSpiked.height, 256);

      // The star source rect covers the whole sprite.
      expect(atlas.starSrcRect, const Rect.fromLTWH(0, 0, 256, 256));

      // DSO glyph cell is 96 logical px * dpr; the sheet is one row of glyphs.
      expect(atlas.dsoGlyphSize, 96 * 2.0);
      expect(atlas.dsoSheet.height, 192);
      expect(
        atlas.dsoSheet.width % 192,
        0,
        reason: 'sheet width should be an integer number of glyph cells',
      );
      expect(
        atlas.dsoSheet.width ~/ 192,
        greaterThanOrEqualTo(6),
        reason: 'one cell per glyph family',
      );
    });

    test('matches() tracks the bake parameters', () {
      final atlas = SkySpriteAtlas.bake(dpr: 2.0, softness: 1.5, spikes: true);
      addTearDown(atlas.dispose);

      expect(atlas.matches(2.0, 1.5, true), isTrue);
      expect(atlas.matches(1.5, 1.5, true), isFalse); // dpr bucket changed
      expect(atlas.matches(2.0, 2.0, true), isFalse); // softness changed
      expect(atlas.matches(2.0, 1.5, false), isFalse); // spike variant changed
    });

    test('each DSO type family maps to a distinct in-bounds source rect', () {
      final atlas = SkySpriteAtlas.bake(dpr: 1.0, softness: 1.0, spikes: false);
      addTearDown(atlas.dispose);

      final sheetRect = Rect.fromLTWH(
        0,
        0,
        atlas.dsoSheet.width.toDouble(),
        atlas.dsoSheet.height.toDouble(),
      );

      // Representative members of each glyph family.
      final samples = <DsoType>[
        DsoType.galaxy,
        DsoType.nebula,
        DsoType.planetaryNebula,
        DsoType.openCluster,
        DsoType.globularCluster,
        DsoType.supernova,
        DsoType.star, // generic fallback
      ];

      final rects = <Rect>{};
      for (final type in samples) {
        final r = atlas.dsoSrcRect(type);
        // Each rect must sit fully inside the sheet.
        expect(
          sheetRect.contains(r.topLeft),
          isTrue,
          reason: '$type rect top-left out of sheet',
        );
        expect(
          r.right,
          lessThanOrEqualTo(sheetRect.right),
          reason: '$type rect overflows sheet width',
        );
        // Cell is the glyph size square.
        expect(r.width, atlas.dsoGlyphSize);
        expect(r.height, atlas.dsoGlyphSize);
        rects.add(r);
      }
      // Seven distinct families -> seven distinct cells.
      expect(rects.length, samples.length);

      // Galaxy subtypes fold onto the galaxy family (same cell).
      expect(
        atlas.dsoSrcRect(DsoType.galaxyPair),
        atlas.dsoSrcRect(DsoType.galaxy),
      );
      // Emission nebula folds onto the nebula family.
      expect(
        atlas.dsoSrcRect(DsoType.emissionNebula),
        atlas.dsoSrcRect(DsoType.nebula),
      );
    });

    test('low tier without spikes still bakes a usable spiked variant', () {
      // When spikes are disabled the spiked variant is a plain copy, so the
      // overlay pass can always index it safely.
      final atlas = SkySpriteAtlas.bake(dpr: 1.0, softness: 1.0, spikes: false);
      addTearDown(atlas.dispose);
      expect(atlas.spikes, isFalse);
      expect(atlas.starSpiked.width, atlas.starPlain.width);
    });
  });
}
