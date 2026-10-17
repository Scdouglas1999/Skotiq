import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../constellation/constellation_format.dart';
import '../constellation/constellation_sign_in_sheet.dart';
import '../constellation/constellation_ui_providers.dart';
import '../constellation/widgets/hub_status_card.dart';
import 'coimaging_create_sheet.dart';
import 'collab_mosaic_detail_screen.dart';
import 'collaborative_sky_providers.dart';
import 'widgets/coimaging_session_card.dart';
import 'widgets/collab_mosaic_card.dart';
import 'widgets/shared_library_card.dart';

/// Collaborative Sky (6.0 pillar) — the unified surface that turns the
/// Constellation swarm into real distributed imaging: live co-imaging sessions
/// (pool integration on one target across rigs and longitudes), collaborative
/// mosaics (split a panel grid across a club), and the shared calibration
/// library (never shoot the same dark twice).
///
/// It reuses the SAME self-hosted hub credentials Pillar C resolves, so signing
/// in here and on the Constellation screen are one and the same. Reads
/// exclusively through core providers, so it works unchanged on the desktop FFI
/// backend and the mobile network backend.
///
/// Scaffold-free body so the surface can be embedded — it renders inside the
/// Plan Tonight → Discover tab (the `/collaborative-sky` deep link redirects
/// there). There is no standalone page wrapper: the Discover tab is the surface.
class CollaborativeSkyView extends ConsumerWidget {
  const CollaborativeSkyView({super.key});

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
            loading: _buildLoading,
            error: (error, _) => _buildError(ref, error),
          ),
        ),
      ],
    );
  }

  void _refresh(WidgetRef ref) => refreshCollaborativeSky(ref);

  /// Re-reads everything the collaborative view shows.
  ///
  /// Public because the view no longer carries a header of its own: the Plan
  /// screen's "Your sky" tab owns the one refresh button for all three
  /// discovery surfaces (06 §Plan removes the second header row).
  static void refreshCollaborativeSky(WidgetRef ref) {
    ref.invalidate(constellationConfiguredProvider);
    ref.invalidate(constellationHubInfoProvider);
    ref.invalidate(coImagingSessionsProvider);
    ref.invalidate(coImagingMembershipsProvider);
    invalidateCollaborativeMosaicStateFor(ref);
    ref.invalidate(sharedLibrarySummaryProvider);
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
          SkeletonBox(width: 180, height: 18),
          SizedBox(height: SkotiqTokens.spaceMd),
          SkeletonBox(
            width: double.infinity,
            height: 160,
            borderRadius: SkotiqTokens.radiusLg,
          ),
        ],
      ),
    );
  }

  Widget _buildError(WidgetRef ref, Object error) {
    return EmptyState(
      icon: LucideIcons.alertCircle,
      title: 'Could not reach the hub',
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

/// Empty/signed-out state: explain Collaborative Sky, then a single connect CTA
/// (the same self-hosted hub the Constellation swarm signs into).
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
          title: 'Image the sky together',
          body: 'Connect to a self-hosted hub to co-image faint targets with '
              'other rigs across longitudes, split mosaics across your club, '
              'and pull sensor-matched calibration masters a member already '
              'shot. You always choose what leaves your device.',
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
                    'LAN-only and self-hosted: every shared artifact carries '
                    'provenance and consent, and scoped roles enforce '
                    'contribute-vs-admin. There is no Skotiq cloud.',
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

/// Connected state: hub banner, then the three collaborative flows.
class _ConnectedBody extends ConsumerWidget {
  final VoidCallback onRefresh;

  const _ConnectedBody({required this.onRefresh});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hubAsync = ref.watch(constellationHubInfoProvider);
    final displayName =
        ref.watch(constellationDisplayNameProvider).valueOrNull ?? '';

    return RefreshIndicator(
      onRefresh: () async {
        onRefresh();
        await ref.read(coImagingSessionsProvider.future);
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
          const _CoImagingSection(),
          const SizedBox(height: SkotiqTokens.spaceLg),
          const _MosaicsSection(),
          const SizedBox(height: SkotiqTokens.spaceLg),
          const _SharedLibrarySection(),
          const SizedBox(height: SkotiqTokens.spaceLg),
        ],
      ),
    );
  }

  Future<void> _reconnect(BuildContext context, WidgetRef ref) async {
    final signedIn = await showConstellationSignInSheet(context);
    if (signedIn == true) onRefresh();
  }
}

/// Live co-imaging sessions — N rigs deepening one
/// target together, right now. Owns the "Start session" affordance (the anchor
/// side of co-imaging) alongside the browse list.
class _CoImagingSection extends ConsumerStatefulWidget {
  const _CoImagingSection();

