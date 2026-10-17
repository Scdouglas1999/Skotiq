import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../collaborative_sky/coimaging_create_sheet.dart';
import '../your_sky/region_detail_screen.dart';
import '../your_sky/sky_atlas_format.dart';
import 'constellation_contribute_sheet.dart';
import 'constellation_format.dart';
import 'constellation_ui_providers.dart';
import 'widgets/contribution_bar.dart';

/// Detail for one shared community target: the fused swarm co-add summary, your
/// contribution, and the three swarm actions — JOIN (record the hub target),
/// CONTRIBUTE (push your additive sums after an explicit consent step), and PULL
/// the fused co-add to blend into Your Sky.
class SharedTargetDetailScreen extends ConsumerStatefulWidget {
  final SharedTarget target;

  const SharedTargetDetailScreen({super.key, required this.target});

  @override
  ConsumerState<SharedTargetDetailScreen> createState() =>
      _SharedTargetDetailScreenState();
}

class _SharedTargetDetailScreenState
    extends ConsumerState<SharedTargetDetailScreen> {
  bool _joined = false;
  bool _pulling = false;
  bool _retracting = false;
  bool _coImaging = false;
  List<SwarmTile> _blended = const [];

  /// Own integration (seconds) at the moment of the last successful pull — the
  /// "before" half of the Pull & Blend payoff card.
  double _ownSecondsBeforeBlend = 0.0;

  SharedTarget get _target => widget.target;

  @override
  void initState() {
    super.initState();
    _joined = ref
        .read(constellationServiceProvider)
        .joinedTargets
        .any((t) => t.targetId == _target.targetId);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final yourSeconds =
        ref.watch(yourContributionSecondsProvider(_target)).valueOrNull ?? 0.0;
    // Contribute / Pull / Retract all read the LOCAL atlas + LOCAL contribution
    // receipts and write the hub — empty on a slave, so they are host-only.
    // Browse/Join stay enabled everywhere.
    final hostActionsEnabled =
        ref.watch(isConstellationHostActionEnabledProvider);
    // widget.target is a frozen constructor snapshot; watch the refreshed hub
    // target so contribute/retract update the headline depth + bar in place.
    final refreshed = ref
        .watch(sharedTargetsProvider)
        .valueOrNull
        ?.where((t) => t.targetId == widget.target.targetId)
        .firstOrNull;
    final effectiveTarget = refreshed ?? _target;

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        elevation: 0,
        title: Text(
          _target.name.isEmpty ? 'Target #${_target.targetId}' : _target.name,
          style:
              SkotiqTypography.bodyStrong.copyWith(color: colors.textPrimary),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: SkotiqTokens.screenPadding,
          children: [
            _SwarmSummaryCard(
                target: effectiveTarget, yourSeconds: yourSeconds),
            const SizedBox(height: SkotiqTokens.spaceLg),
            _JoinCard(
              joined: _joined,
              onToggle: _toggleJoin,
              targetName: _target.name,
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            _CoImageCard(starting: _coImaging, onCoImage: _coImage),
            if (!hostActionsEnabled) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              const _HostOnlyNotice(),
            ],
            const SizedBox(height: SkotiqTokens.spaceMd),
            _ContributeCard(
              enabled: _joined && hostActionsEnabled,
              yourSeconds: yourSeconds,
              onContribute: _contribute,
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            _BlendCard(
              enabled: _joined && hostActionsEnabled,
              pulling: _pulling,
              blended: _blended,
              onPull: _pullAndBlend,
            ),
            if (_blended.isNotEmpty) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              _BlendPayoffCard(
                ownSecondsBefore: _ownSecondsBeforeBlend,
                swarmSeconds: effectiveTarget.integrationSeconds,
                onOpenInYourSky: _openBlendedRegion,
              ),
            ],
            if (hostActionsEnabled) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              _ContributionsCard(
                target: _target,
                onRetract: _retract,
                busy: _retracting,
              ),
            ],
            if (_blended.isNotEmpty) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              const _SwarmTrustCard(),
            ],
            const SizedBox(height: SkotiqTokens.spaceLg),
          ],
        ),
      ),
    );
  }

  void _toggleJoin() {
    final service = ref.read(constellationServiceProvider);
    setState(() {
      if (_joined) {
        service.leaveSharedTarget(_target.targetId);
        _joined = false;
      } else {
        service.joinSharedTarget(_target);
        _joined = true;
      }
    });
  }

  /// Open a live co-imaging session on this shared target, prefilling the create
  /// sheet from the target's own centre + cone so the pooled session matches the
  /// field being browsed. Co-imaging routes through the hub client (not the
  /// local atlas), so — like Join — it works on both the FFI and network
  /// backends and needs no host-only gate.
  Future<void> _coImage() async {
    if (_coImaging) return;
    setState(() => _coImaging = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final session = await showCoImagingCreateSheet(
        context,
        initialTargetName: _target.name,
        initialRaDeg: _target.raDeg,
        initialDecDeg: _target.decDeg,
        initialRadiusDeg: _target.radiusDeg,
      );
      if (session == null || !mounted) return;
      // The creator is the anchor participant, so their subs need the same
      // unattended-contribution consent the join flow requires before we can
      // promise a co-add.
      final sharing = await ensureCoImagingSharingConsent(context, ref);
      if (sharing == null) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            sharing
                ? 'Started a live co-imaging session on ${session.targetName} — '
                    'your subs co-add into the combined stack.'
                : 'Started a live co-imaging session on ${session.targetName}. '
                    'Enable unattended contribution to add your subs to the '
                    'combined stack.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _coImaging = false);
    }
  }

  Future<void> _contribute() async {
    final outcome = await showConstellationContributeSheet(
      context,
      target: _target,
    );
    if (outcome == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    ref.invalidate(sharedTargetsProvider);
    ref.invalidate(yourContributionSecondsProvider(_target));
    final msg = outcome.acceptedCount == 0
        ? 'No locally-imaged tiles overlap this target yet.'
        : 'Contributed ${outcome.acceptedCount} tile'
            '${outcome.acceptedCount == 1 ? '' : 's'} to the swarm'
            '${outcome.rejectedCount > 0 ? ' (${outcome.rejectedCount} rejected)' : ''}.';
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pullAndBlend() async {
    setState(() => _pulling = true);
    final messenger = ScaffoldMessenger.of(context);
    // Snapshot the user's own depth on this field BEFORE the blend so the payoff
    // card can honestly show "yours -> yours + swarm".
    final ownBefore =
        ref.read(yourContributionSecondsProvider(_target)).valueOrNull ?? 0.0;
    try {
      // Pull the additive `.skt` accumulator (finalized: false) so the service
      // actually folds it into the local atlas — that merge is what makes the
      // swarm's depth show up in Your Sky. A finalized FITS pull is a
      // display-only blob that never blends, which would make the "blended
      // into Your Sky" copy below false.
      final tiles = await ref
          .read(constellationServiceProvider)
          .pullTarget(_target.targetId, finalized: false);
      if (!mounted) return;
      setState(() {
        _blended = tiles;
        _ownSecondsBeforeBlend = ownBefore;
        _pulling = false;
      });
      // The pull already merged each delta into the local atlas tiles; refresh
      // the atlas read surface so Your Sky reflects the deeper blended stack.
      ref.invalidate(skyAtlasCoverageProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tiles.isEmpty
                ? 'Nothing to pull for this target yet.'
                : 'Pulled and blended ${tiles.length} community tile'
                    '${tiles.length == 1 ? '' : 's'} into Your Sky.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _pulling = false);
      messenger.showSnackBar(
        SnackBar(content: Text(describeConstellationError(error))),
      );
    }
  }

  /// Deep-link into the Your Sky region the blend deepened, so the payoff lands
  /// on-screen instead of telling the user to "go look elsewhere". Resolves the
  /// tightest region covering the target centre (the pull blended its tiles into
  /// the same atlas region) and pushes RegionDetail. Falls back to a snackbar
  /// when no region covers the field yet.
  Future<void> _openBlendedRegion() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final region = await ref
        .read(skyAtlasServiceProvider)
        .getRegionForPoint(_target.raDeg, _target.decDeg);
    if (!mounted) return;
    if (region == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Open Your Sky to scrub the blended depth — name this field as a '
            'region to track it night over night.',
          ),
        ),
      );
      return;
    }
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => RegionDetailScreen(regionId: region.id),
      ),
    );
  }

  Future<void> _retract(ContributionRecord record) async {
    if (_retracting) return;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Retract this contribution?'),
        content: Text(
          'This subtracts your contribution to tile ${record.tileId} '
          '(${record.contributedFrames} frame'
          '${record.contributedFrames == 1 ? '' : 's'} · '
          '${formatIntegration(record.contributedIntegrationSeconds)}) back '
          'off the swarm.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Retract'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _retracting = true);
    try {
      final receipt = await ref
          .read(constellationServiceProvider)
          .retractTile(record.tileId);
      if (!mounted) return;
      // The high-water reset means the contribution bar + swarm depth shift; the
      // contributions list drops this tile.
      ref.invalidate(myContributionsProvider);
      ref.invalidate(sharedTargetsProvider);
      ref.invalidate(yourContributionSecondsProvider(_target));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Retracted your contribution to tile ${record.tileId}. The fused '
            'depth is now ${receipt.totalFramesAfter} frame'
            '${receipt.totalFramesAfter == 1 ? '' : 's'}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeConstellationError(error))),
      );
    } finally {
      if (mounted) setState(() => _retracting = false);
    }
  }
}

