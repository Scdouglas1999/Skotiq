// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

/// Major-axis size, in canvas pixels, past which a deep-sky object stops being
/// a marker and is drawn at its real extent.
///
/// Below it the glyph atlas is the right answer: one batched quad, floored at a
/// legible minimum so faint small objects are still findable. Above it the
/// square, uniformly-scaled sprite cannot say how big the thing is or which way
/// it lies, and that is the question the planetarium exists to answer.
const double _extendedDsoMinPx = 24.0;

extension _SkyCanvasPainterStellarObjects on SkyCanvasPainter {
  void _drawStars(Canvas canvas, Size size, Offset center, double scale) {
    // Ultra-minimal mode: ALL stars as raw points, no circles, no PSF.
    // Minimal mode has no twinkle, so the entire star field belongs to the
    // base layer; the overlay layer draws nothing (avoids a double-draw).
    if (qualityConfig.quality == RenderQuality.minimal) {
      if (_drawBase) {
        _drawStarsMinimal(canvas, size, center, scale);
      }
      return;
    }

    // Respect quality config limits. The star list is already pre-filtered by
    // the dynamic magnitude provider (fovFilteredStarsProvider) based on FOV,
    // so we only apply the quality config's render count cap here. We use the
    // quality config's magnitude limit as an additional safeguard rather than
    // the static SkyRenderConfig.starMagnitudeLimit, which is a UI default
    // that doesn't account for zoom level.
    final maxStars = qualityConfig.maxStarsToRender;
    final magLimit = qualityConfig.starMagnitudeLimit;

    // Twinkle animation enabled in quality mode
    final doTwinkle =
        qualityConfig.animateStarTwinkle && animationPhase != null;

    // Pre-calculate LST for atmospheric extinction (computed once, not per-star)
    final doExtinction = qualityConfig.enableAtmosphericExtinction;
    final lst = doExtinction
        ? AstronomyCalculations.localSiderealTime(observationTime, longitude)
        : 0.0;

    // Parallax effect: offset dim stars during pan for depth illusion
    final doParallax =
        qualityConfig.enableParallax &&
        parallaxPanDelta != null &&
        parallaxPanDelta!.distance > 0.5;

    // GPU-batched star field via drawRawAtlas. Every star is encoded as one
    // textured quad of the baked white PSF sprite, tinted per-star by its color
    // (atlas BlendMode.modulate) and composited additively (BlendMode.plus).
    // The whole field draws in ONE drawRawAtlas call per sprite variant per
    // layer — no per-star blur, saveLayer or gradient shader.
    //
    // Layer split (preserved): the base layer batches dim + medium stars (plain
    // sprite); the overlay layer batches bright stars (spiked sprite if the tier
    // enables it) with twinkle applied as a per-star scale/alpha modulation in
    // the transform/color it builds.
    final atlas = _atlas(_devicePixelRatio);
    final spriteSize = atlas.starSpriteSize;
    final spriteHalf = spriteSize / 2;
    // Sprite px-radius of the bright core. The whole sprite is scaled so this
    // core maps onto the star's screen radius, and the surrounding halo scales
    // with it — glow grows with the star.
    final coreSpritePx = spriteHalf * SkySpriteAtlas.starCoreFraction;

    // Base-layer batch (dim + medium, plain sprite) lives in the primary
    // scratch buffers; overlay-layer batch (bright, spiked) in the secondary.
    var baseCount = 0;
    var brightCount = 0;
    final srcRect = atlas.starSrcRect;

    var starsProcessed = 0;

    for (final star in stars) {
      if (starsProcessed >= maxStars) break;
      final rawMag = star.magnitude ?? 99;
      // The catalog query returns stars magnitude-sorted (brightest first), so
      // once we pass the magnitude limit every remaining star is fainter and
      // can be skipped — break instead of scanning the whole list.
      if (rawMag > magLimit) break;

      // The overlay layer owns ONLY the bright (mag < 1.5) twinkle pass. Since
      // the list is brightest-first, everything from the first non-bright star
      // on belongs to the base layer, so the overlay is finished here. Breaking
      // before the projection matters: this pass runs on every pan frame and,
      // while an object is selected, on every selection-pulse tick — without
      // the break it projected the entire star list (thousands of stars) to
      // draw a dozen sprites.
      if (!_drawBase && rawMag >= 1.5) break;

      // Cull BEFORE projecting: reject stars outside the view cone with a cheap
      // dot product, and reuse the per-pose projected offset when available.
      var offset = _projectObjectCulled(
        star,
        star.coordinates.raDegrees,
        star.coordinates.dec,
        center,
        scale,
      );
      if (offset == null || !_isInView(offset, size)) continue;

      final magnitude = star.magnitude ?? 5.0;

      // Render-scope split: the base layer owns dim + medium stars; the overlay
      // layer owns the bright-star (twinkle) pass. Skip the work that this
      // layer doesn't own so each star is drawn exactly once across the two
      // layers. Bright threshold matches the bucketing below (mag < 1.5).
      final isBright = magnitude < 1.5;
      if (isBright && !_drawOverlay) continue;
      if (!isBright && !_drawBase) continue;

      // The ground is painted on the BASE layer (paint_lifecycle.dart, after the
      // sky objects) so paint order occludes everything drawn there. This bright
      // pass, however, runs in a SEPARATE CustomPaint stacked ABOVE the base
      // whenever star twinkle is on — the desktop default — so paint order
      // cannot reach it: a star 11.5 deg below the horizon measured peak
      // luminance 196 on the overlay against 22 (pure ground colour) on the
      // base. That is how Fomalhaut came to sit as a bright star in the middle
      // of the terrain. Cull it explicitly for the overlay scope only; in `base`
      // and `full` scopes the ground already covers it.
      if (renderScope == SkyRenderScope.overlay &&
          _isBehindGround(star.coordinates.raDegrees, star.coordinates.dec)) {
        continue;
      }

      // Apply parallax offset to dim stars (mag > 4)
      if (doParallax && magnitude > 4.0) {
        final parallaxFactor = ((magnitude - 4.0) / 6.0).clamp(0.0, 1.0) * 0.02;
        offset = Offset(
          offset.dx + parallaxPanDelta!.dx * parallaxFactor,
          offset.dy + parallaxPanDelta!.dy * parallaxFactor,
        );
      }

      var radius = _magnitudeToRadius(magnitude);
      var brightness = _magnitudeToBrightness(magnitude);

      // Apply twinkle effect for brighter stars (mag < 4)
      if (doTwinkle && magnitude < 4.0) {
        final starPhase =
            (star.coordinates.ra * 1000 + star.coordinates.dec * 100) % 1.0;
        final twinklePhase = (animationPhase! + starPhase) % 1.0;
        final twinkleFactor = magnitude < 2.0 ? 0.15 : 0.08;
        final twinkleValue =
            math.sin(twinklePhase * 2 * math.pi) * twinkleFactor;
        brightness = (brightness + twinkleValue).clamp(0.0, 1.0);
        if (magnitude < 1.5) {
          radius *= 1.0 + twinkleValue * 0.3;
        }
      }

      // Star color
      var color = _starColor(star);
      color = _getEnhancedStarColor(color, magnitude);

      // Atmospheric extinction for bright stars only - uses precomputed LUT
      if (doExtinction && magnitude < 3.0) {
        final (alt, _) = AstronomyCalculations.equatorialToHorizontal(
          raDeg: star.coordinates.raDegrees,
          decDeg: star.coordinates.dec,
          latitudeDeg: latitude,
          lstHours: lst,
        );
        if (alt < 30) {
          final (extinctionFactor, redShift) = AtmosphericExtinctionLUT.lookup(
            alt,
          );
          brightness *= extinctionFactor;
          color = Color.lerp(color, const Color(0xFFFFAA88), redShift)!;
        }
      }

      // Sprite scale so the baked core maps onto the star's screen radius. Dim
      // stars are tiny; a hard floor keeps even the faintest star a visible
      // dot (the sprite core is ~21px at 128px so the floor stays sub-pixel).
      final spriteScale = (radius / coreSpritePx).clamp(0.02, 4.0);

      // Per-star tint: the sprite is white, so the atlas color IS the star color
      // with alpha = brightness. modulate multiplies white*color -> color, and
      // the additive composite sums overlaps.
      final tint = color.withValues(alpha: brightness.clamp(0.0, 1.0));
      final argb = tint.toARGB32();

      if (isBright) {
        SkyCanvasPainter._ensureAtlasScratch2(brightCount + 1);
        _writeStarTransform(
          SkyCanvasPainter._atlasTransforms2,
          SkyCanvasPainter._atlasRects2,
          SkyCanvasPainter._atlasColors2,
          brightCount,
          spriteScale,
          spriteHalf,
          offset,
          srcRect,
          argb,
        );
        brightCount++;
      } else {
        SkyCanvasPainter._ensureAtlasScratch(baseCount + 1);
        _writeStarTransform(
          SkyCanvasPainter._atlasTransforms,
          SkyCanvasPainter._atlasRects,
          SkyCanvasPainter._atlasColors,
          baseCount,
          spriteScale,
          spriteHalf,
          offset,
          srcRect,
          argb,
        );
        baseCount++;
      }

      starsProcessed++;
    }

    // BASE LAYER: one drawRawAtlas for the dim + medium plain-sprite field.
    if (baseCount > 0) {
      canvas.drawRawAtlas(
        atlas.starPlain,
        Float32List.sublistView(
          SkyCanvasPainter._atlasTransforms,
          0,
          baseCount * 4,
        ),
        Float32List.sublistView(SkyCanvasPainter._atlasRects, 0, baseCount * 4),
        Int32List.sublistView(SkyCanvasPainter._atlasColors, 0, baseCount),
        BlendMode.modulate,
        null,
        SkyCanvasPainter._starAtlasPaint,
      );
    }

    // OVERLAY LAYER: one drawRawAtlas for the bright (twinkle) field, using the
    // spiked sprite when the tier enables diffraction spikes.
    if (brightCount > 0) {
      canvas.drawRawAtlas(
        qualityConfig.useDiffractionSpikes ? atlas.starSpiked : atlas.starPlain,
        Float32List.sublistView(
          SkyCanvasPainter._atlasTransforms2,
          0,
          brightCount * 4,
        ),
        Float32List.sublistView(
          SkyCanvasPainter._atlasRects2,
          0,
          brightCount * 4,
        ),
        Int32List.sublistView(SkyCanvasPainter._atlasColors2, 0, brightCount),
        BlendMode.modulate,
        null,
        SkyCanvasPainter._starAtlasPaint,
      );
    }

    // Bright-star labels are drawn on the overlay layer (where the bright pass
    // lives) so they stay with their stars. The atlas pass already placed the
    // glyphs; here we only lay out text. Low tiers suppress these labels.
    if (_drawOverlay && !qualityConfig.reduceLabels) {
      _drawBrightStarLabels(canvas, size, center, scale, maxStars, magLimit);
    }
  }