  @override
  ConsumerState<_CoImagingSection> createState() => _CoImagingSectionState();
}

class _CoImagingSectionState extends ConsumerState<_CoImagingSection> {
  bool _starting = false;

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(coImagingSessionsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Live co-imaging',
          subtitle: 'Pool integration on one target across rigs and longitudes',
          trailing: SkotiqButton(
            label: _starting ? 'Starting…' : 'Start session',
            icon: LucideIcons.plus,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            isLoading: _starting,
            onPressed: _starting ? null : _startSession,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        sessionsAsync.when(
          data: (sessions) {
            if (sessions.isEmpty) {
              return const _EmptySectionHint(
                icon: LucideIcons.radio,
                message: 'No live sessions on this hub yet. Use Start session '
                    'above to open one on a target and deepen it together '
                    'across the night.',
              );
            }
            return Column(
              children: [
                for (final session in sessions)
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: SkotiqTokens.spaceMd,
                    ),
                    child: _CoImagingCardWired(session: session),
                  ),
              ],
            );
          },
          loading: () => const _SectionSkeleton(),
          error: (error, _) => SkotiqBanner(
              title: 'Could not list co-imaging sessions',
              message: describeConstellationError(error),
              tone: BannerTone.warning),
        ),
      ],
    );
  }

  Future<void> _startSession() async {
    if (_starting) return;
    setState(() => _starting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Prefill from the current framing aim when one is set, so "start a
      // session on what I'm looking at" is one tap; the sheet stays fully
      // editable and works with no framing target too. The effective aim (not
      // the view-center target) carries where the reticle — and therefore the
      // telescope — will actually point when the FOV box was dragged.
      final framingTarget = ref.read(framingProvider).effectiveAimTarget;
      final session = await showCoImagingCreateSheet(
        context,
        initialTargetName: framingTarget?.name,
        initialRaDeg: framingTarget?.raDegrees,
        initialDecDeg: framingTarget?.decDegrees,
      );
      if (session == null || !mounted) return;
      // The creator is the anchor participant, so their subs need the SAME
      // unattended-contribution consent the join flow requires before we can
      // promise a co-add — route them through it and word the confirmation by
      // the outcome.
      final sharing = await ensureCoImagingSharingConsent(context, ref);
      if (sharing == null) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            sharing
                ? 'Started ${session.targetName} — your subs co-add into the '
                    'combined stack.'
                : 'Started ${session.targetName}. Sharing is off, so your subs '
                    'will not be added to the combined stack until you enable '
                    'unattended contribution.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}

/// Wires a co-imaging card's Join button to the session service, with local
/// in-flight state so the button shows a spinner and disables while joining.
class _CoImagingCardWired extends ConsumerStatefulWidget {
  final CoImagingSession session;

  const _CoImagingCardWired({required this.session});

  @override
  ConsumerState<_CoImagingCardWired> createState() =>
      _CoImagingCardWiredState();
}

class _CoImagingCardWiredState extends ConsumerState<_CoImagingCardWired> {
  bool _joining = false;
  bool _leaving = false;
  bool _ending = false;

  @override
  Widget build(BuildContext context) {
    // Owner-only "End session": the hub emits ownerAccountId only to a
    // privileged caller (owner / participant), so a non-empty match against
    // this rig's own account id uniquely identifies the anchor. A non-owner
    // participant sees the owner's id here, which never equals their own.
    final myAccountId = ref.watch(constellationAccountIdProvider).valueOrNull;
    final isOwner = myAccountId != null &&
        myAccountId.isNotEmpty &&
        widget.session.ownerAccountId == myAccountId;
    final membershipsAsync = ref.watch(coImagingMembershipsProvider);
    final memberships = membershipsAsync.isLoading || membershipsAsync.hasError
        ? null
        : membershipsAsync.valueOrNull;
    final bool? joined = memberships
        ?.any((membership) => membership.sessionId == widget.session.sessionId);
    final membershipErrorMessage = membershipsAsync.hasError
        ? describeConstellationError(membershipsAsync.error!)
        : null;
    // Subscribe to the live combined-preview channel only while the session is
    // still live, so the SSE connection is opened for the "we're building this
    // together, right now" moment and never for a closed session. The stream
    // emits a snapshot then one event per contribution / join, deepening the
    // card's combined totals in real time.
    final livePreview = widget.session.isActive
        ? ref
            .watch(coImagingPreviewProvider(widget.session.sessionId))
            .valueOrNull
        : null;
    // Credit rigs from the hub's authoritative, consent-aware attribution
    // rather than the raw participant roster; the card falls back to the roster
    // names until this resolves.
    final attribution = ref
        .watch(coImagingAttributionProvider(widget.session.sessionId))
        .valueOrNull;
    // Membership alone does not mean a sub ever leaves this device: the
    // auto-contribute egress fails closed without an unattended consent record.
    final contributing = ref.watch(coImagingSharingEnabledProvider).valueOrNull;
    return CoImagingSessionCard(
      session: widget.session,
      livePreview: livePreview,
      attribution: attribution,
      joined: joined,
      contributing: joined == true ? contributing : null,
      onEnableSharing:
          joined == true && contributing == false ? _enableSharing : null,
      membershipErrorMessage: membershipErrorMessage,
      onRetryMembership: membershipErrorMessage == null
          ? null
          : () => ref.invalidate(coImagingMembershipsProvider),
      joining: _joining,
      leaving: _leaving,
      onJoin:
          joined == false && !_joining && !_leaving && !_ending ? _join : null,
      onLeave:
          joined == true && !_joining && !_leaving && !_ending ? _leave : null,
      onEndSession:
          isOwner && widget.session.isActive && !_ending ? _endSession : null,
      endingSession: _ending,
    );
  }

  Future<void> _join() async {
    if (_joining || _leaving || _authoritativeJoinedState() != false) return;
    setState(() => _joining = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final participant =
          await ref.read(coImagingSessionServiceProvider).joinSession(
                widget.session.sessionId,
                // Carry the session's sky centre into the durable membership so the
                // framing-offset slew (RA scaled by cos(dec)) and the altitude baton
                // tick work offline without a follow-up round-trip.
                targetName: widget.session.targetName,
                targetRaDeg: widget.session.centerRaDeg,
                targetDecDeg: widget.session.centerDecDeg,
              );
      if (!mounted) return;
      ref.invalidate(coImagingMembershipsProvider);
      ref.invalidate(coImagingSessionsProvider);

      // Joining points the mount at a framing slot, but a completed sub only
      // co-adds into the combined stack when the operator has an UNATTENDED
      // contribution consent on record — the same MosaicUploadConsent the
      // mosaic path persists, with the auto-upload opt-in enabled, because the
      // co-imaging auto-contribute egress is inherently unattended (it fails
      // closed on a missing consent or autoUpload==false). Without it the fold
      // silently grows nothing, so route the user to grant it now and only
      // promise the co-add once sharing is actually enabled. The create flow
      // shares this exact gate (see [ensureCoImagingSharingConsent]).
      final sharing = await ensureCoImagingSharingConsent(context, ref);
      if (sharing == null) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            sharing
                ? 'Joined ${widget.session.targetName} at framing slot '
                    '${participant.framingOffsetIndex} — your subs co-add into '
                    'the combined stack.'
                : 'Joined ${widget.session.targetName} at framing slot '
                    '${participant.framingOffsetIndex}. Sharing is off, so your '
                    'subs will not be added to the combined stack until you '
                    'enable unattended contribution.',
          ),
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

  Future<void> _enableSharing() async {
    final sharing = await ensureCoImagingSharingConsent(context, ref);
    if (sharing == null || !mounted) return;
    ref.invalidate(coImagingSharingEnabledProvider);
  }

  Future<void> _leave() async {
    if (_joining || _leaving || _authoritativeJoinedState() != true) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave this session?'),
        content: Text(
          'Your rig stops pooling light into ${widget.session.targetName} and '
          'leaves the live pool. Subs you already contributed stay in the '
          'combined stack; you can rejoin later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_joining || _leaving || _authoritativeJoinedState() != true) return;
    setState(() => _leaving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(coImagingSessionServiceProvider)
          .leaveSession(widget.session.sessionId);
      if (!mounted) return;
      ref.invalidate(coImagingMembershipsProvider);
      ref.invalidate(coImagingSessionsProvider);
      messenger.showSnackBar(
        SnackBar(content: Text('Left ${widget.session.targetName}.')),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeConstellationError(error))),
      );
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  /// Close this session as its owner: confirm (destructive) then flip it to
  /// closed on the hub. The pooled combined stack survives on the hub; only the
  /// LIVE pool ends, so no further subs can co-add.
  Future<void> _endSession() async {
    if (_joining || _leaving || _ending) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('End this session?'),
        content: Text(
          'Closing ${widget.session.targetName} shuts the live pool for every '
          'rig, so no more subs can co-add. The combined stack you have built '
          'together stays on the hub — only the live session ends.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          SkotiqButton(
            label: 'End session',
            variant: ButtonVariant.destructive,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_joining || _leaving || _ending) return;
    setState(() => _ending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(coImagingSessionServiceProvider)
          .closeSession(widget.session.sessionId);
      if (!mounted) return;
      ref.invalidate(coImagingSessionsProvider);
      ref.invalidate(coImagingMembershipsProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Ended ${widget.session.targetName}. The combined stack stays on '
            'the hub.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeConstellationError(error))),
      );
    } finally {
      if (mounted) setState(() => _ending = false);
    }
  }

  /// Returns the last successfully loaded durable membership state for this
  /// session. Loading and error states remain unknown and cannot authorize a
  /// mutation, even if Riverpod retains an older value during a refresh.
  bool? _authoritativeJoinedState() {
    final membershipsAsync = ref.read(coImagingMembershipsProvider);
    if (membershipsAsync.isLoading || membershipsAsync.hasError) return null;
    final memberships = membershipsAsync.valueOrNull;
    if (memberships == null) return null;
    return memberships.any(
      (membership) => membership.sessionId == widget.session.sessionId,
    );
  }
}

/// Collaborative mosaics — split a panel grid across a club, fuse centrally.
class _MosaicsSection extends ConsumerWidget {
  const _MosaicsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mosaicsAsync = ref.watch(collaborativeMosaicsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Collaborative mosaics',
          subtitle: 'Split a mosaic across rigs and get one fused result',
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        mosaicsAsync.when(
          data: (mosaics) {
            if (mosaics.isEmpty) {
              return const _EmptySectionHint(
                icon: LucideIcons.grid,
                message: 'No collaborative mosaics on this hub yet. Publish a '
                    'mosaic project from its planner to split the panels across '
                    'your club.',
              );
            }
            return Column(
              children: [
                for (final mosaic in mosaics)
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: SkotiqTokens.spaceMd,
                    ),
                    child: _MosaicCardWired(summary: mosaic),
                  ),
              ],
            );
          },
          loading: () => const _SectionSkeleton(),
          error: (error, _) => SkotiqBanner(
              title: 'Could not list collaborative mosaics',
              message: describeConstellationError(error),
              tone: BannerTone.warning),
        ),
      ],
    );
  }
}

