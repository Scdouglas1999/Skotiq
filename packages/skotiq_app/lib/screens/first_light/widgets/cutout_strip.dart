import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Side-by-side template / science / residual cutout strip for one transient
/// candidate.
///
/// **Real pixels when available.** The difference pass writes three auto-stretched
/// postage-stamp PNGs (template / science / residual) per detection, addressable
/// from the persisted row alone (tile id + sky position). [firstLightCropProvider]
/// serves them — the local file on the host, the `/api/firstlight/<id>/crops/...`
/// endpoint on a companion tablet — so the strip shows the *actual* pixels around
/// the candidate, the first thing a discoverer eyeballs to reject a hot pixel or
/// satellite.
///
/// **Schematic fallback.** When a stamp is absent (an older detection logged
/// before crops were captured, or a scan that produced none) the panel falls back
/// to a faithful *schematic* drawn from the candidate's measured shape statistics
/// — the same numbers the cross-match and Narrator read — clearly captioned as a
/// schematic so it is never mistaken for raw pixels:
///
///   * **Template** — the deep stack at the source position. A
///     `pointBrightening` had flux here already; a `newSource` did not.
///   * **Science** — the fresh light frame: template plus the source as it
///     appeared, an elliptical Gaussian sized by [TransientDetectionRow.fwhm]
///     and elongated by [TransientDetectionRow.eccentricity].
///   * **Residual** — frame minus template, the difference the pipeline
///     detected. A `dipole` shows the tell-tale +/- lobe pair; everything else
///     a single signed blob whose sign follows [TransientDetectionRow.deltaMag].
class CutoutStrip extends ConsumerWidget {
  const CutoutStrip({super.key, required this.detection});

  final TransientDetectionRow detection;

  FirstLightCropQuery _query(String stage) => (
        detectionId: detection.id,
        tileId: detection.tileId,
        raDeg: detection.raDeg,
        decDeg: detection.decDeg,
        stage: stage,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final kind = TransientKind.fromWire(detection.kind);
    // A point brightening (and a known-star match) already had template flux;
    // a clean newcomer did not.
    final templateHasSource = kind == TransientKind.pointBrightening ||
        detection.catalogMatch != null;
    // Residual sign: deltaMag<0 means brighter (positive residual); fall back
    // to the signed residual flux when no magnitude was measurable.
    final brighter = detection.deltaMag != null
        ? detection.deltaMag! <= 0
        : detection.residualFlux >= 0;

    final templateBytes = ref.watch(
      firstLightCropProvider(_query('template')),
    );
    final scienceBytes = ref.watch(firstLightCropProvider(_query('science')));
    final residualBytes = ref.watch(firstLightCropProvider(_query('residual')));

    // The strip is "real pixels" only when every panel resolved to bytes; a
    // mixed state (some stamps missing) shows the schematic uniformly so the
    // three panels stay visually comparable and the caption stays honest.
    final allReal = templateBytes.valueOrNull != null &&
        scienceBytes.valueOrNull != null &&
        residualBytes.valueOrNull != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Three equal panels with two gaps; keep them square-ish but never let a
        // narrow phone column overflow.
        const gap = SkotiqTokens.spaceSm;
        final panel = ((constraints.maxWidth - gap * 2) / 3).clamp(48.0, 132.0);

        Widget panelFor({
          required String label,
          required _CutoutStage stage,
          required AsyncValue<Uint8List?> bytes,
          bool accent = false,
        }) {
          return _CutoutPanel(
            label: label,
            size: panel,
            colors: colors,
            accent: accent,
            pixels: allReal ? bytes.valueOrNull : null,
            painter: _CutoutPainter(
              colors: colors,
              kind: kind,
              fwhm: detection.fwhm,
              eccentricity: detection.eccentricity,
              snr: detection.snr,
              positionAngleDeg: detection.positionAngleDeg,
              stage: stage,
              templateHasSource: templateHasSource,
              brighter: brighter,
            ),
          );
        }

        final strip = Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            panelFor(
              label: 'Template',
              stage: _CutoutStage.template,
              bytes: templateBytes,
            ),
            const SizedBox(width: gap),
            panelFor(
              label: 'Science',
              stage: _CutoutStage.frame,
              bytes: scienceBytes,
            ),
            const SizedBox(width: gap),
            panelFor(
              label: 'Residual',
              stage: _CutoutStage.residual,
              bytes: residualBytes,
              accent: true,
            ),
          ],
        );

        // Caption: real pixels need none; the schematic must say so explicitly
        // (it appeared only in code comments before), with a Semantics label so a
        // screen reader is told these are measured-shape schematics, not pixels.
        if (allReal) return strip;
        return Semantics(
          label: 'Cutout schematic — drawn from the measured shape, '
              'not raw pixels',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              strip,
              const SizedBox(height: SkotiqTokens.spaceXs),
              Text(
                'Schematic — from measured shape, not raw pixels',
                textAlign: TextAlign.center,
                style: SkotiqTypography.labelQuiet.copyWith(
                  color: colors.textMuted,
                  fontSize: SkotiqTypography.fontSize10,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CutoutPanel extends StatelessWidget {
  const _CutoutPanel({
    required this.label,
    required this.size,
    required this.colors,
    required this.painter,
    this.pixels,
    this.accent = false,
  });

  final String label;
  final double size;
  final SkotiqColors colors;
  final CustomPainter painter;

  /// Real PNG stamp bytes; when non-null the panel renders the actual pixels and
  /// the [painter] schematic is unused.
  final Uint8List? pixels;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final pixels = this.pixels;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: SkotiqTokens.borderRadiusSm,
            border: Border.all(
              color:
                  accent ? colors.accent.withValues(alpha: 0.6) : colors.border,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: pixels != null
              ? Image.memory(
                  pixels,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.none,
                  errorBuilder: (context, error, stack) =>
                      CustomPaint(painter: painter, size: Size.square(size)),
                )
              : CustomPaint(painter: painter, size: Size.square(size)),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          label,
          style: SkotiqTypography.labelQuiet.copyWith(
            color: accent ? colors.accent : colors.textMuted,
            fontSize: SkotiqTypography.fontSize10,
          ),
        ),
      ],
    );
  }
}

