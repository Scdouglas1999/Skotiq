import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'constellation_format.dart';
import 'constellation_sign_in_sheet.dart';
import 'constellation_ui_providers.dart';
import 'share_target_sheet.dart';
import 'shared_target_detail_screen.dart';
import 'widgets/follow_the_night_card.dart';
import 'widgets/hub_status_card.dart';
import 'widgets/shared_target_card.dart';

/// Pillar C ("Constellation") — the community swarm surface.
///
/// A top-level shell destination where the observer signs in to a self-hosted
/// hub, browses the shared community targets the swarm is collecting (each with
/// its combined depth, contributor count, and your share), follows the night
/// ("M31 is dark for you now and the swarm needs more depth"), and opens a
/// target to contribute, pull the fused co-add, and blend it into Your Sky.
///
/// Reads exclusively through the core `constellationServiceProvider` family, so
/// it works unchanged on the desktop FFI backend and the mobile network backend.
class ConstellationScreen extends StatelessWidget {
  const ConstellationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: const SafeArea(bottom: false, child: ConstellationView()),
    );
  }
}

/// Scaffold-free body so the swarm view can also be embedded (e.g. a tab).
class ConstellationView extends ConsumerWidget {
  const ConstellationView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configuredAsync = ref.watch(constellationConfiguredProvider);

    return Column(
      children: [
        Expanded(
          child: configuredAsync.when(
            data: (configured) => configured
                ? _ConnectedBody(onRefresh: () => _refresh(ref))
                : _SignedOutBody(onSignedIn: () => _refresh(ref)),
            loading: () => _buildLoading(),
            error: (error, _) => _buildError(ref, error),
          ),
        ),
      ],
    );
  }

  void _refresh(WidgetRef ref) => ConstellationView.refreshConstellation(ref);

  /// Re-reads everything the swarm view shows.
  ///
  /// Public because the view no longer carries a header of its own: the Plan
  /// screen's "Your sky" tab owns the one refresh button for all three
  /// discovery surfaces (06 §Plan removes the second header row).
  static void refreshConstellation(WidgetRef ref) {
    ref.invalidate(constellationConfiguredProvider);
    ref.invalidate(constellationHubInfoProvider);
    ref.invalidate(sharedTargetsProvider);
    ref.invalidate(followTheNightProvider(-1));
  }

  Widget _buildLoading() {
    return ShimmerLoading(
      child: ListView(
        padding: SkotiqTokens.screenPadding,
        children: const [
          SkeletonBox(
            width: double.infinity,
            height: 96,
            borderRadius: SkotiqTokens.radiusLg,
          ),
          SizedBox(height: SkotiqTokens.spaceLg),
          SkeletonBox(width: 160, height: 18),
          SizedBox(height: SkotiqTokens.spaceMd),
          SkeletonBox(
            width: double.infinity,
            height: 140,
            borderRadius: SkotiqTokens.radiusLg,
          ),
        ],
      ),
    );
  }

  Widget _buildError(WidgetRef ref, Object error) {
    return EmptyState(
      icon: LucideIcons.alertCircle,
      title: 'Could not reach the swarm',
      body: describeConstellationError(error),
      action: SkotiqButton(
        label: 'Retry',
        icon: SkotiqIcons.refresh,
        onPressed: () {
          ref.invalidate(constellationConfiguredProvider);
          ref.invalidate(constellationHubInfoProvider);
        },
      ),
    );
  }
}

/// Empty/signed-out state: explain the swarm, then a single sign-in CTA.
class _SignedOutBody extends ConsumerWidget {
  final VoidCallback onSignedIn;