  /// Encode one star sprite into the atlas scratch buffers at slot [i].
  ///
  /// RSTransform (rotation 0) is encoded directly: with scos=scale, ssin=0 and
  /// the sprite centered at [offset], the translate components fold in the
  /// anchor at the sprite center so the sprite is centered on the star.
  ///   tx = offset.dx - scale * spriteHalf
  ///   ty = offset.dy - scale * spriteHalf
  /// The source rect is the whole sprite; the color tints it via modulate.
  void _writeStarTransform(
    Float32List transforms,
    Float32List rects,
    Int32List colors,
    int i,
    double scale,
    double spriteHalf,
    Offset offset,
    Rect srcRect,
    int argb,
  ) {
    final t = i * 4;
    transforms[t] = scale; // scos
    transforms[t + 1] = 0.0; // ssin
    transforms[t + 2] = offset.dx - scale * spriteHalf; // tx
    transforms[t + 3] = offset.dy - scale * spriteHalf; // ty

    rects[t] = srcRect.left;
    rects[t + 1] = srcRect.top;
    rects[t + 2] = srcRect.right;
    rects[t + 3] = srcRect.bottom;

    colors[i] = argb;
  }

  /// Lay out and paint bright-star name labels. Separated from the atlas pass so
  /// the hot sprite loop stays allocation-free; this walks the (short) prefix of
  /// the magnitude-sorted list down to mag 2.0 and places non-overlapping names.
  void _drawBrightStarLabels(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
    int maxStars,
    double magLimit,
  ) {
    var processed = 0;
    for (final star in stars) {
      if (processed >= maxStars) break;
      final magnitude = star.magnitude ?? 5.0;
      if (magnitude > magLimit) break;
      // Labels are only drawn for the brightest stars: the overlay pass owns
      // the sprites below mag 1.5, labels run to mag 2.0.
      if (magnitude >= 2.0) break;
      // Only stars with a real designation are worth labelling. The catalogue
      // loader falls back to the bare HYG row id when a star has no proper,
      // Bayer or Flamsteed name, and printing "HYG113360" next to a star tells
      // the user nothing while taking a label slot from something that would.
      if (star.name.isEmpty || _isBareCatalogId(star.name)) {
        processed++;
        continue;
      }
      // Do not name a star the observer's own ground is in front of.
      if (_isBehindGround(star.coordinates.raDegrees, star.coordinates.dec)) {
        processed++;
        continue;
      }

      final offset = _projectObjectCulled(
        star,
        star.coordinates.raDegrees,
        star.coordinates.dec,
        center,
        scale,
      );
      if (offset == null || !_isInView(offset, size)) {
        processed++;
        continue;
      }

      final radius = _magnitudeToRadius(magnitude);
      final fontSize = _getLabelFontSize(magnitude, 'star');
      final fontWeight = _getLabelFontWeight(magnitude);
      final textStyle = TextStyle(
        color: Colors.white.withValues(alpha: 0.6),
        fontSize: fontSize,
        fontWeight: fontWeight,
      );
      final textPainter = _TextCache.get(star.name, textStyle);

      final preferredPos = offset + Offset(radius + 3, -textPainter.height / 2);
      final labelPos = _labelManager.findPlacement(
        preferredPos,
        Size(textPainter.width, textPainter.height),
        size,
      );
      if (labelPos != null) {
        textPainter.paint(canvas, labelPos);
      }
      processed++;
    }
  }

