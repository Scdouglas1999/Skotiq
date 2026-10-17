import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Backend seam for the adaptive-conditions panel.
///
/// All concrete Skotiq backends now implement [AdaptiveSwapBackend].
/// This provider stays narrow so tests can override only the adaptive-swap
/// surface instead of mocking the full device backend.
final adaptiveSwapBackendProvider = Provider<AdaptiveSwapBackend>((ref) {
  return ref.watch(sequencerBackendProvider);
});

/// Latest adaptive-swap snapshot from the sequencer executor.
///
/// Tied to the shared 30-second dashboard ticker so the panel refreshes with
/// the same cadence as the sky stats without starting its own timer.
final adaptiveSwapSnapshotProvider =
    FutureProvider.autoDispose<AdaptiveSwapSnapshot?>((ref) async {
  ref.watch(tickerProvider(TickerCadence.thirtySeconds));
  final backend = ref.watch(adaptiveSwapBackendProvider);
  return backend.sequencerGetAdaptiveSwapSnapshot();
});

class RunDashboardAdaptiveConditionsPanel extends ConsumerWidget {
  const RunDashboardAdaptiveConditionsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final snapshotAsync = ref.watch(adaptiveSwapSnapshotProvider);

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: snapshotAsync.when(
        loading: () => _Shell(
          colors: colors,
          statusLabel: 'LOADING',
          statusColor: colors.textMuted,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        ),
        error: (error, _) => _Shell(
          colors: colors,
          statusLabel: 'ERROR',
          statusColor: colors.error,
          // Operator-friendly message: SkotiqError already carries a
          // userMessage; anything else gets a generic line with the raw text
          // tucked behind a tooltip so the dashboard never dumps a stack-y
          // toString() at the user.
          child: Tooltip(
            message: error.toString(),
            child: Text(
              error is SkotiqError
                  ? error.userMessage
                  : 'Adaptive conditions unavailable',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.error),
            ),
          ),
        ),
        data: (snapshot) => _SnapshotBody(colors: colors, snapshot: snapshot),
      ),
    );
  }
}

class _SnapshotBody extends StatelessWidget {
  final SkotiqColors colors;
  final AdaptiveSwapSnapshot? snapshot;