class _SwarmSummaryCard extends StatelessWidget {
  final SharedTarget target;
  final double yourSeconds;

  const _SwarmSummaryCard({required this.target, required this.yourSeconds});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              formatCenter(target.raDeg, target.decDeg),
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            ResponsiveStatStrip(
              stats: [
                ResponsiveStat(
                  label: 'FUSED DEPTH',
                  value: formatIntegration(target.integrationSeconds),
                  icon: LucideIcons.layers,
                  valueColor: colors.accent,
                ),
                ResponsiveStat(
                  label: 'CONTRIBUTORS',
                  value: '${target.contributors}',
                  icon: LucideIcons.users,
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            ContributionBar(
              yourSeconds: yourSeconds,
              swarmSeconds: target.integrationSeconds,
            ),
          ],
        ));
  }
}

class _JoinCard extends StatelessWidget {
  final bool joined;
  final VoidCallback onToggle;
  final String targetName;

  const _JoinCard({
    required this.joined,
    required this.onToggle,
    required this.targetName,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Row(
          children: [
            Icon(
              joined ? LucideIcons.checkCircle2 : LucideIcons.userPlus,
              size: SkotiqTokens.iconMd,
              color: joined ? colors.success : colors.textSecondary,
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    joined ? 'Joined' : 'Join this target',
                    style: SkotiqTypography.labelStrong.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    joined
                        ? 'Contribute and pull are unlocked.'
                        : 'Track this field so you can contribute and pull.',
                    style: SkotiqTypography.captionSm.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            SkotiqButton(
              label: joined ? 'Leave' : 'Join',
              variant: joined ? ButtonVariant.secondary : ButtonVariant.primary,
              size: ButtonSize.small,
              onPressed: onToggle,
            ),
          ],
        ));
  }
}

/// Opens a LIVE co-imaging session on this target: the anchor side of
/// pooling integration across rigs, distinct from the async swarm Contribute/
/// Pull below. Available on every backend since the session routes through the
/// hub client, not the local atlas.
class _CoImageCard extends StatelessWidget {
  final bool starting;
  final VoidCallback onCoImage;

