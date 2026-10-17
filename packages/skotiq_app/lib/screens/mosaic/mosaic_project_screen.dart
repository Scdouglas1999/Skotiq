import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' show meanRaHours;
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as p;

import '../session_review/widgets/master_overlay_view.dart';
import '../session_review/widgets/master_preview_view.dart';
import 'mosaic_contribute_sheet.dart';
import 'mosaic_format.dart';
import 'mosaic_project_controller.dart';
import 'widgets/mosaic_panel_grid.dart';

/// Present the consent sheet (license + anonymity opt-in) and, if the user
/// confirms, upload either one panel ([panelIndex] set) or every
/// integrated-but-unuploaded panel under the chosen license/attribution. A
/// cancelled sheet ships nothing — no panel master leaves the device without an
/// explicit per-upload opt-in.
Future<void> _uploadMosaicWithConsent(
  BuildContext context,
  MosaicProjectController controller, {
  int? panelIndex,
}) async {
  final choice = await showMosaicContributeSheet(context);
  if (choice == null) return;
  if (panelIndex == null) {
    await controller.uploadAllIntegrated(
      license: choice.license,
      attributionConsent: choice.attributionConsent,
    );
  } else {
    await controller.uploadPanelMaster(
      panelIndex,
      license: choice.license,
      attributionConsent: choice.attributionConsent,
    );
  }
}

/// Owner-only destructive recovery: confirm before force-releasing [panelIndex]
/// back to `pending` on the hub, since it drops the panel's current claim or
/// uploaded master and cannot be undone.
Future<void> _confirmForceRelease(
  BuildContext context,
  MosaicProjectController controller,
  int panelIndex,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Force release panel?'),
      content: Text(
        'Panel ${panelIndex + 1} will be released back to pending on the hub, '
        'dropping its current claim or uploaded master. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Force release'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await controller.forceReleasePanel(panelIndex);
  }
}

/// Resolves the DURABLE per-app base directory for mosaic artifacts —
/// `<applicationSupport>/skotiq_mosaic`. Panel masters and the stitched
/// mosaic FITS/PNG land under a per-project subfolder of this so they SURVIVE
/// reboots and OS temp-dir sweeps — under `Directory.systemTemp` they can
/// vanish the moment the OS cleans temp.
///
/// Bounded: a platform channel that never answers must become a visible error
/// on the screen, not a spinner that outlives the session.
final mosaicArtifactsBaseDirProvider = FutureProvider<String>((ref) async {
  final supportDir =
      await resolveSkotiqDataDirectory().timeout(const Duration(seconds: 10));
  return p.join(supportDir.path, 'skotiq_mosaic');
});

/// The mosaic project review screen at `/mosaic/:id`.
///
/// Shows a header (name, target region, NxM grid, status), the panel grid (each
/// panel's status + captured count + a master thumbnail once integrated), the
/// two durable actions (Integrate panels / Stitch mosaic) with busy/error
/// states, and — once the project is complete — the stitched master in the
/// reused [MasterOverlayView] / [MasterPreviewView].
///
/// Design-system pure: every colour, gap, and type style comes from
/// `skotiq_ui` tokens; the stitched-master hero is the morning-report widget
/// reused verbatim.
class MosaicProjectScreen extends ConsumerStatefulWidget {
  /// The `mosaic_projects.id` to review.
  final int projectId;

  /// Overrides the DURABLE artifacts base directory panel masters and stitched
  /// output are written under. When omitted the screen resolves
  /// `<applicationSupport>/skotiq_mosaic` via
  /// [mosaicArtifactsBaseDirProvider]; tests pass a temp directory.
  ///
  /// A plain VALUE (not a builder closure) on purpose — it becomes part of the
  /// controller's family key, and a closure there re-keys the family on every
  /// rebuild (see [MosaicProjectControllerArgs]).
  final String? artifactsBaseDir;

  const MosaicProjectScreen({
    super.key,
    required this.projectId,
    this.artifactsBaseDir,
  });

  @override
  ConsumerState<MosaicProjectScreen> createState() =>
      _MosaicProjectScreenState();
}

