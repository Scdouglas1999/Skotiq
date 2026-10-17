import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../constellation/constellation_format.dart';
import '../mosaic/mosaic_project_screen.dart';
import '../your_sky/sky_atlas_format.dart';
import 'collaborative_sky_format.dart';
import 'collaborative_sky_providers.dart';

/// The per-panel detail for one collaborative mosaic: the claimable panel
/// grid, who has claimed/uploaded each panel (the attribution that credits every
/// contributor on the finished mosaic), and the live combined progress as panels
/// land. A participant can JOIN the mosaic here — linking it to a local project
/// — then claim + capture panels from that project's screen.
class CollabMosaicDetailScreen extends ConsumerStatefulWidget {
  final String mosaicId;
  final String mosaicName;

  const CollabMosaicDetailScreen({
    super.key,
    required this.mosaicId,
    required this.mosaicName,
  });

  @override
  ConsumerState<CollabMosaicDetailScreen> createState() =>
      _CollabMosaicDetailScreenState();
}

class _CollabMosaicDetailScreenState
    extends ConsumerState<CollabMosaicDetailScreen> {
  /// The shell route this page was opened over.
  ///
  /// This page is pushed imperatively onto the ROOT navigator, above the
  /// AppShell's ShellRoute child, so a nav-rail tap (`context.go`) swaps the
  /// page *underneath* it and the operator is left staring at a mosaic while
  /// the rail insists they are on the Dashboard — with no back control and no
  /// keyboard escape. Dismiss ourselves when the shell navigates away so the
  /// pushed route can never outlive the screen it was opened from.
  String? _openedAtLocation;
  GoRouter? _router;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // maybeOf, not of: this page can legitimately be pushed by something that
    // is not under a GoRouter (tests, an embedded preview), and asserting there
    // would turn a nav nicety into a crash.
    final router = GoRouter.maybeOf(context);
    if (router == null || identical(router, _router)) return;
    _router?.routeInformationProvider.removeListener(_onShellNavigated);
    _router = router;
    _openedAtLocation = _currentLocation(router);
    router.routeInformationProvider.addListener(_onShellNavigated);
  }

  @override
  void dispose() {
    _router?.routeInformationProvider.removeListener(_onShellNavigated);
    super.dispose();
  }

  static String _currentLocation(GoRouter router) =>
      router.routeInformationProvider.value.uri.toString();

  void _onShellNavigated() {
    final router = _router;
    if (router == null || !mounted) return;
    if (_currentLocation(router) == _openedAtLocation) return;
    // Popping from inside a router notification would mutate the navigator
    // mid-notification; do it once the frame settles.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    });
  }

  void _back() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    // A deep link that left nothing beneath us still needs a way out.
    _router?.go('/planner?tab=discover&view=collaborative');
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final mosaicId = widget.mosaicId;
    final mosaicName = widget.mosaicName;
    final detailAsync = ref.watch(collaborativeMosaicDetailProvider(mosaicId));

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // One header. The route is PUSHED, so the back affordance has to
            // live on it; PageHeader has no leading slot, so it is the first
            // action, next to refresh.
            PageHeader(
              icon: LucideIcons.grid,
              title: mosaicName.isEmpty ? 'Mosaic' : mosaicName,
              context: 'Collaborative mosaic',
              actions: [
                SkotiqIconButton(
                  icon: SkotiqIcons.chevronLeft,
                  tooltip: 'Back to Collaborate',
                  onPressed: _back,
                ),
                SkotiqIconButton(
                  icon: SkotiqIcons.refresh,
                  tooltip: 'Refresh',
                  onPressed: () => ref
                      .invalidate(collaborativeMosaicDetailProvider(mosaicId)),
                ),
              ],
            ),
            Expanded(
              child: detailAsync.when(
                data: (mosaic) => _Body(mosaic: mosaic),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => EmptyState(
                  icon: LucideIcons.alertCircle,
                  title: 'Could not load the mosaic',
                  body: describeConstellationError(error),
                  action: SkotiqButton(
                    label: 'Retry',
                    icon: SkotiqIcons.refresh,
                    onPressed: () => ref.invalidate(
                      collaborativeMosaicDetailProvider(mosaicId),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final CollabMosaic mosaic;

  const _Body({required this.mosaic});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final total = mosaic.panels.isNotEmpty
        ? mosaic.panels.length
        : mosaic.rows * mosaic.cols;
    final uploaded = mosaic.isComplete
        ? total
        : mosaic.panels.where((p) => p.uploaded).length;
    // Credit contributors from the hub's authoritative `/v1/attribution` list
    // — the consent-aware source — rather than reconstructing them from the
    // owner + per-panel names; falls back to the embedded names until it
    // resolves.
    final attribution = ref
        .watch(collaborativeMosaicAttributionProvider(mosaic.mosaicId))
        .valueOrNull;
    final credits = mosaicContributorCredits(mosaic, attribution: attribution);

    return ListView(
      padding: SkotiqTokens.screenPadding,
      children: [
        SkotiqPanel(
            padding: SkotiqTokens.cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Combined progress',
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                SkotiqProgressBar(
                  value: mosaicCompletionFraction(
                      uploaded: uploaded, total: total),
                  state: mosaic.isComplete
                      ? SkotiqProgressState.success
                      : SkotiqProgressState.normal,
                  indeterminate: mosaic.isAssembling,
                  showPercentage: true,
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  mosaic.isAssembling
                      ? 'All panels in — the owner is stitching the mosaic'
                      : '${formatPanelProgress(uploaded: uploaded, total: total)} '
                          '· ${formatMosaicStatus(mosaic.status)}',
                  style: SkotiqTypography.captionSm.copyWith(
                    color: colors.textSecondary,
                  ),
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
                        'Contributors: $credits',
                        style: SkotiqTypography.captionSm.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            )),
        if (!mosaic.isComplete) ...[
          const SizedBox(height: SkotiqTokens.spaceLg),
          _JoinMosaicButton(mosaic: mosaic),
        ],
        const SizedBox(height: SkotiqTokens.spaceLg),
        const SectionHeader(
          title: 'Panels',
          subtitle: 'Each panel is a claimable work item across the club',
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        if (mosaic.panels.isEmpty)
          SkotiqPanel(
              padding: SkotiqTokens.cardPadding,
              child: Text(
                'This mosaic has ${mosaic.rows * mosaic.cols} panels. Panel '
                'detail loads once the owner publishes the grid.',
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ))
        else
          for (final panel in mosaic.panels)
            Padding(
              padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
              child: _PanelRow(panel: panel),
            ),
        const SizedBox(height: SkotiqTokens.spaceLg),
      ],
    );
  }
}

/// Wires the participant JOIN flow: link this hub mosaic to a (new or existing)
/// local [MosaicProject] via [CollaborativeMosaicService.joinMosaicAsParticipant]
/// — mirroring the hub grid into a durable project — then route to the mosaic
/// project screen so the rig can claim panels and capture. In-flight state
/// disables the button + shows a spinner, mirroring `_JoinSessionButton`;
/// failures surface a snackbar via [describeConstellationError].
class _JoinMosaicButton extends ConsumerStatefulWidget {
  final CollabMosaic mosaic;

  const _JoinMosaicButton({required this.mosaic});

  @override
  ConsumerState<_JoinMosaicButton> createState() => _JoinMosaicButtonState();
}

class _JoinMosaicButtonState extends ConsumerState<_JoinMosaicButton> {
  bool _joining = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final backend = ref.watch(backendProvider);
    final isRemote = backend is NetworkBackend;
    final canJoin =
        backend is! NetworkBackend && backend is! DisconnectedBackend;
    // A mosaic this rig already published or joined has a local project behind
    // it. Telling its OWNER to "Join this mosaic" — and describing their own
    // project as something to be mirrored in — reads as a different mosaic than
    // the one they are looking at.
    final local = ref
        .watch(localMosaicProjectForHubProvider(widget.mosaic.mosaicId))
        .valueOrNull;
    final isOwner = local?.collabRole == 'owner';
    final alreadyLinked = local?.id != null;

    final String title;
    final String body;
    final String label;
    final IconData icon;
    if (isOwner) {
      title = 'Your mosaic';
      body = 'You published this mosaic. Open its local project to claim '
          'panels, watch the club fill the rest, and assemble the result.';
      label = 'Open the local project';
      icon = LucideIcons.grid;
    } else if (alreadyLinked) {
      title = 'Image with this club';
      body = "You've joined this mosaic. Open its local project to claim open "
          'panels and capture them on your rig.';
      label = 'Open the local project';
      icon = LucideIcons.grid;
    } else {
      title = 'Image with this club';
      body = isRemote
          ? 'Join this mosaic on the imaging host, where its local project, '
              'captured panels, and masters are stored.'
          : canJoin
              ? 'Join this mosaic to mirror its panel grid into a local '
                  'project, then claim open panels and capture them on your rig.'
              : 'Connect to the imaging host that will own this mosaic '
                  'project before joining.';
      label = isRemote
          ? 'Join from imaging host'
          : canJoin
              ? 'Join mosaic'
              : 'Connect to join';
      icon = LucideIcons.userPlus;
    }

    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: SkotiqTypography.labelStrong.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceXs),
            Text(
              body,
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label: label,
                icon: icon,
                isLoading: _joining,
                onPressed: _joining || !canJoin ? null : _join,
              ),
            ),
          ],
        ));
  }

  Future<void> _join() async {
    final authority = ref.read(backendProvider);
    if (authority is NetworkBackend || authority is DisconnectedBackend) {
      return;
    }
    setState(() => _joining = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // Whether this is a real join or just a route into an existing local
    // project — `joinMosaicAsParticipant` returns the existing id untouched, so
    // only a genuinely new link should announce one.
    final wasLinked = ref
            .read(localMosaicProjectForHubProvider(widget.mosaic.mosaicId))
            .valueOrNull
            ?.id !=
        null;
    try {
      final projectId = await ref
          .read(collaborativeMosaicServiceProvider)
          .joinMosaicAsParticipant(widget.mosaic);
      if (!mounted || !identical(ref.read(backendProvider), authority)) return;
      // Joining takes a participant slot on the hub, so every cached listing of
      // this mosaic is now stale.
      invalidateCollaborativeMosaicStateFor(ref);
      if (!wasLinked) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Joined '
              '${widget.mosaic.name.isEmpty ? 'mosaic' : widget.mosaic.name}'
              ' — claim open panels to contribute.',
            ),
          ),
        );
      }
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => MosaicProjectScreen(projectId: projectId),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeConstellationError(error))),
      );
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }
}