  const _CoImageCard({required this.starting, required this.onCoImage});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.radio,
                  size: SkotiqTokens.iconMd,
                  color: colors.accent,
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    'Co-image this target live',
                    style: SkotiqTypography.labelStrong.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              'Open a live session so other rigs can pool their integration into '
              'the same combined stack across the night. You stay the anchor and '
              'can end it anytime.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Align(
              alignment: Alignment.centerRight,
              child: SkotiqButton(
                label: starting ? 'Starting…' : 'Co-image this target',
                icon: LucideIcons.radio,
                size: ButtonSize.small,
                isLoading: starting,
                onPressed: starting ? null : onCoImage,
              ),
            ),
          ],
        ));
  }
}

class _ContributeCard extends StatelessWidget {
  final bool enabled;
  final double yourSeconds;
  final VoidCallback onContribute;

  const _ContributeCard({
    required this.enabled,
    required this.yourSeconds,
    required this.onContribute,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final hasLocal = yourSeconds > 0;
    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.upload,
                  size: SkotiqTokens.iconMd,
                  color: enabled ? colors.accent : colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    'Contribute your light',
                    style: SkotiqTypography.labelStrong.copyWith(
                      color: enabled ? colors.textPrimary : colors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              hasLocal
                  ? 'Add your ${formatIntegration(yourSeconds)} of imaging on this '
                      'field to the swarm. You will confirm exactly what leaves '
                      'your device first.'
                  : 'You have not imaged this field yet. Image and fold it into '
                      'Your Sky, then contribute.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Align(
              alignment: Alignment.centerRight,
              child: SkotiqButton(
                label: 'Contribute',
                icon: LucideIcons.upload,
                size: ButtonSize.small,
                onPressed: enabled && hasLocal ? onContribute : null,
              ),
            ),
          ],
        ));
  }
}

