// The Overview blocks that belong to parts of a plan only some runs use: the
// sky-brightness exposure, the Target Scheduler, its swap on the sky's
// conditions and the live-stacking broadcast. Each takes what it shows and
// nothing else; the tab decides when each one is shown.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart' show SchedulerScoreEntry;
import 'package:skotiq_core/errors.dart' show userFacingError;
import 'package:skotiq_core/models.dart'
    show AdaptiveExposureEvent, AdaptiveExposureReason, AdaptiveSwapRuntimeState, AdaptiveSwapSnapshot;
import 'package:skotiq_core/providers.dart'
    show LiveBroadcast, LiveBroadcastReach;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../data/plan/scheduler_provider.dart';
import '../../night_control_contracts.dart';
import '../panel_widgets.dart';

String _seconds(double secs) =>
    DurationFormat.seconds(secs, style: DurationStyle.short);

/// "Adaptive exposure · Adapted": what the sky's brightness made of the
/// planned exposure.
class NightAdaptiveExposureSection extends StatelessWidget {
  const NightAdaptiveExposureSection({super.key, required this.decision});

  final AdaptiveExposureEvent decision;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final (String key, MetricTone? tone) = switch (decision.reason) {
      AdaptiveExposureReason.adapted => (
          decision.isNontrivialAdjustment
              ? 'nightAdaptiveAdapted'
              : 'nightAdaptiveAsPlanned',
          decision.isNontrivialAdjustment ? MetricTone.good : null,
        ),
      AdaptiveExposureReason.clampedMin => (
          'nightAdaptiveClampedMin',
          MetricTone.warning,
        ),
      AdaptiveExposureReason.clampedMax => (
          'nightAdaptiveClampedMax',
          MetricTone.warning,
        ),
      AdaptiveExposureReason.outOfNominalBounds => (
          'nightAdaptiveOutOfBounds',
          MetricTone.warning,
        ),
      AdaptiveExposureReason.unavailable => (
          'nightAdaptiveNoSky',
          MetricTone.warning,
        ),
      AdaptiveExposureReason.disabled || AdaptiveExposureReason.unknown => (
          'nightAdaptiveAsPlanned',
          null
        ),
    };
    final filter = decision.filter;
    final sky = decision.skyBrightnessMag;
    return NightPanelSection(
      title: l10n.text('nightAdaptiveExposure'),
      trailing: l10n.text(key),
      trailingTone: tone,
      gap: SkotiqTokens.spaceXs,
      children: <Widget>[
        NightPanelRow(
          label: filter == null || filter.isEmpty
              ? l10n.text('nightAdaptiveExposureRow')
              : l10n.text(
                  'nightAdaptiveExposureFilter',
                  params: <String, String>{'filter': filter},
                ),
          value: l10n.text(
            'nightAdaptiveSecondsOfPlan',
            params: <String, String>{
              'secs': _seconds(decision.adaptedSecs),
              'planned': _seconds(decision.nominalSecs),
            },
          ),
        ),
        NightPanelRow(
          label: l10n.text('nightAdaptiveSky'),
          value: sky == null
              ? null
              : l10n.text(
                  'nightAdaptiveSkyValue',
                  params: <String, String>{'mag': sky.toStringAsFixed(2)},
                ),
        ),
      ],
    );
  }
}

/// "Scheduler · pick 4 at 23:12": the target the Target Scheduler chose and
/// the candidates it weighed.
class NightSchedulerSection extends StatelessWidget {
  const NightSchedulerSection({
    super.key,
    required this.decision,
    required this.minScore,
  });

  /// Null until the scheduler's first pick in this run.
  final SchedulerDecisionView? decision;

  /// The node's floor: no target under it is run.
  final double minScore;

  /// Candidates listed under the pick.
  static const int candidateRows = 4;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final decision = this.decision;
    final title = l10n.text('nightSchedulerTitle');
    if (decision == null) {
      return NightPanelSection(
        title: title,
        children: <Widget>[NightPanelNote(l10n.text('nightSchedulerWaiting'))],
      );
    }
    final picked = decision.pickedTargetName;
    final score = decision.pickedScore;
    return NightPanelSection(
      title: title,
      trailing: l10n.text(
        'nightSchedulerPickAt',
        params: <String, String>{
          'n': '${decision.decisionCounter}',
          'time': ClockFormat.hm(decision.time),
        },
      ),
      gap: SkotiqTokens.spaceXs,
      children: <Widget>[
        if (picked != null)
          _CandidateRow(
            name: l10n.text(
              'nightSchedulerPicked',
              params: <String, String>{'target': picked},
            ),
            value: score == null ? null : '${score.round()}',
            tone: MetricTone.good,
            strong: true,
          )
        else
          NightPanelNote(
            l10n.text(
              'nightSchedulerNoPick',
              params: <String, String>{'floor': '${minScore.round()}'},
            ),
            tone: MetricTone.warning,
          ),
        for (final entry in decision.scores
            .where((s) => s.targetName != picked)
            .take(candidateRows))
          _candidate(entry, l10n),
      ],
    );
  }

  Widget _candidate(SchedulerScoreEntry entry, SkotiqLocalizations l10n) {
    if (entry.runnable) {
      return _CandidateRow(
        name: entry.targetName,
        value: '${entry.totalScore.round()}',
      );
    }
    final reason = entry.reason;
    return _CandidateRow(
      name: entry.targetName,
      value: reason == null || reason.isEmpty
          ? l10n.text('nightSchedulerSkipped')
          : reason,
      tone: MetricTone.warning,
    );
  }
}

