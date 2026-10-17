import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../glass_card.dart';

/// Neutral lunar grey, the colour of the lit limb in every theme but red night.
@visibleForTesting
const Color moonLitGrey = Color(0xFFD6DCE2);

/// Moon briefing card: a painted phase disc plus illumination, phase name, and
/// moonrise/moonset times. Degrades to "--" rows when rise/set are undefined
/// (circumpolar moon, or no location).
///
/// Phase and illumination are the same everywhere on Earth, so they stay
/// truthful without a site; only rise/set depend on where the observer is.
class MoonCard extends ConsumerWidget {
  final SkotiqColors colors;

  const MoonCard({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final moon = ref.watch(moonInfoProvider);
    final waxing = _isWaxing(moon.phaseName);
    // The moon rises and sets everywhere, so [moonInfoProvider] returns real
    // times whether or not a site is on record. Ask the observer whether it has
    // one — comparing the coordinates against a sentinel reads a NULL latitude
    // as "not zero, so a site exists" and puts a stranger's moonrise on the
    // dashboard.
    final observer = ref.watch(observerLocationProvider);
    final hasSite = observer.hasSite;
    // Same clock as the status bar and the header chip: a dashboard that shows
    // "now" in the site's zone and moonrise in the host's is worse than one
    // that is uniformly host-local.
    final clock = ref.watch(clockProvider);

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.moon,
            title: context.l10n.text('dbMoon'),
            accent: colors.info,
          ),
          const SizedBox(height: DashboardCardStyle.headerGap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CustomPaint(
                size: const Size(72, 72),
                painter: MoonPainter(
                  illumination: moon.illumination,
                  waxing: waxing,
                  // The lit limb is a ~50 px SOLID fill, so a fixed off-white
                  // made it the brightest object anywhere on the dashboard —
                  // in red night mode, a bluish-white flare on the screen the
                  // app opens on, which is the one thing that mode exists to
                  // prevent. Routed through the same theme mapper the charts
                  // use so red night re-expresses it on the red axis (and
                  // every other theme keeps the moon-grey unchanged).
                  litColor: SkotiqChartColors.forTheme(
                    moonLitGrey,
                    colors,
                  ),
                  darkColor: colors.surfaceAlt,
                  borderColor: colors.border,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceLg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      // The phase name arrives from the astronomy layer as an
                      // English literal ("Waning Gibbous"); key off it so the
                      // card is not half-translated.
                      context.l10n.text('dbMoonPhase${moon.phaseName}'),
                      style: SkotiqTypography.body.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.text(
                        'dbIlluminated',
                        params: {
                          'value': moon.illumination.toStringAsFixed(0),
                        },
                      ),
                      style: SkotiqTypography.withTabular(
                        SkotiqTypography.bodySm.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _TimeRow(
            colors: colors,
            icon: LucideIcons.arrowUp,
            label: context.l10n.text('dbMoonrise'),
            value: _clock(hasSite ? moon.moonrise : null, clock),
          ),
          const SizedBox(height: 6),
          _TimeRow(
            colors: colors,
            icon: LucideIcons.arrowDown,
            label: context.l10n.text('dbMoonset'),
            value: _clock(hasSite ? moon.moonset : null, clock),
          ),
        ],
      ),
    );
  }

  /// Derive waxing/waning from the phase name (MoonTimes exposes no flag). Any
  /// "waning"/"last"/"third" phrase → waning; otherwise default to waxing so a
  /// new/full disc still renders sensibly.
  static bool _isWaxing(String phaseName) {
    final p = phaseName.toLowerCase();
    if (p.contains('waning') || p.contains('last') || p.contains('third')) {
      return false;
    }
    return true;
  }

  /// HH:MM on the operator's chosen clock.
  static String _clock(DateTime? t, Clock clock) {
    if (t == null) return kReadoutUnknown;
    final shown = clock.fromUtc(t.toUtc());
    return '${shown.hour.toString().padLeft(2, '0')}:'
        '${shown.minute.toString().padLeft(2, '0')}';
  }
}

class _TimeRow extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final String value;

  const _TimeRow({
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: colors.textMuted),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Text(
            label,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
        Text(
          value,
          style: SkotiqTypography.withTabular(
            SkotiqTypography.labelStrongSm.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Paints a moon disc lit from one side. The terminator is an ellipse whose
/// width tracks the illuminated fraction; `waxing` flips which limb is lit.
///
/// Public because two surfaces draw the same disc — Tonight's moon panel and
/// this card — and a test reads the colours it is handed: the lit limb is the
/// largest solid fill on the page and was once a fixed off-white in every
/// theme.
class MoonPainter extends CustomPainter {
  final double illumination; // 0..100
  final bool waxing;
  final Color litColor;
  final Color darkColor;
  final Color borderColor;

  MoonPainter({
    required this.illumination,
    required this.waxing,
    required this.litColor,
    required this.darkColor,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final frac = (illumination / 100).clamp(0.0, 1.0);

    // Start fully dark.
    canvas.drawCircle(center, r, Paint()..color = darkColor);

    final lit = Paint()..color = litColor;
    canvas.save();
    canvas
        .clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));

    if (frac >= 0.999) {
      canvas.drawCircle(center, r, lit);
    } else if (frac > 0.001) {
      // Half the disc (the lit limb) is a solid semicircle; the terminator is
      // an ellipse interpolating between the two limbs. cos(pi*frac) gives the
      // signed terminator offset: <0.5 illum → terminator on the lit side
      // (crescent), >0.5 → on the dark side (gibbous).
      final litRight = waxing; // waxing moon is lit on the right limb
      final rect = Rect.fromCircle(center: center, radius: r);

      // Solid half on the lit side.
      final half = Path()
        ..addArc(
          rect,
          litRight ? -1.5708 : 1.5708, // start at top, sweep toward lit side
          3.14159,
        )
        ..close();
      canvas.drawPath(half, lit);

      // Terminator ellipse: positive offset adds to the lit half (gibbous),
      // negative carves into it (crescent).
      final term = (frac - 0.5) * 2; // -1..1
      final ellipseW = (r * term).abs();
      final ellipseRect = Rect.fromCenter(
        center: center,
        width: ellipseW * 2,
        height: r * 2,
      );
      final gibbous = frac > 0.5;
      canvas.drawOval(
        ellipseRect,
        Paint()..color = gibbous ? lit.color : darkColor,
      );
    }
    canvas.restore();

    // Rim.
    canvas.drawCircle(
      center,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = borderColor,
    );
  }

  @override
  bool shouldRepaint(MoonPainter old) =>
      old.illumination != illumination ||
      old.waxing != waxing ||
      old.litColor != litColor ||
      old.darkColor != darkColor;
}
