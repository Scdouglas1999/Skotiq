import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Inline card on the Analytics Science tab that reports the plate-solve
/// success rate for the current session and offers a one-click jump to the
/// plate-solver settings page when the rate is bad.
///
/// This addresses P0.3: "plate solve is a hard prerequisite for most science
/// products, but the existing empty state never tells the user that *this*
/// session is failing — only that data is missing." Surfacing the rate plus
/// a path-forward closes that loop.
class ScienceSolveRateCard extends ConsumerWidget {
  final SkotiqColors colors;

  /// All light frames captured this session (or all standalone lights when
  /// no session is active).
  final List<DbCapturedImage> lightFrames;

  const ScienceSolveRateCard({
    super.key,
    required this.colors,
    required this.lightFrames,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = lightFrames.length;
    final solved = lightFrames.where((image) => image.isPlateSolved).length;
    final rate = total == 0 ? 0.0 : solved / total;
    final pct = (rate * 100).round();

    final _Tier tier = _classify(total: total, rate: rate);
    // Whether a solver is actually on this machine. Without it the zero-solve
    // message blamed reachability while ASTAP was being launched per frame and
    // exiting 1 — the failure was pointing/scale, not installation.
    final detection = ref.watch(plateSolverDetectionProvider).valueOrNull;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.crosshair, size: 15, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                'Plate solve health',
                style: SkotiqTypography.bodyStrong
                    .copyWith(color: colors.textPrimary),
              ),
              const Spacer(),
              _StatusPill(tier: tier, colors: colors),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                total == 0 ? kReadoutUnknown : '$pct%',
                style: SkotiqTypography.readoutLg.copyWith(
                    color: tier.color(colors), fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  total == 0
                      ? 'no light frames yet'
                      : '$solved of $total solved',
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : rate.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: colors.well,
              valueColor: AlwaysStoppedAnimation<Color>(tier.color(colors)),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            tier.message(total: total, detection: detection),
            style: SkotiqTypography.caption
                .copyWith(color: colors.textSecondary, height: 1.4),
          ),
          if (tier.showConfigureCta) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SkotiqButton(
                onPressed: () => context.push('/settings/plate-solving'),
                label: 'Configure plate solver',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static _Tier _classify({required int total, required double rate}) {
    if (total == 0) return _Tier.warmup;
    if (total < 3) return _Tier.warmup;
    if (rate >= 0.9) return _Tier.excellent;
    if (rate >= 0.6) return _Tier.acceptable;
    if (rate > 0) return _Tier.struggling;
    return _Tier.broken;
  }
}

enum _Tier {
  warmup,
  excellent,
  acceptable,
  struggling,
  broken;

  bool get showConfigureCta => this == _Tier.struggling || this == _Tier.broken;

  String get label {
    switch (this) {
      case _Tier.warmup:
        return 'Warming up';
      case _Tier.excellent:
        return 'Excellent';
      case _Tier.acceptable:
        return 'Acceptable';
      case _Tier.struggling:
        return 'Struggling';
      case _Tier.broken:
        return 'No solves yet';
    }
  }

  Color color(SkotiqColors c) {
    switch (this) {
      case _Tier.warmup:
        return c.textSecondary;
      case _Tier.excellent:
        return c.success;
      case _Tier.acceptable:
        return c.info;
      case _Tier.struggling:
        return c.warning;
      case _Tier.broken:
        return c.error;
    }
  }

  /// [detection] is the filesystem probe's answer, or null while it is still
  /// running. A zero solve rate has two very different causes — no solver, or a
  /// solver that runs and fails — and the card must not guess between them.
  String message({required int total, PlateSolverDetection? detection}) {
    switch (this) {
      case _Tier.warmup:
        return total == 0
            ? 'Solve health appears once light frames start arriving.'
            : 'A few more frames will produce a stable solve rate.';
      case _Tier.excellent:
        return 'Most frames are solving. Photometry, PSF maps, and residuals all benefit.';
      case _Tier.acceptable:
        return 'Most frames solve. Failures are usually due to clouds or transient guiding excursions.';
      case _Tier.struggling:
        return 'Many frames are failing to solve. Verify focal length, pixel scale, and that the catalog index is reachable.';
      case _Tier.broken:
        if (detection == null) {
          // Detection has not answered (or could not). Say what is true either
          // way rather than guessing at the cause.
          return 'No frames have solved this session, so most science products '
              'will stay empty. Open Plate Solving settings to see whether a '
              'solver is configured and what it reported.';
        }
        if (!detection.hasAnySolver) {
          return 'No plate solver is installed, so nothing has solved this '
              'session and most science products will stay empty. Install '
              'ASTAP (with a star catalog) or astrometry.net, then point '
              'Skotiq at it.';
        }
        return 'No frames have solved this session, and a solver '
            '${detection.astapReady ? '(ASTAP' : '(astrometry.net'}'
            '${detection.catalogName == null ? '' : ', catalog ${detection.catalogName}'}) '
            'is installed — so it is running and failing, not missing. Check '
            'focal length and pixel scale first, then whether the catalog '
            'covers this field.';
    }
  }
}

class _StatusPill extends StatelessWidget {
  final _Tier tier;
  final SkotiqColors colors;

  const _StatusPill({required this.tier, required this.colors});

  @override
  Widget build(BuildContext context) {
    final c = tier.color(colors);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: SkotiqDecorations.chip(colors, tone: c),
      child: Text(
        tier.label,
        style: SkotiqTypography.caption
            .copyWith(color: c, fontWeight: FontWeight.w600),
      ),
    );
  }
}
