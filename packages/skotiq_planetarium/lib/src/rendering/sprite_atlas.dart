import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../celestial_object.dart' show DsoType;

/// GPU sprite textures for the batched (`Canvas.drawRawAtlas`) star and DSO
/// passes.
///
/// The glow / PSF / glyph is baked ONCE into small white sprite textures and
/// the whole field is drawn as batched textured quads — one `drawRawAtlas` call
/// per layer, tinted per-object with `BlendMode.modulate`. Per-object canvas
/// primitives (`MaskFilter.blur`, `saveLayer`, radial-gradient shaders) cost
/// fill rate per object, which the object counts here cannot afford.
///
/// All sprites are baked white with premultiplied alpha so a per-object color in
/// the atlas `colors` list tints them via `modulate` (white * color = color),
/// and so the canvas composite can be additive (`BlendMode.plus`) without dark
/// fringing.
///
/// The bake is synchronous (`Picture.toImageSync`) so it can run inside the
/// first synchronous `paint()` call and the resulting image is usable the same
/// frame. The atlas is cached and only rebuilt when the device-pixel-ratio
/// bucket or the soft/spike quality knob changes.
class SkySpriteAtlas {
  SkySpriteAtlas._({
    required this.starPlain,
    required this.starSpiked,
    required this.starSpriteSize,
    required this.dsoSheet,
    required this.dsoGlyphSize,
    required this.dpr,
    required this.softness,
    required this.spikes,
    required Map<DsoType, Rect> dsoRects,
  }) : _dsoRects = dsoRects;

  /// White star PSF sprite WITHOUT diffraction spikes (Gaussian core + faint
  /// Airy ring). Used for the common bright stars.
  final ui.Image starPlain;

  /// White star PSF sprite WITH 4 diffraction spikes (plus faint 45-degree
  /// secondaries) baked in. Used for the very brightest stars when the quality
  /// tier enables spikes.
  final ui.Image starSpiked;

  /// The square pixel size of each star sprite image (both variants share it).
  final double starSpriteSize;

  /// The DSO glyph sheet: one glyph per [DsoType] family laid out in a grid.
  final ui.Image dsoSheet;

  /// The square pixel size of each glyph cell within [dsoSheet].
  final double dsoGlyphSize;

  /// Device-pixel-ratio bucket this atlas was baked for.
  final double dpr;

  /// Glow softness knob this atlas was baked for (higher = softer/larger halo).
  final double softness;

  /// Whether the spiked star variant has real spikes baked (true) or is a copy
  /// of the plain sprite (false, low tiers).
  final bool spikes;

  final Map<DsoType, Rect> _dsoRects;

  /// Logical (un-scaled) radius of the star sprite's bright core, as a fraction
  /// of the half-sprite. The caller scales the whole sprite so that this core
  /// fraction maps onto the star's screen radius.
  static const double starCoreFraction = 0.16;

  /// Source rect covering the entire plain/spiked star sprite.
  Rect get starSrcRect => Rect.fromLTWH(0, 0, starSpriteSize, starSpriteSize);

  /// Source rect (within [dsoSheet]) for the glyph that represents [type].
  Rect dsoSrcRect(DsoType type) =>
      _dsoRects[_glyphFamily(type).type] ?? _dsoRects[_DsoGlyph.generic.type]!;

  /// The DSO glyph families, in sheet order.
  static const List<_DsoGlyph> _glyphOrder = _DsoGlyph.values;

  // Build / cache

  /// Whether this atlas was baked for the given [dpr]/[softness]/[spikes].
  bool matches(double dpr, double softness, bool spikes) =>
      this.dpr == dpr && this.softness == softness && this.spikes == spikes;

  /// Bake a fresh atlas for the given device-pixel-ratio bucket and quality
  /// knobs. Synchronous: uses `Picture.toImageSync` so the images are ready in
  /// the same paint pass.
  ///
  /// [dpr] is bucketed by the caller (rounded) so minor DPR jitter doesn't
  /// rebuild. [softness] scales the halo radius/falloff (higher tiers softer).
  /// [spikes] bakes diffraction spikes into the spiked variant.
  factory SkySpriteAtlas.bake({
    required double dpr,
    required double softness,
    required bool spikes,
  }) {
    // Logical sprite extents. The star sprite is 128 logical px; the DSO glyph
    // cell is 96 logical px. Multiply by DPR so the baked texels are crisp when
    // the sprite is later drawn at roughly 1:1 on a high-DPR display, but cap so
    // the bake stays cheap.
    final clampedDpr = dpr.clamp(1.0, 3.0);
    final starPx = (128 * clampedDpr).round();
    final glyphPx = (96 * clampedDpr).round();

    final starPlain = _bakeStarSprite(starPx, softness, withSpikes: false);
    final starSpiked = spikes
        ? _bakeStarSprite(starPx, softness, withSpikes: true)
        : _bakeStarSprite(starPx, softness, withSpikes: false);

    final (sheet, rects) = _bakeDsoSheet(glyphPx);

    return SkySpriteAtlas._(
      starPlain: starPlain,
      starSpiked: starSpiked,
      starSpriteSize: starPx.toDouble(),
      dsoSheet: sheet,
      dsoGlyphSize: glyphPx.toDouble(),
      dpr: dpr,
      softness: softness,
      spikes: spikes,
      dsoRects: rects,
    );
  }

