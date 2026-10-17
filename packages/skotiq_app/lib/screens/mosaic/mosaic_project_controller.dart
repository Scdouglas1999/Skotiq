import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;

import '../collaborative_sky/collaborative_sky_providers.dart'
    show invalidateCollaborativeMosaicState;

part 'mosaic_project_controller_parts/_state.dart';
part 'mosaic_project_controller_parts/_providers.dart';

/// Riverpod controller for one mosaic project's review experience.
///
/// It is design-system pure: it holds only data (project + panels + masters +
/// busy/error flags) and drives the two durable actions through the committed
/// [MosaicProjectService] — it owns no widgets and no native calls of its own.
///
///  * [load] reads the project + panels via the DAOs and resolves each panel's
///    master (and the stitched output) from [IntegratedMastersDao].
///  * [integratePanels] runs [MosaicProjectService.integratePanels] and reloads.
///  * [stitchProject] runs [MosaicProjectService.stitchProject] and reloads;
///    it refuses (without touching the service) when fewer than two panels have
///    masters, mirroring the service's own >= 2 guard so the UI never makes a
///    doomed call.
class MosaicProjectController extends StateNotifier<MosaicProjectState> {
  MosaicProjectController({
    required int projectId,
    required MosaicProjectsDao projectsDao,
    required MosaicPanelsDao panelsDao,
    required IntegratedMastersDao mastersDao,
    required MosaicProjectService service,
    required String Function(MosaicProjectPanel panel) panelOutputPathBuilder,
    required String Function(MosaicProject project) stitchOutputDirectory,
    CollaborativeMosaicService? collaborativeService,
    bool hubConfigured = true,
    MosaicCaptureLauncher? captureLauncher,
    IntegrationSettings integrationSettings = IntegrationSettings.defaults,
    void Function()? onHubStateChanged,
    this.hubTimeout = defaultHubTimeout,
    this.hubTransferTimeout = defaultHubTransferTimeout,
  })  : _projectId = projectId,
        _projectsDao = projectsDao,
        _panelsDao = panelsDao,
        _mastersDao = mastersDao,
        _service = service,
        _collaborative = collaborativeService,
        _hubConfigured = hubConfigured,
        _panelOutputPathBuilder = panelOutputPathBuilder,
        _stitchOutputDirectory = stitchOutputDirectory,
        _captureLauncher = captureLauncher,
        _integrationSettings = integrationSettings,
        _onHubStateChanged = onHubStateChanged,
        super(const MosaicProjectState()) {
    // Kick the first load; errors land on state.error rather than throwing into
    // the constructor.
    unawaited(load());
  }

  final int _projectId;
  final MosaicProjectsDao _projectsDao;
  final MosaicPanelsDao _panelsDao;
  final IntegratedMastersDao _mastersDao;
  final MosaicProjectService _service;

  /// Collaborative-mosaic orchestration. Null on the local-only review path,
  /// where no hub-aware service is wired; the collaborative actions then report
  /// a clear error rather than crashing.
  final CollaborativeMosaicService? _collaborative;

  /// Whether a Constellation hub is actually configured/signed-in (resolved from
  /// [constellationConfiguredProvider]). A hub-aware service is always wired, so
  /// this — not merely `_collaborative != null` — is what gates the collaborative
  /// affordances: with no hub the publish/claim/force-release actions would fail
  /// at the tap with an auth error, so they are hidden/disabled up front instead.
  final bool _hubConfigured;
  final String Function(MosaicProjectPanel panel) _panelOutputPathBuilder;
  final String Function(MosaicProject project) _stitchOutputDirectory;

  /// Builds the per-panel-target mosaic sequence and loads it into the executor.
  /// Null when the screen was constructed without a launcher (capture is then
  /// unavailable — the integrate/stitch review actions still work). Injected so
  /// tests can drive [startCapture] without the real sequencer/executor.
  final MosaicCaptureLauncher? _captureLauncher;
  final IntegrationSettings _integrationSettings;