class _BlendCard extends StatelessWidget {
  final bool enabled;
  final bool pulling;
  final List<SwarmTile> blended;
  final VoidCallback onPull;

  const _BlendCard({
    required this.enabled,
    required this.pulling,
    required this.blended,
    required this.onPull,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final blendedCount = blended.length;
    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.download,
                  size: SkotiqTokens.iconMd,
                  color: enabled ? colors.accent : colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    'Pull the fused image',
                    style: SkotiqTypography.labelStrong.copyWith(
                      color: enabled ? colors.textPrimary : colors.textMuted,
                    ),
                  ),
                ),
                if (blendedCount > 0)
                  StatusPill(
                    icon: LucideIcons.combine,
                    label: 'BLENDED',
                    value: '$blendedCount',
                    status: StatusPillStatus.success,
                  ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              blendedCount > 0
                  ? 'The swarm co-add is cached locally and blended into Your Sky '
                      'for this field — see the depth gained below.'
                  : 'Download the swarm\'s combined co-add for this field and blend '
                      'it into Your Sky alongside your own integration.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Align(
              alignment: Alignment.centerRight,
              child: SkotiqButton(
                label: blendedCount > 0 ? 'Refresh blend' : 'Pull & blend',
                icon: LucideIcons.combine,
                size: ButtonSize.small,
                isLoading: pulling,
                onPressed: enabled && !pulling ? onPull : null,
              ),
            ),
          ],
        ));
  }
}

/// Pull & Blend payoff: the before/after depth the swarm's photons added to this
/// field, plus a deep link into the Your Sky region so the deeper sky lands
/// on-screen instead of a dead-end "go look elsewhere". "Before" is the user's
/// own integration at pull time; "after" adds the fused community depth the
/// blend folded into the local atlas.
class _BlendPayoffCard extends StatelessWidget {
  final double ownSecondsBefore;
  final double swarmSeconds;
  final VoidCallback onOpenInYourSky;

