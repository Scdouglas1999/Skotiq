import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../analytics_screen.dart'
    show dbSessionImagesProvider, standaloneImagesProvider;
import 'campaign_rollup_dialog.dart';

/// Compact science summary shown on the Session tab and Imaging HUD.
///
/// Surfaces the four numbers that matter at a glance — solve rate, latest
/// zero point, transparency, and uniformity CV — plus a "go to Science"
/// affordance. Designed to fit comfortably alongside the classic Session
/// metrics (HFR, RMS, integration) without forcing the user to switch tabs
/// to see whether the night is producing usable science data.
class ScienceSessionSummary extends ConsumerWidget {
  /// Callback when the user taps "Open Science tab" / the card surface.
  /// Optional — when null, the card is purely informational.
  final VoidCallback? onOpenSciencePressed;

  const ScienceSessionSummary({super.key, this.onOpenSciencePressed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final activeSessionId = ref.watch(sessionStateProvider).dbSessionId;

    // Pick session vs. sessionless providers so the strip works for quick
    // captures too. Metrics may render from whichever sources are available,
    // but loading/failure remains visible so an unavailable stream never
    // masquerades as a scientifically meaningful "—".
    final FramePhotometricCalibrationRow? latestCal;
    final TransparencySampleRow? latestTransparency;
    final ScienceFrameQualityMetricsRow? latestFrameQuality;
    final List<FramePhotometricCalibrationRow> calibrations;
    final List<DbCapturedImage> images;
    final sources = <AsyncValue<Object?>>[];

    if (activeSessionId != null) {
      final calibrationsAsync =
          ref.watch(sessionFrameCalibrationsProvider(activeSessionId));
      final transparencyAsync =
          ref.watch(sessionTransparencySamplesProvider(activeSessionId));
      final frameMetricsAsync =
          ref.watch(sessionFrameQualityMetricsProvider(activeSessionId));
      final imagesAsync = ref.watch(dbSessionImagesProvider(activeSessionId));
      sources.addAll([
        calibrationsAsync,
        transparencyAsync,
        frameMetricsAsync,
        imagesAsync,
      ]);
      calibrations = calibrationsAsync.valueOrNull ?? const [];
      final transparencyRows = transparencyAsync.valueOrNull ?? const [];
      final frameMetrics = frameMetricsAsync.valueOrNull ?? const [];
      latestCal = calibrations.isEmpty ? null : calibrations.last;
      latestTransparency =
          transparencyRows.isEmpty ? null : transparencyRows.last;
      latestFrameQuality = frameMetrics.isEmpty ? null : frameMetrics.last;
      images = imagesAsync.valueOrNull ?? const [];
    } else {
      final calibrationsAsync = ref.watch(sessionlessCalibrationsProvider);
      final transparencyAsync =
          ref.watch(sessionlessTransparencySamplesProvider);
      final frameMetricsAsync =
          ref.watch(sessionlessFrameQualityMetricsProvider);
      final imagesAsync = ref.watch(standaloneImagesProvider);
      sources.addAll([
        calibrationsAsync,
        transparencyAsync,
        frameMetricsAsync,
        imagesAsync,
      ]);
      calibrations = calibrationsAsync.valueOrNull ?? const [];
      final transparencyRows = transparencyAsync.valueOrNull ?? const [];
      final frameMetrics = frameMetricsAsync.valueOrNull ?? const [];
      latestCal = calibrations.isEmpty ? null : calibrations.last;
      latestTransparency =
          transparencyRows.isEmpty ? null : transparencyRows.last;
      latestFrameQuality = frameMetrics.isEmpty ? null : frameMetrics.last;
      images = imagesAsync.valueOrNull ?? const [];
    }

    final solveStats = _solveStats(images);

    // Resolve the target the active session is bound to so we can offer a
    // "see all sessions for this target" link. Quick-capture sessions
    // typically have no target — we keep the card unchanged in that case.
    final targetAsync = activeSessionId == null
        ? null
        : ref.watch(scienceSessionTargetIdProvider(activeSessionId));
    if (targetAsync != null) sources.add(targetAsync);
    final activeTargetId = targetAsync?.valueOrNull;
    final errors = sources
        .where((source) => source.hasError && source.error != null)
        .map((source) => source.error!)
        .toList(growable: false);
    final isLoading = sources.any(
      (source) => source.isLoading || (!source.hasValue && !source.hasError),
    );

    return Semantics(
      button: true,
      enabled: true,
      child: SkotiqCard(
        onTap: onOpenSciencePressed,
        padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.flaskConical, size: 15, color: colors.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Tonight\'s science',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textPrimary, fontWeight: FontWeight.w600),
                  ),
                ),
                const Spacer(),
                if (activeTargetId != null)
                  TextButton.icon(
                    onPressed: () => CampaignRollupDialog.show(
                      context,
                      activeTargetId,
                    ),
                    icon: Icon(
                      LucideIcons.history,
                      size: 12,
                      color: colors.textSecondary,
                    ),
                    label: Text(
                      'Target campaign',
                      style: SkotiqTypography.caption.copyWith(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                if (onOpenSciencePressed != null)
                  Text(
                    'Open Science tab →',
                    style: SkotiqTypography.caption.copyWith(
                        color: colors.primary, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
            if (errors.isNotEmpty) ...[
              const SizedBox(height: 8),
              _SummaryLoadNotice(
                colors: colors,
                error: errors.first,
                additionalErrorCount: errors.length - 1,
                onRetry: () => _retrySources(ref, activeSessionId),
              ),
            ] else if (isLoading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                minHeight: 2,
                color: colors.primary,
                backgroundColor: colors.border,
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MetricTile(
                    colors: colors,
                    icon: LucideIcons.crosshair,
                    label: 'Plate solves',
                    value: solveStats.label,
                    tone: solveStats.tone(colors),
                    tooltip:
                        'Fraction of frames this session that produced a WCS solution. '
                        'Most science products require a plate solve.',
                  ),
                ),
                _MetricDivider(colors: colors),
                Expanded(
                  child: _MetricTile(
                    colors: colors,
                    icon: LucideIcons.gauge,
                    label: 'Zero point',
                    value: latestCal?.zeroPoint == null
                        ? kReadoutUnknown
                        : latestCal!.zeroPoint!.toStringAsFixed(2),
                    sub: latestCal == null
                        ? null
                        : '${latestCal.matchedStarCount} stars',
                    tone: latestCal == null || !latestCal.isCalibrated
                        ? colors.textMuted
                        : colors.success,
                    tooltip:
                        'Latest photometric zero-point. Higher numbers mean fainter detection limits for the same exposure.',
                  ),
                ),
                _MetricDivider(colors: colors),
                Expanded(
                  child: _MetricTile(
                    colors: colors,
                    icon: LucideIcons.cloud,
                    label: 'Transparency',
                    value: latestTransparency == null
                        ? kReadoutUnknown
                        : '${latestTransparency.transparencyPercent.toStringAsFixed(0)}%',
                    sub: latestTransparency?.qualityBucket,
                    tone: _toneForTransparency(latestTransparency, colors),
                    tooltip:
                        'Most recent atmospheric transparency estimate, based on calibrated frame brightness vs catalog.',
                  ),
                ),
                _MetricDivider(colors: colors),
                Expanded(
                  child: _MetricTile(
                    colors: colors,
                    icon: LucideIcons.layoutGrid,
                    label: 'Uniformity CV',
                    value: latestFrameQuality == null
                        ? kReadoutUnknown
                        : latestFrameQuality.uniformityCv.toStringAsFixed(3),
                    sub: latestFrameQuality == null
                        ? null
                        : 'SNR ${latestFrameQuality.snr.toStringAsFixed(1)}',
                    tone: latestFrameQuality == null
                        ? colors.textMuted
                        : latestFrameQuality.uniformityCv > 0.28
                            ? colors.warning
                            : colors.success,
                    tooltip:
                        'Coefficient of variation of background brightness across the frame. Lower is flatter — values above 0.28 suggest gradients.',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _toneForTransparency(
      TransparencySampleRow? t, SkotiqColors colors) {
    if (t == null) return colors.textMuted;
    if (t.transparencyPercent >= 90) return colors.success;
    if (t.transparencyPercent >= 75) return colors.info;
    return colors.warning;
  }

  static _SolveStats _solveStats(List<DbCapturedImage> images) {
    final lights = images
        .where((image) => image.frameType.toLowerCase() == 'light')
        .toList(growable: false);
    if (lights.isEmpty) {
      return const _SolveStats(rate: null, total: 0, solved: 0);
    }
    final solved = lights.where((image) => image.isPlateSolved).length;
    return _SolveStats(
      rate: lights.isEmpty ? null : solved / lights.length,
      total: lights.length,
      solved: solved,
    );
  }

  void _retrySources(WidgetRef ref, int? sessionId) {
    if (sessionId == null) {
      ref.invalidate(sessionlessCalibrationsProvider);
      ref.invalidate(sessionlessTransparencySamplesProvider);
      ref.invalidate(sessionlessFrameQualityMetricsProvider);
      ref.invalidate(standaloneImagesProvider);
      return;
    }
    ref.invalidate(sessionFrameCalibrationsProvider(sessionId));
    ref.invalidate(sessionTransparencySamplesProvider(sessionId));
    ref.invalidate(sessionFrameQualityMetricsProvider(sessionId));
    ref.invalidate(dbSessionImagesProvider(sessionId));
    ref.invalidate(scienceSessionTargetIdProvider(sessionId));
  }
}

class _SummaryLoadNotice extends StatelessWidget {
  const _SummaryLoadNotice({
    required this.colors,
    required this.error,
    required this.additionalErrorCount,
    required this.onRetry,
  });

  final SkotiqColors colors;
  final Object error;
  final int additionalErrorCount;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.error.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Science summary incomplete: $error'
              '${additionalErrorCount > 0 ? ' (+$additionalErrorCount more)' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _SolveStats {
  final double? rate;
  final int solved;
  final int total;

  const _SolveStats({
    required this.rate,
    required this.solved,
    required this.total,
  });

  String get label {
    if (rate == null) return kReadoutUnknown;
    return '$solved / $total';
  }

  Color tone(SkotiqColors c) {
    final r = rate;
    if (r == null) return c.textMuted;
    if (r >= 0.9) return c.success;
    if (r >= 0.5) return c.info;
    return c.warning;
  }
}

/// Returns the `targetId` for a session, or `null` if the session has no
/// associated target (quick captures, ad-hoc imaging, etc.). Cached so a
/// rebuild from any other state change doesn't refetch the session row.
final scienceSessionTargetIdProvider =
    FutureProvider.family<int?, int>((ref, sessionId) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    final session = await backend.getSessionById(sessionId);
    final targetId = session?['targetId'] ?? session?['target_id'];
    return (targetId as num?)?.toInt();
  }
  final dao = ref.watch(sessionsDaoProvider);
  final session = await dao.getSessionById(sessionId);
  return session?.targetId;
});

class _MetricTile extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final String value;
  final String? sub;
  final Color tone;
  final String tooltip;

  const _MetricTile({
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
    required this.tooltip,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: colors.textMuted),
              const SizedBox(width: 6),
              Text(
                label.toUpperCase(),
                style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: SkotiqTypography.readoutMd
                .copyWith(color: tone, fontWeight: FontWeight.w600),
          ),
          if (sub != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                sub!,
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetricDivider extends StatelessWidget {
  final SkotiqColors colors;
  const _MetricDivider({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: colors.border,
    );
  }
}
