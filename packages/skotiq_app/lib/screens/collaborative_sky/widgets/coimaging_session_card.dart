import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../your_sky/sky_atlas_format.dart';
import '../collaborative_sky_format.dart';

/// A card for one live co-imaging session: N rigs JOIN the SAME target and
/// their subs co-add through the additive fusion pipeline, so effective
/// integration scales with rig count and imaging continues across longitudes.
///
/// Surfaces the "we're building this together, right now" moment: the COMBINED
/// integration + frame tally across every participating rig, who is actively
/// imaging (the longitude baton), the contributor attribution, and a Join CTA.
///
/// Purely presentational — the screen wires [onJoin] to the
/// `CoImagingSessionService` and drives [joining]/[joined].
class CoImagingSessionCard extends StatelessWidget {
  final CoImagingSession session;

  /// The most recent live combined-preview event for this session, if the card
  /// is subscribed to the SSE channel. When present its combined totals + rig
  /// count supersede the one-shot [session] snapshot, so the COMBINED stat
  /// deepens in real time as subs fuse across every rig.
  final CoImagingPreview? livePreview;

  /// The hub's authoritative, consent-aware contributor credits for this session
  /// (`GET /v1/attribution`), or null while they load — the card then falls back
  /// to the participant roster's display names.
  final ArtifactAttribution? attribution;

  /// Whether this rig is already an active participant (drives the "joined"
  /// affordance instead of a Join button). Null while membership is loading or
  /// could not be verified; unknown membership never authorizes Join or Leave.
  final bool? joined;

  /// Human-readable membership lookup failure. Only used while [joined] is
  /// null; the card keeps session discovery visible while surfacing the error.
  final String? membershipErrorMessage;

  /// Retries the authoritative membership lookup after an error.
  final VoidCallback? onRetryMembership;

  /// Whether this rig's completed subs would actually co-add into the combined
  /// stack — i.e. whether unattended contribution consent is on record. Null
  /// while that lookup is in flight.
  ///
  /// Membership is NOT contribution: a rig can be joined (pointed at a framing
  /// slot) while every sub stays on the device because the operator declined
  /// the sharing consent. The caption is gated on this flag, not on [joined].
  final bool? contributing;

  /// Opens the sharing-consent flow from the joined-but-not-contributing state,
  /// so the card offers a way out of it instead of only reporting it.
  final VoidCallback? onEnableSharing;

  /// Whether a join is in-flight (drives the button spinner).
  final bool joining;

  /// Whether a leave is in-flight (drives the Leave button spinner).
  final bool leaving;

  /// Join this session as a rig. Null when already joined, the session is
  /// closed, or joining is unavailable on this device (e.g. a read-only slave).
  final VoidCallback? onJoin;

  /// Leave this session's live pool. Null when not joined, so a joined rig
  /// always has a way out of the pool instead of being silently locked in.
  final VoidCallback? onLeave;

  /// End (close) this session — passed only for the session owner while it is
  /// active. Null for a non-owner or a closed session, so only the anchor can
  /// shut the live pool for everyone.
  final VoidCallback? onEndSession;

  /// Whether an end-session call is in-flight (drives the button spinner).
  final bool endingSession;