/// Backs a mosaic card with its detail (the list payload omits panels) so the
/// combined progress + per-panel attribution are real, falling back to the list
/// summary while the detail loads.
class _MosaicCardWired extends ConsumerWidget {
  final CollabMosaic summary;

  const _MosaicCardWired({required this.summary});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref
        .watch(collaborativeMosaicDetailProvider(summary.mosaicId))
        .valueOrNull;
    // Credit contributors from the hub's authoritative attribution rather than
    // reconstructing them from the browse payload; the card falls back to the
    // embedded names until this resolves.
    final attribution = ref
        .watch(collaborativeMosaicAttributionProvider(summary.mosaicId))
        .valueOrNull;
    return CollabMosaicCard(
      mosaic: detail ?? summary,
      attribution: attribution,
      onView: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CollabMosaicDetailScreen(
            mosaicId: summary.mosaicId,
            mosaicName: summary.name,
          ),
        ),
      ),
    );
  }
}

/// Shared calibration library — never shoot the same dark twice.
class _SharedLibrarySection extends ConsumerWidget {
  const _SharedLibrarySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(sharedLibrarySummaryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Shared calibration',
          subtitle: 'Pull a sensor-matched master instead of re-shooting',
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        summaryAsync.when(
          data: (summary) => SharedLibraryCard(
            summary: summary,
            onOpen: () => _openLibrary(context),
          ),
          loading: () => const _SectionSkeleton(),
          error: (error, _) => SkotiqBanner(
              title: 'Could not read the calibration library',
              message: describeConstellationError(error),
              tone: BannerTone.warning),
        ),
      ],
    );
  }

  void _openLibrary(BuildContext context) {
    // The shared library is matched, pulled, and published from the calibration
    // library in Settings. Guarded so a standalone mount (tests) is a no-op.
    final router = GoRouter.maybeOf(context);
    router?.go('/settings?section=calibration-library');
  }
}

/// A subtle informational hint for an empty collaborative section (no dead
/// buttons — seeding each flow lives in its owning surface).
class _EmptySectionHint extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptySectionHint({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Row(
          children: [
            Icon(icon, size: SkotiqTokens.iconMd, color: colors.info),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Text(
                message,
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ));
  }
}

class _SectionSkeleton extends StatelessWidget {
  const _SectionSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ShimmerLoading(
      child: SkeletonBox(
        width: double.infinity,
        height: 160,
        borderRadius: SkotiqTokens.radiusLg,
      ),
    );
  }
}