  /// Fired after every action that CHANGES hub-side collaborative state
  /// (publish / claim / release / upload / assemble / join).
  ///
  /// The hub listings the Collaborative Sky surface renders are plain (non
  /// `autoDispose`) `FutureProvider`s, so their first answer is cached for the
  /// life of the container. Without this hook, publishing a mosaic left that
  /// surface still rendering "No collaborative mosaics on this hub yet" — the
  /// screen whose whole job is to show shared mosaics claiming there were none,
  /// until the operator happened to press its manual refresh icon.
  final void Function()? _onHubStateChanged;

  /// How long the project read may take before the screen stops waiting on it.
  /// A wedged/locked database must surface an actionable error rather than an
  /// indefinite spinner the operator cannot interpret.
  static const Duration loadTimeout = Duration(seconds: 20);

  /// How long a hub control-plane call (publish / claim / release / discover /
  /// join / refresh) may take before the screen stops waiting on it.
  ///
  /// The local read above states a bound; the calls that actually cross a
  /// network stated none, so a hub that accepted the connection and then went
  /// quiet left the action buttons disabled behind a spinner with no way back
  /// except leaving the screen.
  static const Duration defaultHubTimeout = Duration(seconds: 60);

  /// The bound for hub calls that move image bytes or stitch server-side —
  /// panel-master upload, finished-mosaic download, central assembly. Minutes
  /// rather than seconds because a panel master is hundreds of megabytes, but
  /// still finite.
  static const Duration defaultHubTransferTimeout = Duration(minutes: 10);

  /// Injected so tests can trip the bound without waiting on wall-clock time.
  final Duration hubTimeout;
  final Duration hubTransferTimeout;

  String _hubTimeoutMessage(String action, Duration bound) {
    final elapsed =
        bound.inSeconds < 60 ? '${bound.inSeconds}s' : '${bound.inMinutes} min';
    return '$action timed out after $elapsed — the hub did not answer. '
        'Check the hub is reachable and try again.';
  }