  const _SnapshotBody({required this.colors, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final score = snapshot?.score;
    final state = snapshot?.state;
    final now = DateTime.now().toUtc();
    final status = _status(state?.lastDecisionKind, score, colors);
    final cooldown = state?.cooldownRemainingSecs(now);

    return _Shell(
      colors: colors,
      statusLabel: status.label,
      statusColor: status.color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ScoreLine(colors: colors, score: score),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _InfoRow(
            colors: colors,
            label: 'Tier / floor',
            value: _tierFloor(state),
            highlight: _scorePassesFloor(score, state) ? colors.success : null,
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          _InfoRow(
            colors: colors,
            label: 'Adaptive swap',
            value: _decisionLabel(state),
            highlight: status.color,
          ),
          if ((state?.lastDecisionReason ?? '').isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              state!.lastDecisionReason!,
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceXs),
          _InfoRow(
            colors: colors,
            label: 'Last swap',
            value: _lastSwap(state),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          _InfoRow(
            colors: colors,
            label: 'Hysteresis',
            // The cooldown is computed against the shared 30s dashboard
            // ticker, so the countdown advances in 30s steps rather than
            // smoothly — label it so the lag is explicit instead of looking
            // like a stalled clock.
            value: cooldown == null
                ? '${_formatSecs(state?.configuredHysteresisSecs)} window'
                : '~${_formatSecs(cooldown)} remaining (30s cadence)',
            highlight: cooldown == null ? colors.textSecondary : colors.warning,
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          _InfoRow(
            colors: colors,
            label: 'Telemetry age',
            value: _telemetryAge(score, now),
            highlight: _telemetryAgeColor(score, now, colors),
          ),
        ],
      ),
    );
  }

  bool _scorePassesFloor(
    ConditionsScore? score,
    AdaptiveSwapRuntimeState? state,
  ) {
    final floor = state?.configuredThreshold;
    if (score == null || floor == null) return false;
    return score.score >= floor;
  }

  ({String label, Color color}) _status(
    String? decisionKind,
    ConditionsScore? score,
    SkotiqColors colors,
  ) {
    final kind = decisionKind?.toLowerCase();
    if (kind != null && kind.contains('swap')) {
      return (label: 'SWAPPED', color: colors.warning);
    }
    if (kind != null && (kind.contains('hold') || kind.contains('keep'))) {
      return (label: 'HOLDING', color: colors.success);
    }
    if (score == null) return (label: 'NO DATA', color: colors.textMuted);
    if (score.score >= 70) return (label: 'GOOD', color: colors.success);
    if (score.score >= 50) return (label: 'DEGRADED', color: colors.warning);
    return (label: 'POOR', color: colors.error);
  }

  String _tierFloor(AdaptiveSwapRuntimeState? state) {
    final tier = state?.currentTier;
    final floor = state?.configuredThreshold;
    if ((tier == null || tier.isEmpty) && floor == null) return 'Not set';
    final tierLabel = tier == null || tier.isEmpty ? 'Auto' : _title(tier);
    if (floor == null) return tierLabel;
    return '$tierLabel >= ${floor.toStringAsFixed(0)}';
  }

  String _decisionLabel(AdaptiveSwapRuntimeState? state) {
    final kind = state?.lastDecisionKind;
    if (kind == null || kind.isEmpty) return 'No decision yet';
    return _title(kind.replaceAll('_', ' '));
  }

  String _lastSwap(AdaptiveSwapRuntimeState? state) {
    final last = state?.lastSwapAt;
    if (last == null) return 'None this run';
    final from = state?.lastSwapFromTargetId;
    final to = state?.lastSwapToTargetId;
    final prefix = '${_formatRelative(last)} ago';
    if ((from ?? '').isEmpty || (to ?? '').isEmpty) return prefix;
    return '$prefix ($from -> $to)';
  }

  String _telemetryAge(ConditionsScore? score, DateTime now) {
    if (score == null) return 'No score';
    return '${_formatRelative(score.generatedAt)} old';
  }

  Color _telemetryAgeColor(
    ConditionsScore? score,
    DateTime now,
    SkotiqColors colors,
  ) {
    if (score == null) return colors.textMuted;
    final age = now.difference(score.generatedAt.toUtc());
    if (age.inMinutes >= 5) return colors.warning;
    return colors.textSecondary;
  }

  String _formatRelative(DateTime time) {
    final diff = DateTime.now().toUtc().difference(time.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }

  String _formatSecs(double? seconds) {
    if (seconds == null) return '0s';
    final rounded = seconds.round();
    if (rounded < 60) return '${rounded}s';
    final minutes = rounded ~/ 60;
    final rest = rounded % 60;
    return rest == 0 ? '${minutes}m' : '${minutes}m ${rest}s';
  }

  String _title(String raw) {
    final words = raw
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase());
    return words.join(' ');
  }
}

class _Shell extends StatelessWidget {
  final SkotiqColors colors;
  final String statusLabel;
  final Color statusColor;
  final Widget child;

  const _Shell({
    required this.colors,
    required this.statusLabel,
    required this.statusColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.cloudCog, size: 14, color: colors.primary),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                'ADAPTIVE CONDITIONS',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: colors.textMuted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: SkotiqDecorations.statusChip(
                statusColor,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        child,
      ],
    );
  }
}

class _ScoreLine extends StatelessWidget {
  final SkotiqColors colors;
  final ConditionsScore? score;

  const _ScoreLine({required this.colors, required this.score});

  @override
  Widget build(BuildContext context) {
    final s = score;
    final value = s?.score.clamp(0.0, 100.0);
    final color = _scoreColor(value, colors);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              value == null ? '--' : value.toStringAsFixed(0),
              style: SkotiqTypography.telemetryLg.copyWith(
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                value == null ? 'No score' : s!.qualityLabel,
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        ClipRRect(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          child: LinearProgressIndicator(
            value: value == null ? 0 : value / 100.0,
            minHeight: 5,
            backgroundColor: colors.border.withValues(alpha: 0.35),
            color: color,
          ),
        ),
        if (s != null) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceXs,
            children: [
              _AxisChip(colors: colors, label: 'T', value: s.transparencyScore),
              _AxisChip(colors: colors, label: 'S', value: s.seeingScore),
              _AxisChip(colors: colors, label: 'C', value: s.cloudScore),
              _AxisChip(colors: colors, label: 'W', value: s.windScore),
            ],
          ),
        ],
      ],
    );
  }

  Color _scoreColor(double? value, SkotiqColors colors) {
    if (value == null) return colors.textMuted;
    if (value >= 70) return colors.success;
    if (value >= 50) return colors.warning;
    return colors.error;
  }
}

class _AxisChip extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final double? value;

  const _AxisChip({
    required this.colors,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final text = value == null ? '--' : value!.toStringAsFixed(0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: colors.surfaceAlt.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        '$label $text',
        style: SkotiqTypography.withTabular(
          SkotiqTypography.overline.copyWith(
            fontWeight: FontWeight.w500,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;
  final Color? highlight;

  const _InfoRow({
    required this.colors,
    required this.label,
    required this.value,
    this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textMuted),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: SkotiqTypography.withTabular(
              SkotiqTypography.labelSm.copyWith(
                fontWeight: FontWeight.w600,
                color: highlight ?? colors.textSecondary,
              ),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