class _MosaicProjectScreenState extends ConsumerState<MosaicProjectScreen> {
  /// The controller key this screen visit has already refreshed. The family is
  /// cached (one controller per project + artifacts dir), so re-entering the
  /// screen would otherwise render whatever the last visit loaded — panels
  /// captured or integrated in the meantime would be invisible. Exactly one
  /// re-read per visit, never a poll.
  MosaicProjectControllerArgs? _refreshedFor;

  int get projectId => widget.projectId;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    if (ref.watch(backendProvider) is NetworkBackend) {
      return _chrome(
        context,
        colors,
        child: const EmptyState(
          icon: SkotiqIcons.device,
          title: 'Open this mosaic project on the imaging host',
          body: 'Mosaic project records, panel masters, and stitched '
              'artifacts live on the imaging computer. Remote project '
              'control is unavailable in this release.',
        ),
      );
    }

    // Resolve the DURABLE artifacts base before constructing the controller, so
    // panel/stitch FITS never land in (and get swept from) the system temp dir.
    // An injected base bypasses the async resolution entirely.
    final injectedBase = widget.artifactsBaseDir;
    if (injectedBase != null) {
      return _scaffold(context, ref, colors, injectedBase);
    }

    final baseDir = ref.watch(mosaicArtifactsBaseDirProvider);
    return baseDir.when(
      loading: () => _chrome(
        context,
        colors,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
              SizedBox(height: SkotiqTokens.spaceMd),
              Text('Preparing mosaic storage…'),
            ],
          ),
        ),
      ),
      error: (e, _) => _chrome(
        context,
        colors,
        child: EmptyState(
          icon: SkotiqIcons.warning,
          title: 'Mosaic storage unavailable',
          body: 'Could not resolve a durable artifacts directory, so panel '
              'masters and the stitched mosaic have nowhere to live: $e',
          action: SkotiqButton(
            label: 'Try again',
            icon: SkotiqIcons.refresh,
            variant: ButtonVariant.secondary,
            onPressed: () => ref.invalidate(mosaicArtifactsBaseDirProvider),
          ),
        ),
      ),
      data: (base) => _scaffold(context, ref, colors, base),
    );
  }

  /// The screen shell every state shares: background, safe area, and — first —
  /// a back affordance. Whatever goes wrong below, the operator can always
  /// leave this screen instead of being stranded on it.
  Widget _chrome(
    BuildContext context,
    SkotiqColors colors, {
    required Widget child,
  }) {
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _MosaicProjectHeaderBar(),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }

  Widget _scaffold(
    BuildContext context,
    WidgetRef ref,
    SkotiqColors colors,
    String artifactsBase,
  ) {
    // VALUE-comparable family key: the same screen rebuilding must resolve the
    // SAME controller, or every frame spawns a new one (and a new load).
    final args = MosaicProjectControllerArgs(
      projectId: projectId,
      artifactsBaseDir: artifactsBase,
    );
    final state = ref.watch(mosaicProjectControllerProvider(args));
    final controller = ref.read(mosaicProjectControllerProvider(args).notifier);
    _refreshOnEntry(args);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: _body(context, colors, state, controller),
      ),
    );
  }

  /// Re-read the project ONCE per screen visit when the controller was already
  /// cached from an earlier visit (a fresh controller is loading already).
  /// Panels captured, integrated or claimed while the operator was elsewhere
  /// then show up instead of a stale snapshot.
  void _refreshOnEntry(MosaicProjectControllerArgs args) {
    if (_refreshedFor == args) return;
    _refreshedFor = args;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(mosaicProjectControllerProvider(args));
      // Only when it is showing settled data: never interrupt the first load,
      // an in-flight action, or a not-found result.
      if (state.project == null || state.isLoading || state.isBusy) return;
      unawaited(
          ref.read(mosaicProjectControllerProvider(args).notifier).load());
    });
  }

  Widget _body(
    BuildContext context,
    SkotiqColors colors,
    MosaicProjectState state,
    MosaicProjectController controller,
  ) {
    if (state.isLoading && state.project == null) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MosaicProjectHeaderBar(),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
                  SizedBox(height: SkotiqTokens.spaceMd),
                  Text('Loading mosaic project…'),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final project = state.project;
    if (project == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _MosaicProjectHeaderBar(),
          Expanded(
            child: EmptyState(
              icon: SkotiqIcons.grid,
              title: 'Mosaic project not found',
              body: state.error ?? 'No mosaic project with id $projectId.',
              action: SkotiqButton(
                label: 'Try again',
                icon: SkotiqIcons.refresh,
                variant: ButtonVariant.secondary,
                onPressed: controller.load,
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MosaicProjectHeader(project: project, state: state),
        if (state.error != null)
          _ErrorBanner(message: state.error!, onDismiss: controller.clearError),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MosaicProjectActions(state: state, controller: controller),
                if (controller.canCollaborate) ...[
                  const SizedBox(height: SkotiqTokens.spaceLg),
                  const SectionTitle(
                    icon: SkotiqIcons.share,
                    title: 'Collaborative mosaic',
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  MosaicCollaborativeSection(
                    state: state,
                    controller: controller,
                  ),
                ],
                const SizedBox(height: SkotiqTokens.spaceLg),
                const SectionTitle(
                  icon: SkotiqIcons.grid,
                  title: 'Panels',
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                MosaicPanelGrid(
                  panels: state.panels,
                  panelMasters: state.panelMasters,
                  cols: project.cols,
                  // Surface per-panel claim/upload once the project is a
                  // published collaborative mosaic and a hub service is wired.
                  collaborative: controller.canCollaborate && state.isPublished,
                  collaborativeBusy: state.isBusy,
                  onClaimPanel: controller.claimPanel,
                  // Self-release: whoever holds the baton hands it back
                  // themselves. Not gated on role and not confirm-guarded — it
                  // is reversible (re-claim) and the hub only accepts it from
                  // the claim's own account.
                  onReleasePanel: controller.releasePanel,
                  // Owner/admin recovery: evict a squatting claim or a
                  // poisoned upload back to pending. Only the owner path gets the
                  // callback (the grid hides the button when it is null), so a
                  // non-owner never sees an always-failing destructive action; a
                  // confirm dialog guards the owner's irreversible release.
                  onForceReleasePanel: state.project?.collabRole == 'owner'
                      ? (idx) => _confirmForceRelease(context, controller, idx)
                      : null,
                  // Route the per-panel upload through the consent sheet
                  // rather than calling the service with a silent default.
                  onUploadPanel: (idx) => _uploadMosaicWithConsent(
                    context,
                    controller,
                    panelIndex: idx,
                  ),
                ),
                if (state.isComplete) ...[
                  const SizedBox(height: SkotiqTokens.spaceXl),
                  const SectionTitle(
                    icon: SkotiqIcons.layers,
                    title: 'Stitched master',
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  MosaicStitchedMasterView(master: state.stitchedMaster!),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The slim "leave this screen" bar the mosaic project view carries in EVERY
/// state — loading, loaded, not-found, and storage-failure alike.
///
/// The review screen is always reached by a push (the projects list, the
/// collaborative detail view, or a deep link that builds the list beneath it),
/// and before this existed a failed/slow load rendered a bare spinner with no
/// app chrome at all: the operator had no way back and had to restart the app.
/// The project header: name, target region (RA/Dec), NxM grid, and lifecycle
/// status pill.
class MosaicProjectHeader extends StatelessWidget {
  final MosaicProject project;
  final MosaicProjectState state;

  const MosaicProjectHeader({
    super.key,
    required this.project,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    final center = _centerLabel(state.panels);
    final integrated = state.countWithStatus(MosaicPanelStatus.integrated);
    final planned = state.panels.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          icon: SkotiqIcons.grid,
          title: 'Mosaic',
          context: project.name.isEmpty ? null : project.name,
          actions: [
            SkotiqChip(
              label: mosaicProjectStatusLabel(project.status),
              icon: _statusIcon(project.status),
              tone: _statusTone(project.status),
              dot: true,
            ),
            const _MosaicProjectBackAction(),
          ],
        ),
        // The grid, the panel counts and the centre were a subtitle sentence
        // joined by middots. Every one of them is a measurement, so every one
        // is a Readout (05 §3); the centre keeps prose because it is a
        // coordinate pair, not a figure.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SkotiqTokens.space2xl,
            SkotiqTokens.spaceLg,
            SkotiqTokens.space2xl,
            0,
          ),
          child: ReadoutRow(
            children: [
              Readout(
                value: formatMosaicGrid(cols: project.cols, rows: project.rows),
                label: 'Grid',
                size: ReadoutSize.sm,
              ),
              Readout(
                // Both numbers, because they can differ: `totalPanels` is
                // rows × cols, and a project created with cells disabled in the
                // wizard persists a sparse panel set.
                value: planned == project.totalPanels
                    ? '$planned'
                    : '$planned / ${project.totalPanels}',
                label: 'Panels',
                size: ReadoutSize.sm,
              ),
              Readout(
                value: '$integrated',
                label: 'Integrated',
                size: ReadoutSize.sm,
              ),
              Readout(value: center, label: 'Centre', size: ReadoutSize.sm),
            ],
          ),
        ),
      ],
    );
  }

  /// The mosaic's centre as a compact "RA · Dec" string, derived from the panel
  /// centres, or null when there are no panels (or the RA mean is undefined).
  ///
  /// RA is averaged with [meanRaHours] — a CIRCULAR mean. A plain arithmetic
  /// mean is wrong for an angle: a mosaic straddling RA 0h has panels at e.g.
  /// 23.97h and 0.03h, which average to 12.0h and made this header state, with
  /// full confidence, a centre on the opposite side of the sky. Dec has no
  /// wraparound (it is bounded by ±90°), so it stays a plain mean.
  static String? _centerLabel(List<MosaicProjectPanel> panels) {
    if (panels.isEmpty) return null;
    final ra = meanRaHours(panels.map((panel) => panel.centerRa));
    if (ra == null) return null;
    var dec = 0.0;
    for (final panel in panels) {
      dec += panel.centerDec;
    }
    dec /= panels.length;
    return '${CoordinateParser.formatRaHms(ra)} '
        '${CoordinateParser.formatDecDms(dec)}';
  }

  static IconData _statusIcon(MosaicProjectStatus status) {
    switch (status) {
      case MosaicProjectStatus.planning:
        return SkotiqIcons.clock;
      case MosaicProjectStatus.capturing:
        return SkotiqIcons.camera;
      case MosaicProjectStatus.integrating:
        return SkotiqIcons.layers;
      case MosaicProjectStatus.stitching:
        return SkotiqIcons.grid;
      case MosaicProjectStatus.complete:
        return SkotiqIcons.success;
    }
  }

  /// StatusPill is deprecated outside the instrument bar (05 §10b), so the
  /// lifecycle reads as a toned chip instead.
  static ChipTone _statusTone(MosaicProjectStatus status) {
    switch (status) {
      case MosaicProjectStatus.planning:
        return ChipTone.neutral;
      case MosaicProjectStatus.capturing:
      case MosaicProjectStatus.integrating:
      case MosaicProjectStatus.stitching:
        return ChipTone.primary;
      case MosaicProjectStatus.complete:
        return ChipTone.success;
    }
  }
}

/// The page header the arms with no project loaded show: the screen still says
/// which screen it is while it is loading, missing or refused.
class _MosaicProjectHeaderBar extends StatelessWidget {
  const _MosaicProjectHeaderBar();

  @override
  Widget build(BuildContext context) {
    return const PageHeader(
      icon: SkotiqIcons.grid,
      title: 'Mosaic',
      actions: [_MosaicProjectBackAction()],
    );
  }
}

/// The way out, in the page header.
///
/// This was a full-width bar ABOVE the header on all four arms of this screen —
/// a second header row where 04-shell §4 gives one. The affordance stays, and
/// so does the sentence it was careful about: the control POPS, so it can only
/// promise "Mosaic projects" when the stack is empty and [_leave] really does
/// go there.
class _MosaicProjectBackAction extends StatelessWidget {
  const _MosaicProjectBackAction();

  @override
  Widget build(BuildContext context) {
    // Truthful by construction, exactly as the row it replaces was. This
    // screen is pushed from four places — the projects list, Framing, the
    // sequencer mosaic wizard and the Collaborative Sky mosaic detail — and the
    // control POPS, so it can only promise the projects list in the one case
    // where [_leave] really goes there: an empty stack.
    final canPop = Navigator.of(context).canPop();
    return SkotiqIconButton(
      icon: SkotiqIcons.arrowLeft,
      tooltip: canPop
          ? 'Back to where this mosaic was opened from'
          : 'Back to mosaic projects',
      onPressed: () => _leave(context),
    );
  }

  /// Pop when this screen sits on a stack (the normal case). A deep link that
  /// left nothing beneath it falls back to the projects list, so the control is
  /// never inert.
  static void _leave(BuildContext context) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    context.go('/mosaic');
  }
}

/// The action row: 'Integrate panels' and 'Stitch mosaic', with busy/progress
/// and a stitch gate (<2 panels with masters disables stitch and explains why).
class MosaicProjectActions extends StatelessWidget {
  final MosaicProjectState state;
  final MosaicProjectController controller;

  const MosaicProjectActions({
    super.key,
    required this.state,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final canStitch = state.canStitch;
    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: SkotiqTokens.spaceMd,
            runSpacing: SkotiqTokens.spaceSm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (controller.canStartCapture)
                SkotiqButton(
                  label: 'Start capture',
                  icon: SkotiqIcons.camera,
                  isLoading: state.isStartingCapture,
                  onPressed:
                      state.isBusy ? null : () => controller.startCapture(),
                ),
              SkotiqButton(
                label: 'Integrate panels',
                icon: SkotiqIcons.layers,
                isLoading: state.isIntegrating,
                onPressed:
                    state.isBusy ? null : () => controller.integratePanels(),
              ),
              SkotiqButton(
                label: 'Stitch mosaic',
                icon: SkotiqIcons.grid,
                variant: ButtonVariant.secondary,
                isLoading: state.isStitching,
                onPressed: (!canStitch || state.isBusy)
                    ? null
                    : () => controller.stitchProject(),
              ),
              Text(
                canStitch
                    ? '${state.panelsWithMasters} of ${state.panels.length} '
                        'panels integrated'
                    : 'Stitch needs ≥ 2 integrated panels '
                        '(${state.panelsWithMasters} ready)',
                style: SkotiqTypography.bodySm.copyWith(
                  color: canStitch ? colors.textSecondary : colors.textMuted,
                ),
              ),
            ],
          ),
          if (state.isStartingCapture ||
              state.isIntegrating ||
              state.isStitching) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqProgressBar(
              value: 0,
              indeterminate: true,
              label: state.isStartingCapture
                  ? 'Launching capture…'
                  : state.isIntegrating
                      ? 'Integrating panels…'
                      : 'Stitching mosaic…',
            ),
          ],
        ],
      ),
    );
  }
}

