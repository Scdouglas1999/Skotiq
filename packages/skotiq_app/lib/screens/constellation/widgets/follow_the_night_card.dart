import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../your_sky/sky_atlas_format.dart';
import '../constellation_format.dart';

/// A follow-the-night nudge: "M31 is dark for you now and the swarm needs more
/// depth." Ready-now suggestions get the accent treatment and a Claim button; a
/// target this user already holds the baton for offers Release instead; the rest
/// read as muted context (below horizon / already held by someone else).
class FollowTheNightCard extends StatelessWidget {
  final FollowTheNightSuggestion suggestion;

  /// Claim the baton for this target (take active-imager duty). Disabled while
  /// [claiming] is true; null when the baton is not available to this user.
  final VoidCallback? onClaim;
  final bool claiming;

  /// Release the baton back to the swarm. Non-null only when this user holds it
  /// ([FollowTheNightSuggestion.heldByMe]); disabled while [releasing] is true.
  final VoidCallback? onRelease;
  final bool releasing;

  /// Queue this target into the planner/sequencer tonight (creates/resolves a
  /// library target at the suggestion's RA/Dec). Null when planning is
  /// unavailable; disabled while [planning] is true.
  final VoidCallback? onPlanTonight;
  final bool planning;

  const FollowTheNightCard({
    super.key,
    required this.suggestion,
    required this.onClaim,
    this.claiming = false,
    this.onRelease,
    this.releasing = false,
    this.onPlanTonight,
    this.planning = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final ready = suggestion.isReadyNow;
    final held = suggestion.heldByMe;
    final accent = (ready || held) ? colors.accent : colors.textMuted;

    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                  decoration: SkotiqDecorations.chip(colors, tone: accent),
                  child: Icon(
                    held
                        ? LucideIcons.flag
                        : ready
                            ? LucideIcons.moonStar
                            : LucideIcons.moon,
                    size: SkotiqTokens.iconSm,
                    color: accent,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        suggestion.targetName,
                        style: SkotiqTypography.labelStrong.copyWith(
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        formatCenter(suggestion.raDeg, suggestion.decDeg),
                        style: SkotiqTypography.captionSm.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (held)
                  const StatusPill(
                    icon: LucideIcons.flag,
                    label: 'BATON',
                    value: 'yours',
                    status: StatusPillStatus.success,
                  )
                else if (ready)
                  const StatusPill(
                    icon: LucideIcons.sparkles,
                    label: 'NOW',
                    value: 'dark',
                    status: StatusPillStatus.active,
                  ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Text(
              formatFollowHint(
                targetName: suggestion.targetName,
                isReadyNow: ready,
                altitudeOk: suggestion.handoff.altitudeOk,
                swarmSeconds: suggestion.swarmIntegrationSeconds,
              ),
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
            if (suggestion.swarmIntegrationSeconds > 0) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                '${formatIntegration(suggestion.swarmIntegrationSeconds)} fused so far',
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ],
            if (_hasActions) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: SkotiqTokens.spaceSm,
                runSpacing: SkotiqTokens.spaceSm,
                children: [
                  if (onPlanTonight != null)
                    SkotiqButton(
                      label: 'Plan tonight',
                      icon: LucideIcons.calendarPlus,
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      isLoading: planning,
                      onPressed: planning ? null : onPlanTonight,
                    ),
                  if (held && onRelease != null)
                    SkotiqButton(
                      label: 'Release',
                      icon: LucideIcons.flagOff,
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      isLoading: releasing,
                      onPressed: releasing ? null : onRelease,
                    )
                  else if (onClaim != null)
                    SkotiqButton(
                      label: 'Take the baton',
                      icon: LucideIcons.flag,
                      size: ButtonSize.small,
                      isLoading: claiming,
                      onPressed: claiming ? null : onClaim,
                    ),
                ],
              ),
            ],
          ],
        ));
  }

  bool get _hasActions =>
      onPlanTonight != null ||
      (suggestion.heldByMe && onRelease != null) ||
      onClaim != null;
}