  /// Release the GPU images. Call when replacing a cached atlas.
  void dispose() {
    starPlain.dispose();
    starSpiked.dispose();
    dsoSheet.dispose();
  }

  // Star sprite baking

  /// Bake one white star PSF sprite of [px]×[px] texels.
  ///
  /// The profile is three components:
  ///   * a bright Gaussian core,
  ///   * a faint Airy-style ring just outside it,
  ///   * a broad soft halo, [softness]-scaled.
  /// All channels are white; alpha carries the profile. When [withSpikes] is
  /// set, 4 cardinal diffraction spikes plus faint 45-degree secondaries are
  /// added.
  static ui.Image _bakeStarSprite(
    int px,
    double softness, {
    required bool withSpikes,
  }) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = px.toDouble();
    final c = Offset(size / 2, size / 2);
    final half = size / 2;

    // Radii as fractions of the half-sprite. The core is small and bright; the
    // halo fills most of the sprite. Softness widens the halo and softens the
    // falloff so higher tiers read as a gentler bloom.
    final coreR = half * starCoreFraction;
    final ringR = half * (0.34 + 0.04 * softness);
    final haloR = half * (0.92);

    // Broad soft halo (replaces the per-object gradient glow). Additive feel is
    // achieved at draw time via BlendMode.plus; here we just lay down a white
    // radial falloff in alpha.
    final haloPaint = Paint()
      ..blendMode = BlendMode.srcOver
      ..shader = ui.Gradient.radial(
        c,
        haloR,
        [
          Colors.white.withValues(alpha: 0.42),
          Colors.white.withValues(alpha: 0.10 + 0.04 * softness),
          Colors.white.withValues(alpha: 0.0),
        ],
        // Softer falloff (mid-stop pushed out) for higher softness.
        [0.0, 0.45 + 0.1 * (softness - 1.0).clamp(0.0, 1.0), 1.0],
      );
    canvas.drawCircle(c, haloR, haloPaint);