/// The distributed-mosaic lifecycle card on the owner / participant project
/// view. It surfaces the whole publish → claim → upload →
/// assemble → download loop by invoking the already-wired
/// [MosaicProjectController] collaborative actions; it owns no hub logic of its
/// own.
///
/// State machine rendered from the durable project + live `collab_status`:
///  * not yet published  → "Publish to hub" (becomes claimable work items);
///  * published          → hub id + role + status, bulk claim (everything
///    pending for the owner, a bounded batch for a participant so one rig
///    cannot lock a shared mosaic in a tap) / upload-all, the hub's own claim
///    expiry, and a "Refresh status" poll control;
///  * owner + assembling  → "Assemble + publish" (pull every panel, stitch,
///    push the finished mosaic to the swarm);
///  * complete            → "Download finished mosaic".
///
/// Every button binds its enabled/spinner state to the controller's
/// isPublishing/isClaiming/isUploading/isAssembling/isRefreshing/isDownloading
/// busy flags; errors land on the screen-level banner via `state.error`.
class MosaicCollaborativeSection extends StatelessWidget {
  final MosaicProjectState state;
  final MosaicProjectController controller;

  const MosaicCollaborativeSection({
    super.key,
    required this.state,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final published = state.isPublished;
    final role = state.project?.collabRole;
    final collabStatus = state.collabStatus;
    final isOwner = role == 'owner';

    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!published) ...[
            Text(
              'This mosaic is local-only. Publish its panel grid to the hub so '
              'your club can claim and capture panels in parallel.',
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label: 'Publish to hub',
                icon: SkotiqIcons.upload,
                isLoading: state.isPublishing,
                onPressed:
                    state.isBusy ? null : () => controller.publishToHub(),
              ),
            ),
          ] else ...[
            _CollabStatusLine(
              hubMosaicId: state.hubMosaicId ?? '',
              role: role,
              collabStatus: collabStatus,
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Wrap(
              spacing: SkotiqTokens.spaceMd,
              runSpacing: SkotiqTokens.spaceSm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SkotiqButton(
                  label: _bulkClaimLabel(isOwner, controller.bulkClaimCount),
                  icon: SkotiqIcons.download,
                  variant: ButtonVariant.secondary,
                  isLoading: state.isClaiming,
                  onPressed: (state.isBusy || controller.bulkClaimCount == 0)
                      ? null
                      : () => controller.claimPendingBatch(),
                ),
                SkotiqButton(
                  label: 'Upload all integrated',
                  icon: SkotiqIcons.upload,
                  variant: ButtonVariant.secondary,
                  isLoading: state.isUploading,
                  onPressed:
                      (state.isBusy || state.integratedNotUploaded.isEmpty)
                          ? null
                          : () => _uploadMosaicWithConsent(context, controller),
                ),
                if (isOwner && collabStatus == 'assembling')
                  SkotiqButton(
                    label: 'Assemble + publish',
                    icon: SkotiqIcons.grid,
                    isLoading: state.isAssembling,
                    onPressed: state.isBusy
                        ? null
                        : () => controller.assembleFromHub(),
                  ),
                if (collabStatus == 'complete')
                  SkotiqButton(
                    label: 'Download finished mosaic',
                    icon: SkotiqIcons.download,
                    isLoading: state.isDownloading,
                    onPressed:
                        state.isBusy ? null : () => controller.downloadOutput(),
                  ),
                SkotiqButton(
                  label: 'Refresh status',
                  icon: SkotiqIcons.refresh,
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  isLoading: state.isRefreshing,
                  onPressed:
                      state.isBusy ? null : () => controller.refreshStatus(),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              // How many panels THIS rig still owes the swarm, not just how
              // many have landed on the hub: a claim is a commitment to shoot a
              // panel (and to block the rest of the club from it), so the count
              // that matters when deciding whether to claim more — or hand some
              // back — is the outstanding held one. Uploaded panels are counted
              // by the clause after it, never as still-held work.
              'You hold ${state.heldPanelCount} of ${state.panels.length} '
              'panels · ${state.panelsUploaded} uploaded to the hub'
              '${isOwner ? '' : ' · claim a panel below to contribute'}',
              style:
                  SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: SkotiqTokens.spaceXs),
            Text(
              _claimHoldCaption(context, state),
              style:
                  SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// The bulk-claim action label. The owner of the mosaic claims everything still
/// pending; a participant takes a bounded batch, and the label says exactly how
/// many panels the tap will take rather than implying "all of them".
String _bulkClaimLabel(bool isOwner, int count) {
  if (isOwner) return 'Claim all pending';
  return count == 1 ? 'Claim 1 panel' : 'Claim $count panels';
}

/// The claim-hold caption: what holding a claim commits the operator to. Once
/// panels are held it shows the HUB's own expiry for them (never a client-side
/// copy of the TTL), so "how long am I holding this?" has a real answer, and it
/// always points at releasing a panel that will not be shot.
String _claimHoldCaption(BuildContext context, MosaicProjectState state) {
  final expiresAt = state.claimExpiresAt;
  if (expiresAt == null) {
    return 'A claimed panel is held for your rig until you release it or the '
        'hub claim expires.';
  }
  return 'Your claim is held until ${_formatClaimExpiry(context, expiresAt)} — '
      'release any panel you are not going to shoot.';
}

/// Format a hub claim expiry in the operator's local time, adding the date when
/// the deadline falls on another day.
String _formatClaimExpiry(BuildContext context, DateTime expiresAt) {
  final local = expiresAt.toLocal();
  final l10n = MaterialLocalizations.of(context);
  final time = l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local));
  final now = DateTime.now();
  final sameDay = local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  return sameDay ? time : '${l10n.formatShortDate(local)} $time';
}

/// The published-mosaic summary line: hub id, this device's role, and the live
/// hub-side lifecycle pill.
class _CollabStatusLine extends StatelessWidget {
  final String hubMosaicId;
  final String? role;
  final String? collabStatus;

  const _CollabStatusLine({
    required this.hubMosaicId,
    required this.role,
    required this.collabStatus,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      children: [
        Icon(
          role == 'owner' ? SkotiqIcons.star : SkotiqIcons.user,
          size: SkotiqTokens.iconSm,
          color: colors.primary,
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Text(
            'Hub mosaic $hubMosaicId · '
            '${role == 'owner' ? 'Owner' : 'Participant'}',
            style: SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        StatusPill(
          icon: _collabStatusIcon(collabStatus),
          label: 'Status',
          value: collabMosaicStatusLabel(collabStatus),
          status: _collabPillStatus(collabStatus),
        ),
      ],
    );
  }

  static IconData _collabStatusIcon(String? status) {
    switch (status) {
      case 'assembling':
        return SkotiqIcons.layers;
      case 'complete':
        return SkotiqIcons.success;
      case 'published':
      default:
        return SkotiqIcons.share;
    }
  }

  static StatusPillStatus _collabPillStatus(String? status) {
    switch (status) {
      case 'assembling':
        return StatusPillStatus.warning;
      case 'complete':
        return StatusPillStatus.success;
      case 'published':
      default:
        return StatusPillStatus.active;
    }
  }
}

/// The display label for a hub-side collaborative `collab_status`.
String collabMosaicStatusLabel(String? status) {
  switch (status) {
    case 'assembling':
      return 'Assembling';
    case 'complete':
      return 'Complete';
    case 'published':
      return 'Published';
    default:
      return status == null || status.isEmpty ? 'Published' : status;
  }
}

/// The stitched-master hero. Reuses the morning-report [MasterOverlayView] when
/// a preview PNG is on disk (so the operator gets zoom/pan + coverage/rejection
/// overlays), falling back to [MasterPreviewView] otherwise (which renders its
/// own honest empty state when even the preview is missing).
class MosaicStitchedMasterView extends StatelessWidget {
  final IntegratedMaster master;

  const MosaicStitchedMasterView({super.key, required this.master});

  @override
  Widget build(BuildContext context) {
    final preview = master.previewPngPath;
    return SizedBox(
      height: 520,
      child: SkotiqPanel(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: SkotiqTokens.borderRadiusMd,
          child: preview != null
              ? MasterOverlayView(
                  previewPngPath: preview,
                  rejectionMapPngPath: master.rejectionMapPreviewPath,
                  coverageMapPngPath: master.coverageMapPreviewPath,
                )
              : MasterPreviewView.fromMaster(master),
        ),
      ),
    );
  }
}

/// A dismissible error banner shown under the header.
class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      width: double.infinity,
      color: colors.error.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: Row(
        children: [
          Icon(SkotiqIcons.warning,
              size: SkotiqTokens.iconSm, color: colors.error),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              message,
              style: SkotiqTypography.bodySm.copyWith(color: colors.error),
            ),
          ),
          IconButton(
            icon: Icon(SkotiqIcons.close,
                size: SkotiqTokens.iconSm, color: colors.textSecondary),
            tooltip: 'Dismiss',
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// The display label for a [MosaicProjectStatus].
String mosaicProjectStatusLabel(MosaicProjectStatus status) {
  switch (status) {
    case MosaicProjectStatus.planning:
      return 'Planning';
    case MosaicProjectStatus.capturing:
      return 'Capturing';
    case MosaicProjectStatus.integrating:
      return 'Integrating';
    case MosaicProjectStatus.stitching:
      return 'Stitching';
    case MosaicProjectStatus.complete:
      return 'Complete';
  }
}