  /// Load (or reload) the project, its panels, the per-panel masters, and the
  /// stitched output. Errors are captured onto [MosaicProjectState.error]; the
  /// previously-loaded chrome is left intact so a transient read failure does
  /// not blank the screen. The whole read is bounded by [loadTimeout], so
  /// `isLoading` always resolves.
  Future<void> load() async {
    if (!mounted) return;
    state = state.copyWith(isLoading: state.project == null, clearError: true);
    try {
      final snapshot = await _readSnapshot().timeout(loadTimeout);
      final project = snapshot.project;
      if (project == null) {
        if (!mounted) return;
        state = state.copyWith(
          isLoading: false,
          error: 'No mosaic project with id $_projectId',
        );
        return;
      }
      final panels = snapshot.panels;

      if (!mounted) return;
      state = MosaicProjectState(
        project: project,
        panels: panels,
        panelMasters: snapshot.panelMasters,
        stitchedMaster: snapshot.stitchedMaster,
        isLoading: false,
        isStartingCapture: state.isStartingCapture,
        isIntegrating: state.isIntegrating,
        isStitching: state.isStitching,
        isPublishing: state.isPublishing,
        isClaiming: state.isClaiming,
        isUploading: state.isUploading,
        isAssembling: state.isAssembling,
        isJoining: state.isJoining,
        isRefreshing: state.isRefreshing,
        isDownloading: state.isDownloading,
        // The held-claim expiry is only meaningful while this rig still holds
        // one; releasing the last panel drops it rather than leaving a stale
        // deadline on screen.
        claimExpiresAt: panels.any((p) => p.isClaimed && !p.isUploaded)
            ? state.claimExpiresAt
            : null,
      );
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        error: 'Timed out reading mosaic project $_projectId after '
            '${loadTimeout.inSeconds}s — the project database did not respond. '
            'Close any other Skotiq instance using it and try again.',
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: 'Failed to load: $e');
    }
  }

  /// One consistent read of everything the screen renders, separate from [load]
  /// so the whole read can be bounded by a single timeout.
  Future<_MosaicProjectSnapshot> _readSnapshot() async {
    final project = await _projectsDao.getById(_projectId);
    if (project == null) return const _MosaicProjectSnapshot();

    final panels = await _panelsDao.getForProject(_projectId);

    // Resolve each panel's per-panel master once, de-duplicated by master id
    // (several panels never share a master, but the map keeps the lookup
    // O(1) for the grid and tolerates a missing/deleted master row).
    final masters = <int, IntegratedMaster>{};
    for (final panel in panels) {
      final masterId = panel.integratedMasterId;
      if (masterId == null || masters.containsKey(masterId)) continue;
      final master = await _mastersDao.getById(masterId);
      if (master != null) masters[masterId] = master;
    }

    final outputMasterId = project.outputMasterId;
    final stitched = outputMasterId == null
        ? null
        : await _mastersDao.getById(outputMasterId);

    return _MosaicProjectSnapshot(
      project: project,
      panels: panels,
      panelMasters: masters,
      stitchedMaster: stitched,
    );
  }

  /// Whether this controller can launch capture (a [MosaicCaptureLauncher] was
  /// supplied). The screen hides/disables the "Start capture" action when false.
  bool get canStartCapture => _captureLauncher != null;

  /// LAUNCH capture of the durable project via
  /// [MosaicProjectService.startCapture]: the service resolves each panel's
  /// distinct capture target, the injected [MosaicCaptureLauncher] builds the
  /// per-panel-target mosaic sequence and loads it into the executor, and the
  /// project + panels move into the capturing state. Then reload so the header
  /// reflects the new lifecycle.
  ///
  /// No-op (with a clear error) when no launcher was supplied. Busy/error are
  /// reported on state; a thrown service/launcher error is caught and surfaced,
  /// never rethrown into the widget tree.
  Future<void> startCapture() async {
    final project = state.project;
    if (project == null || state.isBusy) return;
    final launcher = _captureLauncher;
    if (launcher == null) {
      state = state.copyWith(
        error: 'Capture is unavailable: no sequencer/executor wired for this '
            'screen.',
      );
      return;
    }
    state = state.copyWith(isStartingCapture: true, clearError: true);
    try {
      await _service.startCapture(_projectId, launcher: launcher);
      await load();
      if (mounted) state = state.copyWith(isStartingCapture: false);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isStartingCapture: false,
        error: 'Start capture failed: $e',
      );
    }
  }

  /// Integrate every panel of this project via [MosaicProjectService], then
  /// reload so the grid reflects the new per-panel masters. Busy/error are
  /// reported on state; a thrown service error is caught and surfaced, never
  /// rethrown into the widget tree.
  Future<void> integratePanels() async {
    final project = state.project;
    if (project == null || state.isBusy) return;
    state = state.copyWith(isIntegrating: true, clearError: true);
    try {
      final outcomes = await _service.integratePanels(
        _projectId,
        settings: _integrationSettings,
        outputFitsPathBuilder: _panelOutputPathBuilder,
      );
      await load();
      if (!mounted) return;
      final failed = outcomes
          .where((o) => o.status == MosaicPanelStatus.failed)
          .toList(growable: false);
      if (failed.isEmpty) {
        state = state.copyWith(isIntegrating: false);
      } else {
        final detail = failed
            .map((o) => o.note == null
                ? 'panel ${o.panelIndex + 1}'
                : 'panel ${o.panelIndex + 1}: ${o.note}')
            .join('; ');
        state = state.copyWith(
          isIntegrating: false,
          error: 'Integrated ${outcomes.length - failed.length} of '
              '${outcomes.length} panels; ${failed.length} failed — $detail',
        );
      }
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isIntegrating: false,
        error: 'Integration failed: $e',
      );
    }
  }

  /// Stitch the integrated panels into one mosaic master via
  /// [MosaicProjectService], then reload so the stitched hero appears.
  ///
  /// Gated on [MosaicProjectState.canStitch] (>= 2 panels with masters): when
  /// fewer than two panels carry a master this records a clear error WITHOUT
  /// calling the service, mirroring the service's own guard so the UI never
  /// makes a doomed FFI round-trip.
  Future<void> stitchProject() async {
    final project = state.project;
    if (project == null || state.isBusy) return;
    if (!state.canStitch) {
      state = state.copyWith(
        error: 'Stitch needs at least 2 integrated panels '
            '(have ${state.panelsWithMasters}).',
      );
      return;
    }
    state = state.copyWith(isStitching: true, clearError: true);
    try {
      await _service.stitchProject(
        _projectId,
        outputDirectory: _stitchOutputDirectory(project),
      );
      await load();
      if (mounted) state = state.copyWith(isStitching: false);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isStitching: false, error: 'Stitch failed: $e');
    }
  }

  // Collaborative mosaics — publish / claim / upload / assemble over the
  // hub. Each mirrors the integrate/stitch shape: set the right busy flag, call
  // the collaborative service, reload, and surface errors WITHOUT rethrowing.

  /// Whether the collaborative actions are available: a hub-aware service was
  /// wired AND a Constellation hub is actually configured/signed-in. The screen
  /// hides/disables the collaborative affordances when false, so the buttons are
  /// never enabled-then-failing-at-the-tap on a rig with no hub.
  bool get canCollaborate => _collaborative != null && _hubConfigured;

  /// Reload this project AND tell the rest of the app that hub-side state moved.
  ///
  /// Every collaborative action calls this instead of a bare [load]: [load] only
  /// re-reads THIS controller's own project row, which is why the shared
  /// listings elsewhere in the app used to keep serving their pre-publish
  /// answer. Local-only actions (integrate/stitch) keep calling [load] directly
  /// so they do not trigger a needless hub round-trip.
  Future<void> _reloadAfterHubMutation() async {
    await load();
    if (mounted) _onHubStateChanged?.call();
  }

  /// Publish this project to the hub as a collaborative mosaic, then reload so
  /// the header reflects the published state.
  Future<void> publishToHub() async {
    final collaborative = _collaborative;
    final project = state.project;
    if (project == null || state.isBusy) return;
    if (collaborative == null) {
      state = state.copyWith(
          error: 'Collaborative mosaics are unavailable: no '
              'hub is configured for this screen.');
      return;
    }
    state = state.copyWith(isPublishing: true, clearError: true);
    try {
      await collaborative.publishProject(_projectId).timeout(hubTimeout);
      await _reloadAfterHubMutation();
      if (mounted) state = state.copyWith(isPublishing: false);
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isPublishing: false,
        error: _hubTimeoutMessage('Publish', hubTimeout),
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isPublishing: false, error: 'Publish failed: $e');
    }
  }

  /// The most panels a NON-OWNER may take in a single bulk claim.
  ///
  /// A hub claim is held for hours and only its holder (or the owner, one panel
  /// at a time) can give it back, so an unbounded "claim everything" on a mosaic
  /// this rig does not own is a one-tap lockout of its owner. A participant gets
  /// a batch worth a night's work instead and can claim further panels
  /// individually from the grid.
  static const int participantBulkClaimLimit = 4;

  /// How many panels the bulk-claim action will actually take: everything still
  /// pending for the OWNER of the mosaic, and for a participant at most
  /// [participantBulkClaimLimit] and never more than half the grid, so one
  /// contributor can never swallow a shared mosaic in a single tap.
  int get bulkClaimCount {
    final pending = state.unclaimedPanels.length;
    if (state.isOwner) return pending;
    final halfGrid = state.panels.length ~/ 2;
    var limit = participantBulkClaimLimit;
    if (halfGrid < limit) limit = halfGrid;
    if (limit < 1) limit = 1;
    return pending < limit ? pending : limit;
  }

  /// Claim one panel of the published mosaic via the hub baton, then reload.
  Future<void> claimPanel(int panelIndex) async {
    await _runClaim(
        () => _collaborative!.claimPanels(_projectId, [panelIndex]));
  }

  /// Claim a batch of not-yet-claimed panels of the published mosaic, then
  /// reload. Bounded by [bulkClaimCount] — unlimited for the mosaic's owner,
  /// capped for a participant.
  Future<void> claimPendingBatch() async {
    final indices = state.unclaimedPanels
        .take(bulkClaimCount)
        .map((p) => p.panelIndex)
        .toList(growable: false);
    if (indices.isEmpty) return;
    await _runClaim(() => _collaborative!.claimPanels(_projectId, indices));
  }

  Future<void> _runClaim(
    Future<List<MosaicPanelClaim>> Function() action,
  ) async {
    final collaborative = _collaborative;
    final project = state.project;
    if (project == null || state.isBusy) return;
    if (collaborative == null) {
      state = state.copyWith(
          error: 'Collaborative mosaics are unavailable: no '
              'hub is configured for this screen.');
      return;
    }
    state = state.copyWith(isClaiming: true, clearError: true);
    try {
      final claims = await action().timeout(hubTimeout);
      await _reloadAfterHubMutation();
      if (!mounted) return;
      // Surface the hub's OWN deadline for what was just granted, so the person
      // taking a panel can see how long they are holding it for.
      final expiries = claims
          .map((c) => c.expiresAt)
          .whereType<DateTime>()
          .toList(growable: false);
      state = state.copyWith(
        isClaiming: false,
        claimExpiresAt: expiries.isEmpty
            ? null
            : expiries.reduce((a, b) => a.isBefore(b) ? a : b),
      );
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isClaiming: false,
        error: _hubTimeoutMessage('Claim', hubTimeout),
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isClaiming: false, error: 'Claim failed: $e');
    }
  }

  /// Hand THIS rig's own claim on [panelIndex] back to the pool, then reload.
  ///
  /// The counterpart to [claimPanel] and the only way a contributor can undo a
  /// claim themselves: the hub accepts it from the account holding the baton,
  /// where [forceReleasePanel] is owner/admin-only. Reuses the claim busy flag
  /// since it is claim-baton management.
  Future<void> releasePanel(int panelIndex) async {
    final collaborative = _collaborative;
    final project = state.project;
    if (project == null || state.isBusy) return;
    if (collaborative == null) {
      state = state.copyWith(
          error: 'Collaborative mosaics are unavailable: no '
              'hub is configured for this screen.');
      return;
    }
    state = state.copyWith(isClaiming: true, clearError: true);
    try {
      final released = await collaborative
          .releasePanel(_projectId, panelIndex)
          .timeout(hubTimeout);
      await _reloadAfterHubMutation();
      if (!mounted) return;
      if (released) {
        state = state.copyWith(isClaiming: false);
      } else {
        state = state.copyWith(
          isClaiming: false,
          error: 'Panel ${panelIndex + 1} was not released — the hub no longer '
              'holds a claim for this device.',
        );
      }
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isClaiming: false,
        error: _hubTimeoutMessage('Release', hubTimeout),
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isClaiming: false, error: 'Release failed: $e');
    }
  }

  /// Owner/admin recovery: force-release one panel of the published mosaic —
  /// evicting a squatting claim or a poisoned upload that the per-account
  /// release cannot recover — then reload. The hub enforces owner/admin
  /// ownership; a non-owner sees the surfaced auth error. Reuses the claim busy
  /// flag since it is a claim-baton management action.
  Future<void> forceReleasePanel(int panelIndex) async {
    final collaborative = _collaborative;
    final project = state.project;
    if (project == null || state.isBusy) return;
    if (collaborative == null) {
      state = state.copyWith(
          error: 'Collaborative mosaics are unavailable: no '
              'hub is configured for this screen.');
      return;
    }
    state = state.copyWith(isClaiming: true, clearError: true);
    try {
      await collaborative
          .forceReleasePanel(_projectId, panelIndex)
          .timeout(hubTimeout);
      await _reloadAfterHubMutation();
      if (mounted) state = state.copyWith(isClaiming: false);
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isClaiming: false,
        error: _hubTimeoutMessage('Force-release', hubTimeout),
      );
    } catch (e) {
      if (!mounted) return;
      state =
          state.copyWith(isClaiming: false, error: 'Force-release failed: $e');
    }
  }

  /// Upload one integrated panel's master to the hub under the user's chosen
  /// sharing [license] + [attributionConsent] — the caller presents the
  /// contribute sheet first — then reload.
  Future<void> uploadPanelMaster(
    int panelIndex, {
    required ContributionLicense license,
    required bool attributionConsent,
  }) async {
    await _runUpload(
      () => _collaborative!
          .uploadPanelMaster(
            _projectId,
            panelIndex,
            license: license,
            attributionConsent: attributionConsent,
          )
          .timeout(hubTransferTimeout),
    );
  }

  /// Upload every integrated-but-not-yet-uploaded panel master under the user's
  /// chosen sharing [license] + [attributionConsent], then reload.
  Future<void> uploadAllIntegrated({
    required ContributionLicense license,
    required bool attributionConsent,
  }) async {
    final indices = state.integratedNotUploaded
        .map((p) => p.panelIndex)
        .toList(growable: false);
    if (indices.isEmpty) return;
    await _runUpload(() async {
      for (final index in indices) {
        // Per panel, not per batch: a twenty-panel upload is legitimately long,
        // but no single panel may stall forever.
        await _collaborative!
            .uploadPanelMaster(
              _projectId,
              index,
              license: license,
              attributionConsent: attributionConsent,
            )
            .timeout(hubTransferTimeout);
      }
    });
  }

  Future<void> _runUpload(Future<void> Function() action) async {
    final collaborative = _collaborative;
    final project = state.project;
    if (project == null || state.isBusy) return;
    if (collaborative == null) {
      state = state.copyWith(
          error: 'Collaborative mosaics are unavailable: no '
              'hub is configured for this screen.');
      return;
    }
    state = state.copyWith(isUploading: true, clearError: true);
    try {
      await action();
      await _reloadAfterHubMutation();
      if (mounted) state = state.copyWith(isUploading: false);
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isUploading: false,
        error: _hubTimeoutMessage('Upload', hubTransferTimeout),
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isUploading: false, error: 'Upload failed: $e');
    }
  }

  /// Owner-only central assembly: pull every panel master, stitch, and push the
  /// finished mosaic back to the hub, then reload.
  Future<void> assembleFromHub() async {
    final collaborative = _collaborative;
    final project = state.project;
    if (project == null || state.isBusy) return;
    if (collaborative == null) {
      state = state.copyWith(
          error: 'Collaborative mosaics are unavailable: no '
              'hub is configured for this screen.');
      return;
    }
    state = state.copyWith(isAssembling: true, clearError: true);
    try {
      await collaborative.assembleMosaic(_projectId).timeout(
            hubTransferTimeout,
          );
      await _reloadAfterHubMutation();
      if (mounted) state = state.copyWith(isAssembling: false);
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isAssembling: false,
        error: _hubTimeoutMessage('Assemble', hubTransferTimeout),
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isAssembling: false, error: 'Assemble failed: $e');
    }
  }

  /// Discover open/claimable collaborative mosaics on the configured hub — the
  /// participant-side counterpart to [publishToHub], so a rig can pick a mosaic
  /// to JOIN before claiming panels. Returns the listing (empty + a surfaced
  /// error when no hub is wired); never throws into the widget tree.
  Future<List<CollabMosaic>> discoverMosaics() async {
    final collaborative = _collaborative;
    if (collaborative == null) {
      state = state.copyWith(
          error: 'Collaborative mosaics are unavailable: no '
              'hub is configured for this screen.');
      return const [];
    }
    try {
      return await collaborative.listMosaics().timeout(hubTimeout);
    } on TimeoutException {
      if (mounted) {
        state = state.copyWith(
          error: _hubTimeoutMessage('Discover', hubTimeout),
        );
      }
      return const [];
    } catch (e) {
      if (mounted) state = state.copyWith(error: 'Discover failed: $e');
      return const [];
    }
  }

  /// JOIN [hubMosaicId] as a participant: link this local project to the hub
  /// mosaic with `collab_role = participant` so its claim/upload/download calls
  /// resolve the hub mosaic. Prerequisite for a non-owner rig to contribute —
  /// without it, claim/upload 400 with "not published to a hub". Then reload.
  Future<void> joinAsParticipant(String hubMosaicId) async {
    final collaborative = _collaborative;
    final project = state.project;
    if (project == null || state.isBusy) return;
    if (collaborative == null) {
      state = state.copyWith(
          error: 'Collaborative mosaics are unavailable: no '
              'hub is configured for this screen.');
      return;
    }
    if (hubMosaicId.trim().isEmpty) {
      state =
          state.copyWith(error: 'Join failed: a hub mosaic id is required.');
      return;
    }
    state = state.copyWith(isJoining: true, clearError: true);
    try {
      await collaborative
          .joinAsParticipant(_projectId, hubMosaicId)
          .timeout(hubTimeout);
      await _reloadAfterHubMutation();
      if (mounted) state = state.copyWith(isJoining: false);
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isJoining: false,
        error: _hubTimeoutMessage('Join', hubTimeout),
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isJoining: false, error: 'Join failed: $e');
    }
  }

  /// Refresh this project's `collab_status` from the hub (the owner polling for
  /// `assembling`, or a participant polling for `complete`), then reload so the
  /// header reflects the live lifecycle.
  Future<void> refreshStatus() async {
    final collaborative = _collaborative;
    final project = state.project;
    if (project == null || state.isBusy) return;
    if (collaborative == null) {
      state = state.copyWith(
          error: 'Collaborative mosaics are unavailable: no '
              'hub is configured for this screen.');
      return;
    }
    state = state.copyWith(isRefreshing: true, clearError: true);
    try {
      await collaborative.refreshStatus(_projectId).timeout(hubTimeout);
      await load();
      if (mounted) state = state.copyWith(isRefreshing: false);
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isRefreshing: false,
        error: _hubTimeoutMessage('Refresh', hubTimeout),
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(isRefreshing: false, error: 'Refresh failed: $e');
    }
  }

  /// Download the finished collaborative mosaic the owner assembled + published
  /// back to the swarm — the participant end of the "publish the finished mosaic
  /// to every participant" loop. Persists it as this project's output master,
  /// then reload so the stitched hero appears.
  Future<void> downloadOutput() async {
    final collaborative = _collaborative;
    final project = state.project;
    if (project == null || state.isBusy) return;
    if (collaborative == null) {
      state = state.copyWith(
          error: 'Collaborative mosaics are unavailable: no '
              'hub is configured for this screen.');
      return;
    }
    state = state.copyWith(isDownloading: true, clearError: true);
    try {
      await collaborative.downloadOutput(_projectId).timeout(
            hubTransferTimeout,
          );
      await load();
      if (mounted) state = state.copyWith(isDownloading: false);
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isDownloading: false,
        error: _hubTimeoutMessage('Download', hubTransferTimeout),
      );
    } catch (e) {
      if (!mounted) return;
      state =
          state.copyWith(isDownloading: false, error: 'Download failed: $e');
    }
  }

  /// Dismiss the current error banner.
  void clearError() {
    if (state.error != null) state = state.copyWith(clearError: true);
  }
}