  /// Ultra-minimal star rendering: all stars as raw points in a single draw call.
  /// No circles, no PSF, no glow. Designed for Raspberry Pi at 30fps.
  void _drawStarsMinimal(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    final maxStars = qualityConfig.maxStarsToRender;
    final magLimit = qualityConfig.starMagnitudeLimit;

    // Collect all visible star positions into a single Float32List
    final points = <double>[];
    var starsProcessed = 0;

    for (final star in stars) {
      if (starsProcessed >= maxStars) break;
      // Magnitude-sorted list: stop once past the limit instead of scanning on.
      if ((star.magnitude ?? 99) > magLimit) break;

      final offset = _projectObjectCulled(
        star,
        star.coordinates.raDegrees,
        star.coordinates.dec,
        center,
        scale,
      );
      if (offset == null || !_isInView(offset, size)) continue;

      points.add(offset.dx);
      points.add(offset.dy);
      starsProcessed++;
    }

    if (points.isEmpty) return;

    // Single draw call for ALL stars as points
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(points),
      paint,
    );

    // Draw labels for only the very brightest stars (mag < 1.0) even in minimal
    // mode. The list is magnitude-sorted, so stop at the first star >= mag 1.0.
    // When the tier requests reduced labels, skip them entirely.
    if (qualityConfig.reduceLabels) return;
    for (final star in stars) {
      final mag = star.magnitude ?? 99.0;
      if (mag >= 1.0) break;
      if (star.name.isEmpty) continue;

      final offset = _projectObjectCulled(
        star,
        star.coordinates.raDegrees,
        star.coordinates.dec,
        center,
        scale,
      );
      if (offset == null || !_isInView(offset, size)) continue;

      final textStyle = TextStyle(
        color: Colors.white.withValues(alpha: 0.5),
        fontSize: 9,
        fontWeight: FontWeight.w500,
      );
      final textPainter = _TextCache.get(star.name, textStyle);
      textPainter.paint(canvas, offset + Offset(4, -textPainter.height / 2));
    }
  }

  /// Calculate surface brightness for a DSO.
  /// SB = mag + 2.5 * log10(area_arcsec2)
  double? _surfaceBrightness(DeepSkyObject dso) {
    final mag = dso.magnitude;
    final majorAxis = dso.sizeArcMin;
    if (mag == null || majorAxis == null || majorAxis <= 0) return null;
    final minorAxis = dso.minorAxisArcMin ?? majorAxis;
    final areaArcmin2 = math.pi * (majorAxis / 2) * (minorAxis / 2);
    final areaArcsec2 = areaArcmin2 * 3600;
    if (areaArcsec2 <= 0) return null;
    return mag + 2.5 * (math.log(areaArcsec2) / math.ln10);
  }

  /// Map surface brightness to opacity multiplier.
  double _surfaceBrightnessOpacity(double? sb) {
    if (sb == null) return 0.7;
    if (sb <= 22.0) return 1.0;
    if (sb >= 26.5) return 0.15;
    return 1.0 - (sb - 22.0) / (26.5 - 22.0) * 0.85;
  }

  void _drawDSOs(Canvas canvas, Size size, Offset center, double scale) {
    // Respect quality config limits. DSO list is pre-filtered by the dynamic
    // magnitude provider (fovFilteredDsosProvider), so we use the quality
    // config's limit as a safeguard rather than the static SkyRenderConfig default.
    var dsosDrawn = 0;
    final maxDsos = qualityConfig.maxDsosToRender;
    final magLimit = qualityConfig.dsoMagnitudeLimit;

    // Calculate pop-in animation values
    // Phase goes from 0 to 1; use easeOutCubic for smooth deceleration
    final popinPhase = dsoPopinAnimationPhase ?? 1.0;
    final easedPhase = Curves.easeOutCubic.transform(
      popinPhase.clamp(0.0, 1.0),
    );
    // Scale from 80% to 100%
    final popinScale = 0.8 + 0.2 * easedPhase;
    // Alpha from 0 to 1
    final popinAlpha = easedPhase;
    final animating =
        dsoPopinAnimationPhase != null && dsoPopinAnimationPhase! < 1.0;

    // GPU-batched DSO field via drawRawAtlas. Each DSO is one textured quad of
    // its baked white type-glyph (from the DSO glyph sheet), tinted by its type
    // color × surface-brightness alpha (atlas BlendMode.modulate) and rotated by
    // its position angle. The whole field draws in ONE drawRawAtlas call — no
    // per-DSO blur, saveLayer or gradient shader. Source-over composite so
    // overlapping glyphs don't blow out to white.
    final atlas = _atlas(_devicePixelRatio);
    final glyphSize = atlas.dsoGlyphSize;
    final glyphHalf = glyphSize / 2;

    var dsoCount = 0;

    // Every visible DSO is one atlas quad; tiny ones just scale the glyph down,
    // so no separate point-batch path is needed.
    for (final dso in dsos) {
      if (dsosDrawn >= maxDsos) break;
      final dsoMag = dso.magnitude ?? 99.0;
      // DSO list is magnitude-sorted (brightest first), so stop once past the
      // limit instead of scanning the remaining (all-fainter) entries.
      if (dsoMag > magLimit) break;

      // Cull BEFORE projecting and reuse the per-pose projected offset.
      final offset = _projectObjectCulled(
        dso,
        dso.coordinates.raDegrees,
        dso.coordinates.dec,
        center,
        scale,
      );
      if (offset == null || !_isInView(offset, size)) continue;

      // The catalogued extent, in canvas pixels. Zero when the catalogue does
      // not know the size, which keeps unmeasured objects on the marker path.
      final majorPx = (dso.sizeArcMin ?? 0) / 60 * scale;
      final minorPx = (dso.minorAxisArcMin ?? dso.sizeArcMin ?? 0) / 60 * scale;

      // Surface brightness opacity scaling
      final sb = _surfaceBrightness(dso);
      final sbOpacity = _surfaceBrightnessOpacity(sb);

      // Effective alpha (include pop-in if animating)
      final effectiveAlpha = animating ? popinAlpha * sbOpacity : sbOpacity;

      // Position angle rotation (galaxies/nebulae). Negative because the canvas
      // Y axis is flipped.
      final paRad = -((dso.positionAngle ?? 0) * SkyCanvasPainter._deg2rad);

      // Per-DSO tint: the glyph is white, so the atlas color is the DSO's body
      // color at the full effective alpha — the baked glyph already carries the
      // internal falloff. `_dsoTintColor` supplies the per-subtype nebula
      // colors (emission red, reflection blue, dark grey, planetary teal).
      final tint = _dsoTintColor(
        dso.type,
      ).withValues(alpha: effectiveAlpha.clamp(0.0, 1.0));

      // `displaySize` is the object's on-screen extent along its major axis;
      // labels and the observed/listed/sequenced markers hang off it.
      double displaySize;

      if (majorPx >= _extendedDsoMinPx) {
        final popin = animating ? popinScale : 1.0;
        _drawExtendedDso(
          canvas,
          offset,
          majorPx * popin,
          (minorPx <= 0 ? majorPx : minorPx) * popin,
          paRad,
          tint,
        );
        displaySize = majorPx * popin;
      } else {
        // Minimum 6px radius so every DSO is visible. Brighter = bigger.
        // Magnitude scaling: mag 0 -> 20px, mag 6 -> 14px, mag 10 -> 10px,
        // mag 14 -> 6px. A catalogue with no size falls back to 5 arcmin.
        final magSizeBonus = ((14.0 - dsoMag) / 14.0 * 14.0).clamp(0.0, 14.0);
        final markerPx = (dso.sizeArcMin ?? 5) / 60 * scale;
        displaySize = markerPx.clamp(6.0 + magSizeBonus, _extendedDsoMinPx);

        // Apply pop-in scale animation by shrinking the glyph: for a centered
        // sprite that is equivalent to scaling the canvas, and it stays inside
        // the single batched call.
        if (animating) {
          displaySize *= popinScale;
        }

        // Glyph scale: the glyph art fills the cell (with a small margin), so a
        // scale of displaySize/glyphSize makes the visible glyph ~displaySize px.
        final glyphScale = (displaySize / glyphSize).clamp(0.01, 4.0);

        SkyCanvasPainter._ensureAtlasScratch(dsoCount + 1);
        _writeDsoTransform(
          SkyCanvasPainter._atlasTransforms,
          SkyCanvasPainter._atlasRects,
          SkyCanvasPainter._atlasColors,
          dsoCount,
          glyphScale,
          math.cos(paRad),
          math.sin(paRad),
          glyphHalf,
          offset,
          atlas.dsoSrcRect(dso.type),
          tint.toARGB32(),
        );
        dsoCount++;
      }

      // Draw label. For bright DSOs (mag < 10), ALWAYS show the label so users
      // can find imaging targets. For fainter DSOs, show labels when zoomed in
      // enough that the object is > 10px on screen. Low tiers suppress DSO
      // labels entirely to save per-frame text work.
      if (config.showDSOLabels && !qualityConfig.reduceLabels) {
        // Same rule as the star labels: nothing behind the observer's ground
        // gets named as though it were up.
        final showLabel =
            (dsoMag < 10.0 || displaySize > 10.0) &&
            !_isBehindGround(dso.coordinates.raDegrees, dso.coordinates.dec);
        if (showLabel) {
          final labelText = _dsoLabelText(dso);
          final fontSize = _getLabelFontSize(dsoMag, 'dso');
          final fontWeight = _getLabelFontWeight(dsoMag);
          final labelAlpha = dsoMag < 10.0
              ? 0.85 *
                    effectiveAlpha // Bright DSOs get prominent labels
              : 0.6 * effectiveAlpha; // Fainter DSOs get subtler labels
          final textStyle = TextStyle(
            color: _dsoTypeColor(dso.type).withValues(alpha: labelAlpha),
            fontSize: fontSize,
            fontWeight: fontWeight,
          );
          final textPainter = _TextCache.get(labelText, textStyle);

          // Find non-overlapping placement
          final preferredPos =
              offset + Offset(displaySize / 2 + 3, -textPainter.height / 2);
          final labelPos = _labelManager.findPlacement(
            preferredPos,
            Size(textPainter.width, textPainter.height),
            size,
          );
          if (labelPos != null) {
            textPainter.paint(canvas, labelPos);
          }
        }
      }

      // Draw observed marker if this DSO has been logged
      if (observedObjectIds.isNotEmpty && _isDsoObserved(dso)) {
        _drawObservedMarker(canvas, offset, displaySize);
      }

      // Draw listed marker if this DSO is in an observing list
      if (listedObjectIds.isNotEmpty && _isDsoListed(dso)) {
        _drawListedMarker(canvas, offset, displaySize);
      }

      if (sequencedObjectIds.isNotEmpty && _isDsoSequenced(dso)) {
        _drawSequencedMarker(canvas, offset, displaySize);
      }

      dsosDrawn++;
    }

    // ONE drawRawAtlas for the whole DSO field, source-over so overlaps blend
    // rather than blow out.
    if (dsoCount > 0) {
      canvas.drawRawAtlas(
        atlas.dsoSheet,
        Float32List.sublistView(
          SkyCanvasPainter._atlasTransforms,
          0,
          dsoCount * 4,
        ),
        Float32List.sublistView(SkyCanvasPainter._atlasRects, 0, dsoCount * 4),
        Int32List.sublistView(SkyCanvasPainter._atlasColors, 0, dsoCount),
        BlendMode.modulate,
        null,
        SkyCanvasPainter._dsoAtlasPaint,
      );
    }
  }

  /// Draw an object large enough to have a shape at its catalogued extent: a
  /// soft body inside a thin boundary, on the major/minor axes, turned to its
  /// position angle.
  ///
  /// These leave the batched atlas because `drawRawAtlas` can only place a
  /// square sprite under a uniform scale — it has no way to express a 3:1
  /// galaxy. Only a handful of objects clear [_extendedDsoMinPx] in any one
  /// field, so the individual draws cost far less than the answer is worth.
  ///
  /// Position angle is measured from north, so the major axis runs along the
  /// canvas Y axis before [paRad] turns it; [paRad] carries the same sign
  /// convention as the glyph path's rotation.
  void _drawExtendedDso(
    Canvas canvas,
    Offset offset,
    double majorPx,
    double minorPx,
    double paRad,
    Color tint,
  ) {
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: minorPx,
      height: majorPx,
    );
    final alpha = tint.a;

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.rotate(paRad);
    canvas.drawOval(
      rect,
      Paint()..color = tint.withValues(alpha: (alpha * 0.16).clamp(0.0, 1.0)),
    );
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = tint.withValues(alpha: (alpha * 0.7).clamp(0.0, 1.0)),
    );
    canvas.restore();
  }

  /// Encode one DSO glyph into the atlas scratch buffers at slot [i].
  ///
  /// The RSTransform carries the position-angle rotation. With a uniform
  /// [scale] and rotation (cos,sin), the standard RSTransform components are:
  ///   scos = scale*cos, ssin = scale*sin
  /// and the translate folds in the anchor at the glyph center so the glyph is
  /// centered and rotated about [offset]:
  ///   tx = offset.dx - (scos*half - ssin*half)
  ///   ty = offset.dy - (ssin*half + scos*half)
  void _writeDsoTransform(
    Float32List transforms,
    Float32List rects,
    Int32List colors,
    int i,
    double scale,
    double cosR,
    double sinR,
    double half,
    Offset offset,
    Rect srcRect,
    int argb,
  ) {
    final scos = scale * cosR;
    final ssin = scale * sinR;
    final t = i * 4;
    transforms[t] = scos;
    transforms[t + 1] = ssin;
    transforms[t + 2] = offset.dx - (scos * half - ssin * half);
    transforms[t + 3] = offset.dy - (ssin * half + scos * half);

    rects[t] = srcRect.left;
    rects[t + 1] = srcRect.top;
    rects[t + 2] = srcRect.right;
    rects[t + 3] = srcRect.bottom;

    colors[i] = argb;
  }

  /// Build label text for a DSO. Uses common name for bright objects,
  /// otherwise catalog designation.
  /// Examples: "M31 - Andromeda Galaxy", "NGC 7000 - North America Nebula", "IC 1396"
  String _dsoLabelText(DeepSkyObject dso) {
    // Primary designation: prefer Messier, then NGC/IC, then raw name
    String designation;
    final messier = dso.messierNumber;
    if (messier != null) {
      designation = messier;
    } else {
      final ngcIc = dso.ngcIcDesignation;
      designation = ngcIc ?? dso.name;
    }

    // Append common name if available and different from designation
    if (dso.commonNames != null && dso.commonNames!.isNotEmpty) {
      final firstName = dso.commonNames!.split(',').first.trim();
      if (firstName.isNotEmpty && firstName != designation) {
        return '$designation - $firstName';
      }
    }

    return designation;
  }

  /// Whether [name] is a bare catalogue row id rather than a real designation
  /// (e.g. "HYG113360"), which the star loader substitutes when a row carries
  /// no proper, Bayer or Flamsteed name.
  static bool _isBareCatalogId(String name) =>
      _bareCatalogIdPattern.hasMatch(name);

  /// Check if a DSO matches any listed catalog ID or object name.
  bool _isDsoListed(DeepSkyObject dso) => _dsoMatchesIds(dso, listedObjectIds);

  /// Check if a DSO is a target of the currently loaded sequence.
  bool _isDsoSequenced(DeepSkyObject dso) =>
      _dsoMatchesIds(dso, sequencedObjectIds);

  /// Whether [dso] is named by [ids] under any of the designations a user (or
  /// a sequence target name) might have recorded it as.
  bool _dsoMatchesIds(DeepSkyObject dso, Set<String> ids) {
    if (ids.contains(dso.id)) return true;
    if (ids.contains(dso.name)) return true;
    if (dso.isMessier) {
      final messier = dso.messierNumber;
      if (messier != null && ids.contains(messier)) return true;
    }
    final ngcIc = dso.ngcIcDesignation;
    if (ngcIc != null && ids.contains(ngcIc)) return true;
    return false;
  }

  /// Draw a small cyan target ring at the bottom-right of a DSO, marking it as
  /// a target of tonight's sequence.
  ///
  /// Deliberately a different shape AND hue from the observed dot (green) and
  /// the observing-list bookmark (amber), and on the opposite corner, so an
  /// object that is all three still reads unambiguously.
  void _drawSequencedMarker(Canvas canvas, Offset dsoCenter, double dsoSize) {
    final markerSize = math.max(4.0, dsoSize * 0.3);
    final markerPos =
        dsoCenter +
        Offset(dsoSize / 2 + markerSize * 0.5, dsoSize / 2 + markerSize * 0.5);
    final radius = markerSize * 0.42;

    final ringPaint = Paint()
      ..color = const Color(0xFF4DD0E1).withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, markerSize * 0.16);
    final corePaint = Paint()
      ..color = const Color(0xFF4DD0E1).withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(markerPos, radius, ringPaint);
    canvas.drawCircle(markerPos, radius * 0.32, corePaint);
  }

  /// Draw a small amber bookmark marker at the top-right of a DSO.
  void _drawListedMarker(Canvas canvas, Offset dsoCenter, double dsoSize) {
    final markerSize = math.max(4.0, dsoSize * 0.3);
    final markerPos =
        dsoCenter +
        Offset(dsoSize / 2 + markerSize * 0.5, -dsoSize / 2 - markerSize * 0.5);

    final fillPaint = Paint()
      ..color = const Color(0xFFFFA726).withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    // Draw a small bookmark shape
    final bookmarkPath = Path()
      ..moveTo(markerPos.dx - markerSize * 0.4, markerPos.dy - markerSize * 0.5)
      ..lineTo(markerPos.dx + markerSize * 0.4, markerPos.dy - markerSize * 0.5)
      ..lineTo(markerPos.dx + markerSize * 0.4, markerPos.dy + markerSize * 0.4)
      ..lineTo(markerPos.dx, markerPos.dy + markerSize * 0.15)
      ..lineTo(markerPos.dx - markerSize * 0.4, markerPos.dy + markerSize * 0.4)
      ..close();

    canvas.drawPath(bookmarkPath, fillPaint);
    canvas.drawPath(bookmarkPath, borderPaint);
  }

  /// Check if a DSO matches any observed catalog ID or object name.
  bool _isDsoObserved(DeepSkyObject dso) {
    if (observedObjectIds.contains(dso.id)) return true;
    if (observedObjectIds.contains(dso.name)) return true;
    if (dso.isMessier) {
      final messier = dso.messierNumber;
      if (messier != null && observedObjectIds.contains(messier)) return true;
    }
    final ngcIc = dso.ngcIcDesignation;
    if (ngcIc != null && observedObjectIds.contains(ngcIc)) return true;
    return false;
  }

  /// Draw a small green "observed" indicator at the bottom-right of a DSO.
  void _drawObservedMarker(Canvas canvas, Offset dsoCenter, double dsoSize) {
    final markerRadius = math.max(3.0, dsoSize * 0.25);
    final markerPos =
        dsoCenter + Offset(dsoSize / 2 + markerRadius, dsoSize / 2);

    final fillPaint = Paint()
      ..color = const Color(0xFF4CAF50).withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawCircle(markerPos, markerRadius, fillPaint);
    canvas.drawCircle(markerPos, markerRadius, borderPaint);

    if (markerRadius >= 3.5) {
      final checkPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      final checkPath = Path()
        ..moveTo(markerPos.dx - markerRadius * 0.35, markerPos.dy)
        ..lineTo(
          markerPos.dx - markerRadius * 0.05,
          markerPos.dy + markerRadius * 0.3,
        )
        ..lineTo(
          markerPos.dx + markerRadius * 0.35,
          markerPos.dy - markerRadius * 0.3,
        );
      canvas.drawPath(checkPath, checkPaint);
    }
  }

  /// Body tint for the baked DSO glyph. Differs from [_dsoTypeColor] (used for
  /// labels) in carrying the per-subtype nebula colors: emission/HII red,
  /// reflection blue, dark-nebula blue-grey, planetary-nebula teal. Other types
  /// fall through to the label color.
  Color _dsoTintColor(DsoType type) {
    switch (type) {
      case DsoType.emissionNebula:
      case DsoType.hiiRegion:
        return const Color(0xFFFF1744); // Pink/red emission
      case DsoType.reflectionNebula:
        return const Color(0xFF448AFF); // Blue reflection
      case DsoType.darkNebula:
        return const Color(0xFF78909C); // Blue-grey dark nebula
      case DsoType.planetaryNebula:
        return const Color(0xFF26A69A); // Teal (old planetary ring color)
      default:
        return _dsoTypeColor(type);
    }
  }

  Color _dsoTypeColor(DsoType type) {
    switch (type) {
      case DsoType.galaxy:
        return const Color(0xFF64B5F6); // Blue
      case DsoType.nebula:
        return const Color(0xFFE91E63); // Pink
      case DsoType.planetaryNebula:
        return const Color(0xFF4CAF50); // Green
      case DsoType.openCluster:
        return const Color(0xFFFFEB3B); // Yellow
      case DsoType.globularCluster:
        return const Color(0xFFFF9800); // Orange
      case DsoType.supernova:
        return const Color(0xFFF44336); // Red
      default:
        return const Color(0xFFFFFFFF); // White
    }
  }
}

/// Matches a star name that is only a catalogue row id — "HYG113360",
/// "HIP 12345" and friends — as opposed to a real designation.
final RegExp _bareCatalogIdPattern = RegExp(
  r'^(HYG|HIP|HD|HR|TYC|GAIA)\s*[\d.\- ]+$',
  caseSensitive: false,
);