  const _SignedOutBody({required this.onSignedIn});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: SkotiqTokens.screenPadding,
      children: [
        const SizedBox(height: SkotiqTokens.spaceLg),
        EmptyState(
          icon: LucideIcons.users,
          title: 'Image together, go deeper',
          body: 'Connect to a self-hosted Constellation hub to pool your '
              'integration with other imagers. You always choose what leaves '
              'your device — by default, only the additive co-add sums your '
              'atlas already keeps, never your raw subframes.',
          action: SkotiqButton(
            label: 'Connect to a hub',
            icon: LucideIcons.radioTower,
            onPressed: () => _openSignIn(context, ref),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        SkotiqPanel(
            padding: SkotiqTokens.cardPadding,
            child: Row(
              children: [
                Icon(
                  LucideIcons.shieldCheck,
                  size: SkotiqTokens.iconMd,
                  color: colors.info,
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    'LAN-only and self-hosted: there is no Skotiq cloud and '
                    'no central account. You federate directly with a hub you '
                    'or your group runs.',
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            )),
      ],
    );
  }

  Future<void> _openSignIn(BuildContext context, WidgetRef ref) async {
    final signedIn = await showConstellationSignInSheet(context);
    if (signedIn == true) onSignedIn();
  }
}

/// Connected state: hub banner, follow-the-night, shared-target browse list.
class _ConnectedBody extends ConsumerWidget {
  final VoidCallback onRefresh;

  const _ConnectedBody({required this.onRefresh});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hubAsync = ref.watch(constellationHubInfoProvider);
    final displayName =
        ref.watch(constellationDisplayNameProvider).valueOrNull ?? '';
    final suggestionsAsync = ref.watch(followTheNightProvider(-1));
    final targetsAsync = ref.watch(sharedTargetsProvider);

    return RefreshIndicator(
      onRefresh: () async {
        onRefresh();
        await ref.read(sharedTargetsProvider.future);
      },
      child: ListView(
        padding: SkotiqTokens.screenPadding,
        children: [
          hubAsync.when(
            data: (info) => info == null
                ? const SizedBox.shrink()
                : HubStatusCard(
                    info: info,
                    displayName: displayName,
                    onSignOut: onRefresh,
                  ),
            loading: () => const SkeletonBox(
              width: double.infinity,
              height: 96,
              borderRadius: SkotiqTokens.radiusLg,
            ),
            error: (error, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SkotiqBanner(
                    title: 'Hub unavailable',
                    message: describeConstellationError(error),
                    tone: BannerTone.warning),
                const SizedBox(height: SkotiqTokens.spaceMd),
                Wrap(
                  spacing: SkotiqTokens.spaceMd,
                  runSpacing: SkotiqTokens.spaceSm,
                  children: [
                    ConstellationSignOutButton(
                      onSignedOut: onRefresh,
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                    ),
                    SkotiqButton(
                      label: 'Connect to a hub',
                      icon: LucideIcons.radioTower,
                      size: ButtonSize.small,
                      onPressed: () => _reconnect(context, ref),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _FollowTheNightSection(
            suggestionsAsync: suggestionsAsync,
            onRetry: () => ref.invalidate(followTheNightProvider(-1)),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: SectionHeader(
                  title: 'Shared targets',
                  subtitle: 'Community fields the swarm is deepening together',
                ),
              ),
              if (ref.watch(isConstellationHostActionEnabledProvider)) ...[
                const SizedBox(width: SkotiqTokens.spaceMd),
                SkotiqButton(
                  label: 'Share a target',
                  icon: LucideIcons.globe2,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () => _shareTarget(context, ref),
                ),
              ],
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _SharedTargetsSection(
            targetsAsync: targetsAsync,
            onShare: ref.watch(isConstellationHostActionEnabledProvider)
                ? () => _shareTarget(context, ref)
                : null,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
        ],
      ),
    );
  }

  Future<void> _reconnect(BuildContext context, WidgetRef ref) async {
    final signedIn = await showConstellationSignInSheet(context);
    if (signedIn == true) onRefresh();
  }

  Future<void> _shareTarget(BuildContext context, WidgetRef ref) async {
    final navigator = Navigator.of(context);
    final target = await showShareTargetSheet(context);
    if (target == null) return;
    ref.invalidate(sharedTargetsProvider);
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => SharedTargetDetailScreen(target: target),
        ),
      ),
    );
  }
}

class _FollowTheNightSection extends StatelessWidget {
  final AsyncValue<List<FollowTheNightSuggestion>> suggestionsAsync;
  final VoidCallback onRetry;

  const _FollowTheNightSection({
    required this.suggestionsAsync,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return suggestionsAsync.when(
      data: (suggestions) {
        if (suggestions.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Follow the night',
              subtitle: 'Where it is darkest for you and the swarm needs depth',
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            for (final s in suggestions)
              Padding(
                padding: const EdgeInsets.only(
                  bottom: SkotiqTokens.spaceMd,
                ),
                child: _FollowTheNightCardWired(suggestion: s),
              ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (error, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: 'Follow the night',
            subtitle: 'Where it is darkest for you and the swarm needs depth',
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqBanner(
              title: 'Could not check tonight\'s handoffs',
              message: describeConstellationError(error),
              tone: BannerTone.warning),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: 'Retry handoffs',
              icon: SkotiqIcons.refresh,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: onRetry,
            ),
          ),
        ],
      ),
    );
  }
}

/// Wires a follow-the-night card's Claim button to the service, with local
/// in-flight state so the button shows a spinner and disables while claiming.
class _FollowTheNightCardWired extends ConsumerStatefulWidget {
  final FollowTheNightSuggestion suggestion;

  const _FollowTheNightCardWired({required this.suggestion});

  @override
  ConsumerState<_FollowTheNightCardWired> createState() =>
      _FollowTheNightCardWiredState();
}

class _FollowTheNightCardWiredState
    extends ConsumerState<_FollowTheNightCardWired> {
  bool _claiming = false;
  bool _releasing = false;
  bool _planning = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    return FollowTheNightCard(
      suggestion: s,
      claiming: _claiming,
      onClaim: s.isReadyNow ? _claim : null,
      releasing: _releasing,
      onRelease: s.heldByMe ? _release : null,
      planning: _planning,
      onPlanTonight: _planTonight,
    );
  }

  Future<void> _release() async {
    setState(() => _releasing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(constellationServiceProvider)
          .releaseHandoff(widget.suggestion.targetId);
      if (!mounted) return;
      ref.invalidate(followTheNightProvider(-1));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Released the baton for ${widget.suggestion.targetName} back to '
            'the swarm.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeConstellationError(error))),
      );
    } finally {
      if (mounted) setState(() => _releasing = false);
    }
  }

  Future<void> _planTonight() async {
    setState(() => _planning = true);
    final messenger = ScaffoldMessenger.of(context);
    final s = widget.suggestion;
    try {
      // Host-aware: on a slave this resolves/creates the target on the MASTER's
      // library via the NetworkBackend; on the host it writes the local table.
      // RA is stored in decimal hours, the suggestion carries degrees.
      await ref.read(targetLibraryServiceProvider).ensureCatalogTarget(
            targetName: s.targetName,
            raHours: s.raDeg / 15.0,
            decDegrees: s.decDeg,
          );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${s.targetName} is queued in your planner — open Planning to '
            'schedule it tonight.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeConstellationError(error))),
      );
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  Future<void> _claim() async {
    setState(() => _claiming = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final claim = await ref
          .read(constellationServiceProvider)
          .claimHandoff(widget.suggestion.targetId);
      if (!mounted) return;
      ref.invalidate(followTheNightProvider(-1));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            claim?.claimToken != null
                ? 'You hold the baton for ${widget.suggestion.targetName}. '
                    'Image it tonight.'
                : 'Claim requested for ${widget.suggestion.targetName}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeConstellationError(error))),
      );
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }
}

class _SharedTargetsSection extends StatelessWidget {
  final AsyncValue<List<SharedTarget>> targetsAsync;

  /// Opens the "Share one of my targets" flow; null on a slave (the action is
  /// host-only), in which case the empty hint stays informational.
  final VoidCallback? onShare;

  const _SharedTargetsSection({required this.targetsAsync, this.onShare});

  @override
  Widget build(BuildContext context) {
    return targetsAsync.when(
      data: (targets) {
        if (targets.isEmpty) {
          return SkotiqPanel(
              padding: SkotiqTokens.cardPadding,
              child: _EmptySwarmHint(onShare: onShare));
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 1100
                ? 3
                : constraints.maxWidth >= SkotiqTokens.breakpointTablet
                    ? 2
                    : 1;
            return _SharedTargetGrid(targets: targets, columns: columns);
          },
        );
      },
      loading: () => const ShimmerLoading(
        child: Column(
          children: [
            SkeletonBox(
              width: double.infinity,
              height: 160,
              borderRadius: SkotiqTokens.radiusLg,
            ),
            SizedBox(height: SkotiqTokens.spaceMd),
            SkeletonBox(
              width: double.infinity,
              height: 160,
              borderRadius: SkotiqTokens.radiusLg,
            ),
          ],
        ),
      ),
      error: (error, _) => SkotiqBanner(
          title: 'Could not list shared targets',
          message: describeConstellationError(error),
          tone: BannerTone.warning),
    );
  }
}

class _EmptySwarmHint extends StatelessWidget {
  /// Opens the "Share one of my targets" flow; null on a slave where seeding is
  /// host-only (the hint then just explains, with no dead button).
  final VoidCallback? onShare;

  const _EmptySwarmHint({this.onShare});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.globe2,
                size: SkotiqTokens.iconMd, color: colors.info),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Text(
                onShare != null
                    ? 'No shared targets on this hub yet. Share one of your '
                        'imaged targets to seed the first field the whole swarm '
                        'can deepen.'
                    : 'No shared targets on this hub yet. Seeding a field runs '
                        'on your imaging host — share a target from there to '
                        'start the swarm.',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
        if (onShare != null) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: 'Share one of my targets',
              icon: LucideIcons.globe2,
              size: ButtonSize.small,
              onPressed: onShare,
            ),
          ),
        ],
      ],
    );
  }
}