class _PanelRow extends StatelessWidget {
  final CollabMosaicPanel panel;

  const _PanelRow({required this.panel});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final credit = (panel.assignedDisplayName ?? '').trim();

    return SkotiqPanel(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceLg,
          vertical: SkotiqTokens.spaceMd,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: SkotiqDecorations.chip(colors, tone: colors.primary),
              child: Text(
                '${panel.panelIndex + 1}',
                style: SkotiqTypography.labelStrongSm.copyWith(
                  color: colors.primary,
                ),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    formatCenter(panel.centerRaDeg, panel.centerDecDeg),
                    style: SkotiqTypography.captionSm.copyWith(
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (credit.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      credit,
                      style: SkotiqTypography.captionSm.copyWith(
                        color: colors.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            StatusPill(
              icon: _panelIcon(panel.status),
              label: '',
              value: _panelLabel(panel.status),
              status: _panelVariant(panel.status),
            ),
          ],
        ));
  }

  IconData _panelIcon(String status) {
    switch (status) {
      case 'uploaded':
        return LucideIcons.checkCircle2;
      case 'claimed':
        return LucideIcons.user;
      default:
        return LucideIcons.circleDashed;
    }
  }

  String _panelLabel(String status) {
    switch (status) {
      case 'uploaded':
        return 'Uploaded';
      case 'claimed':
        return 'Claimed';
      default:
        return 'Open';
    }
  }

  StatusPillStatus _panelVariant(String status) {
    switch (status) {
      case 'uploaded':
        return StatusPillStatus.success;
      case 'claimed':
        return StatusPillStatus.active;
      default:
        return StatusPillStatus.inactive;
    }
  }
}