enum _CutoutStage { template, frame, residual }

/// Paints one schematic cutout panel: a faint star-field background plus the
/// measured source ellipse, drawn differently per [stage].
class _CutoutPainter extends CustomPainter {
  _CutoutPainter({
    required this.colors,
    required this.kind,
    required this.fwhm,
    required this.eccentricity,
    required this.snr,
    required this.positionAngleDeg,
    required this.stage,
    required this.templateHasSource,
    required this.brighter,
  });

  final SkotiqColors colors;
  final TransientKind kind;
  final double fwhm;
  final double eccentricity;
  final double snr;
  final double positionAngleDeg;
  final _CutoutStage stage;
  final bool templateHasSource;
  final bool brighter;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Faint, deterministic field of background stars so the panels read as sky,
    // not blank tiles. Seeded by the panel size so it is stable across rebuilds.
    final rng = math.Random(((fwhm + eccentricity) * 1000).round() + 7);
    final star = Paint()..color = colors.textMuted.withValues(alpha: 0.35);
    for (var i = 0; i < 9; i++) {
      final p = Offset(
        rng.nextDouble() * size.width,
        rng.nextDouble() * size.height,
      );
      // Skip stars too near the centre so they don't fight the source.
      if ((p - center).distance < size.width * 0.18) continue;
      canvas.drawCircle(p, 0.6 + rng.nextDouble() * 0.8, star);
    }

    // Source ellipse geometry from the measured PSF. FWHM is in pixels on the
    // tile grid; map a typical few-pixel PSF onto ~22% of the panel, clamped so
    // an extreme value can't fill or vanish.
    final base = size.width * (0.10 + 0.012 * fwhm).clamp(0.10, 0.30);
    final ecc = eccentricity.clamp(0.0, 0.95);
    final semiMajor = base / math.sqrt(1 - ecc * ecc).clamp(0.4, 1.0);
    final semiMinor = base * math.sqrt(1 - ecc * ecc);
    // Orient the ellipse along the residual's measured major axis (the native
    // second-moment position angle). The tile +y axis points down in canvas
    // space, but a position angle is direction-less (mod 180°) so the sign does
    // not matter for an ellipse. A round source's angle is immaterial.
    final angle = positionAngleDeg * math.pi / 180.0;
    // Brightness intensity ramps with SNR but stays visible at the floor.
    final intensity = (0.35 + snr / 30.0).clamp(0.35, 1.0);

    switch (stage) {
      case _CutoutStage.template:
        if (templateHasSource) {
          _drawBlob(
            canvas,
            center,
            semiMajor,
            semiMinor,
            angle,
            colors.textSecondary,
            // Template flux for a known source is steady, not the full bright
            // intensity — the *change* is what shows up in the residual.
            0.55,
          );
        }
        // newSource → empty template (nothing drawn): the headline absence.
        break;
      case _CutoutStage.frame:
        // Frame = template flux (if any) plus the source as imaged this night.
        if (templateHasSource) {
          _drawBlob(
            canvas,
            center,
            semiMajor,
            semiMinor,
            angle,
            colors.textSecondary,
            0.55,
          );
        }
        _drawBlob(
          canvas,
          center,
          semiMajor,
          semiMinor,
          angle,
          colors.textPrimary,
          intensity,
        );
        break;
      case _CutoutStage.residual:
        final pos = brighter ? colors.accent : colors.info;
        if (kind == TransientKind.dipole) {
          // The dipole signature: a positive lobe beside a negative one.
          final off = Offset(semiMajor * 0.8, 0);
          _drawBlob(
            canvas,
            center - off,
            semiMinor,
            semiMinor,
            0,
            colors.accent,
            intensity,
          );
          _drawBlob(
            canvas,
            center + off,
            semiMinor,
            semiMinor,
            0,
            colors.error,
            intensity,
          );
        } else {
          _drawBlob(
            canvas,
            center,
            semiMajor,
            semiMinor,
            angle,
            pos,
            intensity,
          );
        }
        break;
    }
  }

  /// Draw a soft elliptical Gaussian-like blob via a radial gradient.
  void _drawBlob(
    Canvas canvas,
    Offset center,
    double semiMajor,
    double semiMinor,
    double angle,
    Color color,
    double intensity,
  ) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    // Map the unit circle to the ellipse so the radial gradient becomes
    // elliptical.
    canvas.scale(semiMajor, semiMinor);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: intensity.clamp(0.0, 1.0)),
          color.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1.0));
    canvas.drawCircle(Offset.zero, 1.0, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CutoutPainter old) =>
      old.kind != kind ||
      old.fwhm != fwhm ||
      old.eccentricity != eccentricity ||
      old.snr != snr ||
      old.positionAngleDeg != positionAngleDeg ||
      old.stage != stage ||
      old.templateHasSource != templateHasSource ||
      old.brighter != brighter ||
      old.colors != colors;
}