/// Responsive grid mirroring the Your Sky region grid: intrinsic-height cards in
/// 1/2/3 columns so the contribution bars never clip.
class _SharedTargetGrid extends StatelessWidget {
  final List<SharedTarget> targets;
  final int columns;

  const _SharedTargetGrid({required this.targets, required this.columns});

  @override
  Widget build(BuildContext context) {
    if (columns <= 1) {
      return Column(
        children: [
          for (final t in targets)
            Padding(
              padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
              child: SharedTargetCard(
                target: t,
                onTap: () => _open(context, t),
              ),
            ),
        ],
      );
    }
    final rows = <Widget>[];
    for (var i = 0; i < targets.length; i += columns) {
      final rowChildren = <Widget>[];
      for (var c = 0; c < columns; c++) {
        final index = i + c;
        if (c > 0) {
          rowChildren.add(const SizedBox(width: SkotiqTokens.spaceMd));
        }
        rowChildren.add(
          Expanded(
            child: index < targets.length
                ? SharedTargetCard(
                    target: targets[index],
                    onTap: () => _open(context, targets[index]),
                  )
                : const SizedBox.shrink(),
          ),
        );
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rowChildren,
            ),
          ),
        ),
      );
    }
    return Column(children: rows);
  }

  void _open(BuildContext context, SharedTarget target) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SharedTargetDetailScreen(target: target),
      ),
    );
  }
}