    // Faint Airy-style ring: a thin bright annulus a little outside the core.
    final ringPaint = Paint()
      ..blendMode = BlendMode.plus
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, half * 0.05)
      ..shader = ui.Gradient.radial(
        c,
        ringR,
        [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.22),
          Colors.white.withValues(alpha: 0.0),
        ],
        const [0.0, 0.82, 1.0],
      );
    canvas.drawCircle(c, ringR * 0.9, ringPaint);

    if (withSpikes) {
      _bakeSpikes(canvas, c, coreR, half);
    }

    // Bright Gaussian core, drawn last and additive so the center reads
    // white-hot.
    final corePaint = Paint()
      ..blendMode = BlendMode.plus
      ..shader = ui.Gradient.radial(
        c,
        coreR * 2.0,
        [
          Colors.white.withValues(alpha: 1.0),
          Colors.white.withValues(alpha: 0.85),
          Colors.white.withValues(alpha: 0.0),
        ],
        const [0.0, 0.35, 1.0],
      );
    canvas.drawCircle(c, coreR * 2.0, corePaint);

    return recorder.endRecording().toImageSync(px, px);
  }

  /// Bake 4 cardinal diffraction spikes plus faint 45-degree secondaries into
  /// the star sprite. White, additive, fading to transparent at the tips.
  static void _bakeSpikes(Canvas canvas, Offset c, double coreR, double half) {
    final spikeLen = half * 0.9;
    final primary = Paint()
      ..blendMode = BlendMode.plus
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.0, half * 0.025);
    final secondary = Paint()
      ..blendMode = BlendMode.plus
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(0.5, half * 0.014);

    // Primary spikes: horizontal + vertical.
    for (final angle in [0.0, 90.0, 180.0, 270.0]) {
      final rad = angle * math.pi / 180.0;
      final end = Offset(
        c.dx + math.cos(rad) * spikeLen,
        c.dy + math.sin(rad) * spikeLen,
      );
      primary.shader = ui.Gradient.linear(c, end, [
        Colors.white.withValues(alpha: 0.55),
        Colors.white.withValues(alpha: 0.0),
      ]);
      canvas.drawLine(c, end, primary);
    }

    // Secondary 45-degree spikes (fainter, shorter).
    final secLen = spikeLen * 0.6;
    for (final angle in [45.0, 135.0, 225.0, 315.0]) {
      final rad = angle * math.pi / 180.0;
      final end = Offset(
        c.dx + math.cos(rad) * secLen,
        c.dy + math.sin(rad) * secLen,
      );
      secondary.shader = ui.Gradient.linear(c, end, [
        Colors.white.withValues(alpha: 0.22),
        Colors.white.withValues(alpha: 0.0),
      ]);
      canvas.drawLine(c, end, secondary);
    }
  }

  // DSO glyph sheet baking

  /// Bake the DSO glyph sheet: one white glyph per family laid out left-to-right
  /// in a single row. Returns the sheet image plus a map from family to its
  /// source rect.
  ///
  /// Each glyph is drawn WHITE (alpha-only); the per-DSO atlas color tints it
  /// via `BlendMode.modulate` at draw time. One glyph per family: galaxy =
  /// elongated ellipse + core, open cluster = sparse dot field + ring, globular
  /// = bright core + halo, nebula = soft cloud, planetary = double ring + dot,
  /// supernova = starburst.
  static (ui.Image, Map<DsoType, Rect>) _bakeDsoSheet(int glyphPx) {
    final count = _glyphOrder.length;
    final sheetW = glyphPx * count;
    final sheetH = glyphPx;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rects = <DsoType, Rect>{};

    for (var i = 0; i < count; i++) {
      final glyph = _glyphOrder[i];
      final cellLeft = (i * glyphPx).toDouble();
      final cellRect = Rect.fromLTWH(
        cellLeft,
        0,
        glyphPx.toDouble(),
        glyphPx.toDouble(),
      );
      rects[glyph.type] = cellRect;

      canvas.save();
      canvas.translate(cellLeft + glyphPx / 2, glyphPx / 2);
      _bakeGlyph(canvas, glyph, glyphPx / 2);
      canvas.restore();
    }

    final sheet = recorder.endRecording().toImageSync(sheetW, sheetH);
    return (sheet, rects);
  }

  /// Bake a single white DSO glyph centered at the canvas origin, fitting within
  /// [half] of the cell. The glyph is drawn with a small margin so its halo /
  /// extent doesn't clip the cell edge (which would tile-bleed under the atlas
  /// sampler).
  static void _bakeGlyph(Canvas canvas, _DsoGlyph glyph, double half) {
    // Keep a margin so soft edges don't touch the cell border.
    final r = half * 0.82;
    const white = Colors.white;

    switch (glyph) {
      case _DsoGlyph.galaxy:
        // Elongated soft ellipse + bright core (axis ratio baked at 0.5; the
        // draw path rotates by position angle, and non-round galaxies still
        // read as elongated because the glyph itself is elongated).
        final body = Paint()
          ..shader = ui.Gradient.radial(
            Offset.zero,
            r,
            [
              white.withValues(alpha: 0.55),
              white.withValues(alpha: 0.18),
              white.withValues(alpha: 0.0),
            ],
            const [0.0, 0.55, 1.0],
          );
        canvas.save();
        canvas.scale(1.0, 0.5);
        canvas.drawCircle(Offset.zero, r, body);
        canvas.restore();
        canvas.drawCircle(
          Offset.zero,
          r * 0.18,
          Paint()..color = white.withValues(alpha: 0.95),
        );
        break;

      case _DsoGlyph.nebula:
        // Soft cloud: a few overlapping radial puffs.
        final rng = math.Random(11);
        for (var i = 0; i < 5; i++) {
          final a = rng.nextDouble() * 2 * math.pi;
          final d = rng.nextDouble() * r * 0.4;
          final pr = r * (0.45 + rng.nextDouble() * 0.35);
          final puff = Paint()
            ..blendMode = BlendMode.plus
            ..shader = ui.Gradient.radial(
              Offset(math.cos(a) * d, math.sin(a) * d),
              pr,
              [white.withValues(alpha: 0.20), white.withValues(alpha: 0.0)],
            );
          canvas.drawCircle(Offset(math.cos(a) * d, math.sin(a) * d), pr, puff);
        }
        break;

      case _DsoGlyph.planetary:
        // Double ring (outer faint + inner brighter) + central dot.
        final outer = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, r * 0.12)
          ..color = white.withValues(alpha: 0.5);
        canvas.drawCircle(Offset.zero, r * 0.7, outer);
        final inner = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, r * 0.09)
          ..color = white.withValues(alpha: 0.35);
        canvas.drawCircle(Offset.zero, r * 0.45, inner);
        canvas.drawCircle(
          Offset.zero,
          math.max(1.5, r * 0.12),
          Paint()..color = white.withValues(alpha: 0.85),
        );
        break;

      case _DsoGlyph.openCluster:
        // Sparse dot field + faint boundary ring.
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, r * 0.04)
          ..color = white.withValues(alpha: 0.3);
        canvas.drawCircle(Offset.zero, r, ring);
        final rng = math.Random(7);
        final dot = Paint()..style = PaintingStyle.fill;
        for (var i = 0; i < 7; i++) {
          final a = rng.nextDouble() * 2 * math.pi;
          final d = rng.nextDouble() * r * 0.7;
          dot.color = white.withValues(alpha: 0.55 + rng.nextDouble() * 0.4);
          canvas.drawCircle(
            Offset(math.cos(a) * d, math.sin(a) * d),
            math.max(1.0, r * 0.08),
            dot,
          );
        }
        break;

      case _DsoGlyph.globular:
        // Bright core + soft halo + faint cross hint.
        final halo = Paint()
          ..shader = ui.Gradient.radial(
            Offset.zero,
            r,
            [
              white.withValues(alpha: 0.5),
              white.withValues(alpha: 0.18),
              white.withValues(alpha: 0.0),
            ],
            const [0.0, 0.45, 1.0],
          );
        canvas.drawCircle(Offset.zero, r, halo);
        canvas.drawCircle(
          Offset.zero,
          r * 0.18,
          Paint()..color = white.withValues(alpha: 0.9),
        );
        final cross = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, r * 0.03)
          ..color = white.withValues(alpha: 0.3);
        canvas.drawLine(Offset(-r, 0), Offset(r, 0), cross);
        canvas.drawLine(Offset(0, -r), Offset(0, r), cross);
        break;

      case _DsoGlyph.supernova:
        // Starburst: bright core + 4 spikes.
        canvas.drawCircle(
          Offset.zero,
          r * 0.22,
          Paint()..color = white.withValues(alpha: 0.95),
        );
        final spike = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(1.0, r * 0.06)
          ..color = white.withValues(alpha: 0.7);
        for (var a = 0.0; a < math.pi * 2; a += math.pi / 2) {
          canvas.drawLine(
            Offset.zero,
            Offset(math.cos(a) * r * 0.85, math.sin(a) * r * 0.85),
            spike,
          );
        }
        break;

      case _DsoGlyph.generic:
        // Plain soft disc.
        final disc = Paint()
          ..shader = ui.Gradient.radial(Offset.zero, r, [
            white.withValues(alpha: 0.5),
            white.withValues(alpha: 0.0),
          ]);
        canvas.drawCircle(Offset.zero, r, disc);
        break;
    }
  }

  /// Map a DSO type onto the glyph family that represents it.
  static _DsoGlyph _glyphFamily(DsoType type) {
    switch (type) {
      case DsoType.galaxy:
      case DsoType.galaxyPair:
      case DsoType.galaxyTriplet:
      case DsoType.galaxyGroup:
        return _DsoGlyph.galaxy;

      case DsoType.nebula:
      case DsoType.emissionNebula:
      case DsoType.reflectionNebula:
      case DsoType.hiiRegion:
      case DsoType.clusterWithNebulosity:
      case DsoType.darkNebula:
        return _DsoGlyph.nebula;

      case DsoType.planetaryNebula:
        return _DsoGlyph.planetary;

      case DsoType.openCluster:
      case DsoType.asterism:
      case DsoType.starCloud:
      case DsoType.association:
        return _DsoGlyph.openCluster;

      case DsoType.globularCluster:
        return _DsoGlyph.globular;

      case DsoType.supernova:
      case DsoType.nova:
        return _DsoGlyph.supernova;

      case DsoType.star:
      case DsoType.doubleStar:
      case DsoType.other:
        return _DsoGlyph.generic;
    }
  }
}

/// The distinct DSO glyph families baked into the sheet. Each maps to a known
/// sub-rect; [SkySpriteAtlas._glyphFamily] folds the full [DsoType] set onto
/// these.
enum _DsoGlyph {
  galaxy(DsoType.galaxy),
  nebula(DsoType.nebula),
  planetary(DsoType.planetaryNebula),
  openCluster(DsoType.openCluster),
  globular(DsoType.globularCluster),
  supernova(DsoType.supernova),
  generic(DsoType.star);

  const _DsoGlyph(this.type);

  /// A representative [DsoType] used as the rect-map key for this family.
  final DsoType type;
}