  const _BlendPayoffCard({
    required this.ownSecondsBefore,
    required this.swarmSeconds,
    required this.onOpenInYourSky,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final after = ownSecondsBefore + swarmSeconds;
    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.trendingUp,
                  size: SkotiqTokens.iconMd,
                  color: colors.success,
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    'Depth gained',
                    style: SkotiqTypography.labelStrong.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Row(
              children: [
                Text(
                  formatIntegration(ownSecondsBefore),
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Icon(
                  LucideIcons.arrowRight,
                  size: SkotiqTokens.iconSm,
                  color: colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Text(
                  formatIntegration(after),
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Text(
                  'fused',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceXs),
            Text(
              'The swarm added ${formatIntegration(swarmSeconds)} of community '
              'integration to your ${formatIntegration(ownSecondsBefore)} on this '
              'field.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Align(
              alignment: Alignment.centerRight,
              child: SkotiqButton(
                label: 'Open in Your Sky',
                icon: LucideIcons.sparkles,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: onOpenInYourSky,
              ),
            ),
          ],
        ));
  }
}

/// Slave notice: the host-owned actions read the host's atlas + receipts, so we
/// disable them here and say where they run rather than no-op silently.
class _HostOnlyNotice extends StatelessWidget {
  const _HostOnlyNotice();

  @override
  Widget build(BuildContext context) {
    return const SkotiqBanner(
        title: 'Contributing, pulling, and retracting run on your imaging '
            'host. Browse and join from here; open Constellation on the host to '
            'share your light.',
        tone: BannerTone.info);
  }
}

/// "Your contributions" — the persisted retractable receipts for this hub.
///
/// Lists every tile this device has contributed (the Wave-0 receipts carrying a
/// remote contributionId) with a per-row Retract that subtracts it back off the
/// hub exactly. This is what makes the twice-printed "subtract your contribution
/// exactly" promise true. Receipts are per-tile and hub-wide (a target's cone
/// spans several tiles), so the list is scoped to the hub, not one target.
class _ContributionsCard extends ConsumerWidget {
  final SharedTarget target;
  final ValueChanged<ContributionRecord> onRetract;
  final bool busy;

  const _ContributionsCard({
    required this.target,
    required this.onRetract,
    required this.busy,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final contributionsAsync = ref.watch(myContributionsProvider);
    return contributionsAsync.when(
      data: (records) {
        if (records.isEmpty) return const SizedBox.shrink();
        return SkotiqPanel(
            padding: SkotiqTokens.cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      LucideIcons.shieldCheck,
                      size: SkotiqTokens.iconMd,
                      color: colors.accent,
                    ),
                    const SizedBox(width: SkotiqTokens.spaceMd),
                    Expanded(
                      child: Text(
                        'Your contributions',
                        style: SkotiqTypography.labelStrong.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  'You only shared additive co-add sums, so retracting a tile '
                  'subtracts your contribution exactly — the shared depth returns '
                  'to what it was before.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                for (final r in records)
                  _ContributionRow(
                    record: r,
                    onRetract: () => onRetract(r),
                    busy: busy,
                  ),
              ],
            ));
      },
      loading: () => const SkeletonBox(
        width: double.infinity,
        height: 96,
        borderRadius: SkotiqTokens.radiusLg,
      ),
      error: (error, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkotiqBanner(
              title: 'Contribution receipts unavailable',
              message: '${describeConstellationError(error)}\n\n'
                  'Retract actions are hidden until Skotiq can verify your '
                  'receipts with the imaging host.',
              tone: BannerTone.warning),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: 'Retry receipts',
              icon: SkotiqIcons.refresh,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => ref.invalidate(myContributionsProvider),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContributionRow extends StatelessWidget {
  final ContributionRecord record;
  final VoidCallback onRetract;
  final bool busy;

  const _ContributionRow({
    required this.record,
    required this.onRetract,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tile ${record.tileId}',
                  style: SkotiqTypography.label.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${record.contributedFrames} frame'
                  '${record.contributedFrames == 1 ? '' : 's'} · '
                  '${formatIntegration(record.contributedIntegrationSeconds)}',
                  style: SkotiqTypography.captionSm.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          SkotiqButton(
            label: 'Retract',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: busy ? null : onRetract,
          ),
        ],
      ),
    );
  }
}

class _SwarmTrustCard extends ConsumerWidget {
  const _SwarmTrustCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(myContributionsProvider).valueOrNull;
    if (records == null || records.isEmpty) return const SizedBox.shrink();
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Row(
          children: [
            Icon(
              LucideIcons.shieldCheck,
              size: SkotiqTokens.iconSm,
              color: colors.textMuted,
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Text(
                'You only ever shared additive co-add sums, so the hub can subtract '
                'your contribution exactly to restore the prior depth.',
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textMuted,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ));
  }
}