/// A target and its score (or why it was skipped). The value keeps its width
/// up to the section's note share; the name takes the rest.
class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.name,
    required this.value,
    this.tone,
    this.strong = false,
  });

  final String name;
  final String? value;
  final MetricTone? tone;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final valueColor =
        tone == null ? colors.textPrimary : nightToneColor(tone!, colors);
    return MergeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Expanded(
              child: Text(
                name,
                style: (strong
                        ? SkotiqTypography.labelSm
                        : SkotiqTypography.caption)
                    .copyWith(
                  color: strong ? colors.textPrimary : colors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * NightPanelSection.noteShare,
              ),
              child: Text(
                value ?? kReadoutUnknown,
                textAlign: TextAlign.end,
                style: SkotiqTypography.monoXs.copyWith(color: valueColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Conditions swap · Holding": the conditions score the scheduler weighs
/// and whether it has swapped to a target the sky suits better.
class NightConditionsSwapSection extends StatelessWidget {
  const NightConditionsSwapSection({
    super.key,
    required this.snapshot,
    required this.swapBelow,
    required this.targetName,
    required this.now,
  });

  final AsyncValue<AdaptiveSwapSnapshot?> snapshot;

  /// The node's floor: under it the scheduler looks for a better target.
  final double swapBelow;

  /// The plan's name for a target id the executor reports.
  final String Function(String id) targetName;

  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final title = l10n.text('nightSwapTitle');
    final value = snapshot.valueOrNull;
    if (value == null) {
      final String note;
      MetricTone? tone;
      if (snapshot.hasError) {
        note = l10n.text(
          'nightSwapError',
          params: <String, String>{'detail': userFacingError(snapshot.error!)},
        );
        tone = MetricTone.bad;
      } else if (snapshot.isLoading) {
        note = l10n.text('nightSwapLoading');
      } else {
        note = l10n.text('nightSwapNoScore');
      }
      return NightPanelSection(
        title: title,
        children: <Widget>[NightPanelNote(note, tone: tone)],
      );
    }

    final score = value.score;
    final state = value.state;
    final (String status, MetricTone? tone) = _status(state, score?.score);
    final age = score == null ? null : now.difference(score.generatedAt);
    final reason = state.lastDecisionReason;
    return NightPanelSection(
      title: title,
      trailing: l10n.text(status),
      trailingTone: tone,
      gap: SkotiqTokens.spaceXs,
      children: <Widget>[
        NightPanelRow(
          label: l10n.text('nightSwapScore'),
          value: score == null
              ? null
              : '${score.score.round()} · ${score.qualityLabel}',
        ),
        NightPanelRow(
          label: l10n.text('nightSwapBelow'),
          value: _floor(state),
        ),
        NightPanelRow(
          label: l10n.text('nightSwapLast'),
          value: _lastSwap(state, l10n),
        ),
        if (state.cooldownRemainingSecs(now) case final wait?)
          NightPanelRow(
            label: l10n.text('nightSwapNextAllowed'),
            value: l10n.text(
              'nightSwapIn',
              params: <String, String>{
                'time':
                    DurationFormat.seconds(wait, style: DurationStyle.short),
              },
            ),
          ),
        if (age != null)
          NightPanelRow(
            label: l10n.text('nightSwapScoreAge'),
            value: RelativeTime.age(age),
          ),
        if (age != null && age.inMinutes >= 5)
          NightPanelNote(l10n.text('nightSwapStale'), tone: MetricTone.warning),
        if (reason != null && reason.isNotEmpty) NightPanelNote(reason),
      ],
    );
  }

  (String, MetricTone?) _status(AdaptiveSwapRuntimeState state, double? score) {
    final kind = state.lastDecisionKind?.toLowerCase() ?? '';
    if (kind.contains('swap')) return ('nightSwapSwapped', MetricTone.warning);
    if (kind.contains('hold') || kind.contains('keep')) {
      return ('nightSwapHolding', MetricTone.good);
    }
    if (score == null) return ('nightSwapNoData', null);
    final floor = state.configuredThreshold ?? swapBelow;
    return score >= floor
        ? ('nightSwapAboveFloor', MetricTone.good)
        : ('nightSwapBelowFloor', MetricTone.warning);
  }

  /// "50", or "medium · 50" when the executor names the target's tier.
  String _floor(AdaptiveSwapRuntimeState state) {
    final floor = '${(state.configuredThreshold ?? swapBelow).round()}';
    final tier = state.currentTier;
    return tier == null || tier.isEmpty ? floor : '$tier · $floor';
  }

  String _lastSwap(AdaptiveSwapRuntimeState state, SkotiqLocalizations l10n) {
    final at = state.lastSwapAt;
    if (at == null) return l10n.text('nightSwapNone');
    final ago = RelativeTime.ago(at, now: now);
    final from = state.lastSwapFromTargetId;
    final to = state.lastSwapToTargetId;
    if (from == null || from.isEmpty || to == null || to.isEmpty) return ago;
    return '$ago · ${targetName(from)} → ${targetName(to)}';
  }
}

/// "Broadcast · Live, private": the live stack the audience is watching and
/// the link to hand out.
class NightBroadcastSection extends StatefulWidget {
  const NightBroadcastSection({super.key, required this.broadcast});

  final LiveBroadcast broadcast;

  /// Side of the QR code; large enough to scan from a phone held at arm's
  /// length off a laptop screen.
  static const double qrSize = 132;

  @override
  State<NightBroadcastSection> createState() => _NightBroadcastSectionState();
}

class _NightBroadcastSectionState extends State<NightBroadcastSection> {
  // A white QR code is the brightest thing on a night screen, so it is shown
  // only on request.
  bool _showQr = false;

  Future<void> _copy(String url) async {
    final l10n = SkotiqLocalizations.of(context);
    final overlay = Overlay.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: url));
    if (overlay == null || !overlay.mounted) return;
    SkotiqToastHelper.showInOverlay(
      overlay: overlay,
      message: l10n.text('nightBroadcastCopied'),
      severity: SkotiqAlertSeverity.success,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final broadcast = widget.broadcast;
    final url = broadcast.audienceUrl;
    final shown = broadcast.shownUrl;
    final reachable = url != null && broadcast.reach == LiveBroadcastReach.open;
    final target = broadcast.target;
    return NightPanelSection(
      title: l10n.text('nightBroadcastTitle'),
      trailing: l10n.text(
        broadcast.isPublic
            ? 'nightBroadcastLivePublic'
            : 'nightBroadcastLivePrivate',
      ),
      trailingTone: MetricTone.good,
      gap: SkotiqTokens.spaceXs,
      children: <Widget>[
        NightPanelRow(
          label: l10n.text('nightBroadcastTarget'),
          value: target == null || target.isEmpty ? null : target,
        ),
        NightPanelRow(
          label: l10n.text('nightBroadcastStacked'),
          value: l10n.text(
            'nightBroadcastStackedValue',
            params: <String, String>{
              'frames': '${broadcast.frames}',
              'time': _seconds(broadcast.integrationSecs),
            },
          ),
        ),
        NightPanelRow(
          label: l10n.text('nightBroadcastViewers'),
          value: '${broadcast.viewers}',
        ),
        if (shown != null)
          Semantics(
            label: l10n.text(
              'nightBroadcastLinkSemantics',
              params: <String, String>{'url': shown},
            ),
            excludeSemantics: true,
            child: Text(
              shown,
              style: SkotiqTypography.monoXs.copyWith(
                color: reachable ? colors.textPrimary : colors.textMuted,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (!reachable)
          NightPanelNote(
            l10n.text(
              broadcast.reach == LiveBroadcastReach.thisComputerOnly
                  ? 'nightBroadcastLocalOnly'
                  : 'nightBroadcastServerOff',
            ),
            tone: MetricTone.warning,
          )
        else ...<Widget>[
          const SizedBox(height: SkotiqTokens.spaceXs),
          NightPanelGrid(
            columns: 2,
            children: <Widget>[
              NightPanelButton(
                label: l10n.text('nightBroadcastCopy'),
                onPressed: () => _copy(url),
              ),
              NightPanelButton(
                label: l10n.text(
                  _showQr ? 'nightBroadcastHideQr' : 'nightBroadcastShowQr',
                ),
                selected: _showQr,
                onPressed: () => setState(() => _showQr = !_showQr),
              ),
            ],
          ),
          if (_showQr)
            Padding(
              padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                  child: QrImageView(
                    data: url,
                    size: NightBroadcastSection.qrSize,
                    padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                    backgroundColor: ImageOverlayColors.foreground,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: ImageOverlayColors.shadow,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: ImageOverlayColors.shadow,
                    ),
                    semanticsLabel: l10n.text(
                      'nightBroadcastQrSemantics',
                      params: <String, String>{'url': shown ?? ''},
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