  const CoImagingSessionCard({
    super.key,
    required this.session,
    this.livePreview,
    this.attribution,
    this.joined = false,
    this.contributing,
    this.onEnableSharing,
    this.membershipErrorMessage,
    this.onRetryMembership,
    this.joining = false,
    this.leaving = false,
    this.onJoin,
    this.onLeave,
    this.onEndSession,
    this.endingSession = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final active = session.isActive;

    // Prefer the live combined-preview totals when the card is subscribed to the
    // SSE channel. Both the snapshot and the list-endpoint session grow
    // monotonically, so max() keeps the headline honest whichever arrived last
    // (a just-refreshed list vs. the next preview tick).
    final live = livePreview;
    final combinedSeconds = live == null
        ? session.combinedIntegrationSeconds
        : math.max(
            live.combinedIntegrationSeconds,
            session.combinedIntegrationSeconds,
          );
    final combinedFrames = live == null
        ? session.combinedFrames
        : math.max(live.combinedFrames, session.combinedFrames);
    final rigCount = live == null
        ? session.participants.length
        : math.max(live.participantCount, session.participants.length);
    final liveNote = active ? formatLivePreviewNote(type: live?.type) : null;

    final contributors = sessionContributorCredits(
      session,
      rigCount: rigCount,
      attribution: attribution,
    );

    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                  decoration:
                      SkotiqDecorations.chip(colors, tone: colors.accent),
                  child: Icon(
                    LucideIcons.radio,
                    size: SkotiqTokens.iconSm,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.targetName.isEmpty
                            ? 'Live session'
                            : session.targetName,
                        style: SkotiqTypography.labelStrong.copyWith(
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        formatCenter(session.centerRaDeg, session.centerDecDeg),
                        style: SkotiqTypography.captionSm.copyWith(
                          color: colors.textMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                StatusPill(
                  icon: active ? LucideIcons.radio : LucideIcons.checkCircle2,
                  label: '',
                  value: active ? 'Live' : 'Closed',
                  status: active
                      ? StatusPillStatus.active
                      : StatusPillStatus.inactive,
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            ResponsiveStatStrip(
              minCellWidth: 104,
              stats: [
                ResponsiveStat(
                  label: 'COMBINED',
                  value: formatIntegration(combinedSeconds),
                  icon: LucideIcons.layers,
                  accent: colors.accent,
                ),
                ResponsiveStat(
                  label: 'FRAMES',
                  value: '$combinedFrames',
                  icon: LucideIcons.image,
                ),
                ResponsiveStat(
                  label: 'RIGS',
                  value: '$rigCount',
                  icon: LucideIcons.radioTower,
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Row(
              children: [
                Icon(
                  LucideIcons.users,
                  size: SkotiqTokens.iconXs,
                  color: colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    contributors,
                    style: SkotiqTypography.captionSm.copyWith(
                      color: colors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceXs),
            Row(
              children: [
                Icon(
                  active ? LucideIcons.zap : LucideIcons.flag,
                  size: SkotiqTokens.iconXs,
                  color: active ? colors.success : colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    formatSessionStatus(
                      active: active,
                      batonHolderDisplayName: session.batonHolderDisplayName,
                    ),
                    style: SkotiqTypography.captionSm.copyWith(
                      color: colors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (liveNote != null) ...[
              const SizedBox(height: SkotiqTokens.spaceXs),
              Row(
                children: [
                  Icon(
                    LucideIcons.radio,
                    size: SkotiqTokens.iconXs,
                    color: colors.accent,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Text(
                      liveNote,
                      style: SkotiqTypography.captionSm.copyWith(
                        color: colors.accent,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            if (active) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              _ActionRow(
                joined: joined,
                contributing: contributing,
                onEnableSharing: onEnableSharing,
                membershipErrorMessage: membershipErrorMessage,
                onRetryMembership: onRetryMembership,
                joining: joining,
                leaving: leaving,
                onJoin: onJoin,
                onLeave: onLeave,
                onEndSession: onEndSession,
                endingSession: endingSession,
              ),
            ],
          ],
        ));
  }
}

/// The trailing action row: a Join button, or — once this rig is in — a quiet
/// membership chip alongside a Leave control. The chip distinguishes a rig
/// whose subs actually co-add from one that merely holds a framing slot.
class _ActionRow extends StatelessWidget {
  final bool? joined;
  final bool? contributing;
  final VoidCallback? onEnableSharing;
  final String? membershipErrorMessage;
  final VoidCallback? onRetryMembership;
  final bool joining;
  final bool leaving;
  final VoidCallback? onJoin;
  final VoidCallback? onLeave;
  final VoidCallback? onEndSession;
  final bool endingSession;

  const _ActionRow({
    required this.joined,
    required this.contributing,
    required this.onEnableSharing,
    required this.membershipErrorMessage,
    required this.onRetryMembership,
    required this.joining,
    required this.leaving,
    required this.onJoin,
    required this.onLeave,
    required this.onEndSession,
    required this.endingSession,
  });

  @override
  Widget build(BuildContext context) {
    final membership = _buildMembership(context);
    // The owner's destructive "End session" sits on its own row below the
    // membership content (Join / Leave / status) so it never crowds those
    // controls off a narrow card, and it renders in every membership state (an
    // owner can end the pool whether or not their own rig is still joined).
    if (onEndSession == null) return membership;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        membership,
        const SizedBox(height: SkotiqTokens.spaceMd),
        Align(
          alignment: Alignment.centerLeft,
          child: SkotiqButton(
            label: endingSession ? 'Ending…' : 'End session',
            icon: LucideIcons.powerOff,
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
            isLoading: endingSession,
            onPressed: onEndSession,
          ),
        ),
      ],
    );
  }

  Widget _buildMembership(BuildContext context) {
    final colors = SkotiqColors.of(context);
    if (joined == null) {
      final errorMessage = membershipErrorMessage;
      if (errorMessage != null) {
        return SkotiqBanner(
            title: 'Could not verify membership',
            message: errorMessage,
            tone: BannerTone.warning,
            action: SkotiqButton(
              label: 'Retry',
              icon: SkotiqIcons.refresh,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: onRetryMembership,
            ));
      }
      return Row(
        children: [
          SizedBox(
            width: SkotiqTokens.iconSm,
            height: SkotiqTokens.iconSm,
            child: SkotiqSpinner(
                size: SkotiqTokens.iconSm, color: colors.textMuted),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            'Checking membership…',
            style: SkotiqTypography.captionSm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      );
    }
    if (joined == true) {
      // Three states, not two: contributing (green), joined-but-not-sharing
      // (neutral, with a way to turn it on), and still resolving consent.
      final isContributing = contributing == true;
      final sharingOff = contributing == false;
      final captionColor = isContributing ? colors.success : colors.textMuted;
      return Row(
        children: [
          Icon(
            isContributing ? LucideIcons.checkCircle2 : LucideIcons.circleSlash,
            size: SkotiqTokens.iconSm,
            color: captionColor,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              isContributing
                  ? 'You are pooling light here'
                  : sharingOff
                      ? 'Joined — not contributing (sharing off)'
                      : 'Joined — checking sharing…',
              style: SkotiqTypography.captionSm.copyWith(
                color: captionColor,
              ),
            ),
          ),
          if (sharingOff && onEnableSharing != null) ...[
            const SizedBox(width: SkotiqTokens.spaceSm),
            SkotiqButton(
              label: 'Turn on sharing',
              icon: LucideIcons.upload,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: onEnableSharing,
            ),
          ],
          if (onLeave != null) ...[
            const SizedBox(width: SkotiqTokens.spaceSm),
            SkotiqButton(
              label: leaving ? 'Leaving…' : 'Leave',
              icon: LucideIcons.logOut,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              isLoading: leaving,
              onPressed: onLeave,
            ),
          ],
        ],
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: SkotiqButton(
        label: joining ? 'Joining…' : 'Join session',
        icon: LucideIcons.radio,
        size: ButtonSize.small,
        isLoading: joining,
        onPressed: onJoin,
      ),
    );
  }
}
