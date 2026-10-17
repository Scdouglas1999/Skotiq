// The unattended-rig auto-driver for distributed collaborative mosaics.
//
// The hub auto-flips a mosaic to `assembling` the moment the final panel master
// lands, and to `complete` once the owner pushes the stitched output. But those
// two terminal steps still require the local rig to ACT: the owner must pull
// every panel + run the native stitch + push the result; a participant must pull
// the finished mosaic. On a manned session a human taps the buttons on the
// mosaic project screen — but a real unattended collaborative night (the 6.0
// demo: four rigs across three cities, owner asleep) needs the OWNER rig to
// complete the mosaic with nobody watching.
//
// [CollaborativeMosaicPoller] is that driver. It periodically sweeps this
// device's in-flight collaborative projects and, per role:
//
//   * EITHER ROLE — auto-uploads this rig's integrated-but-unuploaded panels
//     it holds the claim baton for, via
//     [CollaborativeMosaicService.uploadPanelMaster]. This is the integrate→
//     upload bridge that actually moves a captured panel into the hub: without
//     it a truly unattended rig would integrate its panel locally but never
//     push it, the hub would never reach `assembling`, and the auto-assembly
//     below would never fire. The upload only runs when the user has recorded
//     an UNATTENDED-UPLOAD consent (license + attribution + auto-upload opt-in);
//     with no such consent the rig leaves uploads manual rather than shipping
//     full-resolution pixels under a silent default.
//   * OWNER  — refreshes the hub status; when the hub reports `assembling`
//     (every panel uploaded) it runs [CollaborativeMosaicService.assembleMosaic]
//     EXACTLY ONCE (pull + stitch + push), completing the mosaic.
//   * PARTICIPANT — refreshes the hub status; when the hub reports `complete`
//     it runs [CollaborativeMosaicService.downloadOutput] once, pulling the
//     finished mosaic the owner published back to the swarm.
//
// Re-entrancy is the only real hazard: a native stitch spans minutes, so a naive
// timer would fire `assembleMosaic` again on the next tick while the first is
// still running (and again, and again). The poller guards with a per-project
// in-flight set AND a whole-sweep guard, and leans on `assembleMosaic`'s own
// hub-status==assembling re-check + abort-on-unpullable-panel so it can never
// publish an incomplete mosaic even if a force-release reverts the mosaic to
// `open` mid-flight.

import 'dart:async';

import '../../database/daos/mosaic_panels_dao.dart';
import '../../database/daos/mosaic_projects_dao.dart';
import '../../models/imaging/mosaic_project.dart' show MosaicProject;
import '../constellation/constellation_models.dart'
    show CollabMosaic, ConstellationException;
import '../logging_service.dart';
import 'collaborative_mosaic_service.dart';
import 'mosaic_upload_consent.dart';

/// Periodic, unattended driver that completes collaborative mosaics on the
/// owner rig (auto-assemble) and pulls the finished mosaic on participant rigs
/// (auto-download), so a collaborative night finishes with nobody watching.
class CollaborativeMosaicPoller {
  CollaborativeMosaicPoller({
    required CollaborativeMosaicService service,
    required MosaicProjectsDao projectsDao,
    required MosaicPanelsDao panelsDao,
    required LoggingService logger,
    MosaicUploadConsentResolver? uploadConsentResolver,
    Duration interval = const Duration(minutes: 2),
  }) : _service = service,
       _projectsDao = projectsDao,
       _panelsDao = panelsDao,
       _logger = logger,
       _uploadConsentResolver = uploadConsentResolver,
       _interval = interval;

  final CollaborativeMosaicService _service;
  final MosaicProjectsDao _projectsDao;
  final MosaicPanelsDao _panelsDao;
  final LoggingService _logger;

  /// Resolves the persisted UNATTENDED-upload consent. Null (or a resolved
  /// consent whose [MosaicUploadConsent.autoUpload] is false) keeps panel
  /// uploads manual — the poller never ships full-resolution pixels with no
  /// recorded opt-in.
  final MosaicUploadConsentResolver? _uploadConsentResolver;
  final Duration _interval;

  static const _logSource = 'CollaborativeMosaicPoller';

  Timer? _timer;

  /// Projects whose terminal action (assemble / download) is currently running,
  /// so a later tick never re-fires it while the first call is still in flight.
  final Set<int> _inFlight = <int>{};

  /// Guards a whole sweep so a slow [pollOnce] cannot overlap with the next
  /// timer tick (the per-project set guards the long action; this guards the
  /// list+refresh pass).
  bool _sweeping = false;

  /// True once [start] has armed the periodic timer (and not yet [stop]ped).
  bool get isRunning => _timer != null;

  /// Arm the periodic sweep. Idempotent — a second call while running is a
  /// no-op. Does not fire immediately; the first sweep runs after [interval]
  /// (the hub needs time to collect panels before there is anything to do).
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_interval, (_) => unawaited(pollOnce()));
    _logger.info(
      'Started collaborative-mosaic auto-driver (every '
      '${_interval.inSeconds}s).',
      source: _logSource,
    );
  }

  /// Cancel the periodic sweep. In-flight terminal actions are NOT interrupted
  /// (they are short native stitches/pulls and own their own cleanup); only the
  /// scheduling stops. Idempotent.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Run one sweep: for every in-flight collaborative project this device owns
  /// or participates in, refresh the hub status and drive the terminal action
  /// when the hub is ready. Never throws — a per-project failure is logged and
  /// the sweep continues, so one wedged mosaic cannot stall the others.
  Future<void> pollOnce() async {
    if (_sweeping) return;
    _sweeping = true;
    try {
      final projects = await _projectsDao.listActiveCollaborative();
      for (final project in projects) {
        final projectId = project.id;
        if (projectId == null) continue;
        // A terminal action for this project is already in flight (a
        // multi-minute native stitch) — skip until it resolves and clears the
        // guard.
        if (_inFlight.contains(projectId)) continue;
        // Push any of this rig's captured+integrated panels into the hub FIRST
        // (the integrate→upload bridge), so the next status refresh can see the
        // hub flip to `assembling` once the final panel lands.
        try {
          await _autoUpload(project);
        } on Object catch (e) {
          _logger.warning(
            'Auto-upload pass for project $projectId failed: $e',
            source: _logSource,
          );
        }
        try {
          await _drive(projectId, project.collabRole);
        } on Object catch (e) {
          _logger.warning(
            'Auto-driver pass for project $projectId failed: $e',
            source: _logSource,
          );
        }
      }
    } on Object catch (e) {
      _logger.warning('Auto-driver sweep failed: $e', source: _logSource);
    } finally {
      _sweeping = false;
    }
  }

  /// Auto-upload this rig's integrated-but-unuploaded panels for a published
  /// [project] — the unattended integrate→upload bridge.
  ///
  /// Gated on the persisted UNATTENDED-upload consent: with no resolver, no
  /// recorded consent, or `autoUpload == false`, this is a no-op (uploads stay
  /// manual — the rig never ships full-resolution pixels without an explicit
  /// opt-in). When consent is granted, every panel this device CLAIMED (holds
  /// the baton for), has INTEGRATED, and has NOT yet uploaded is pushed under
  /// the user's recorded license + attribution choice. Per-panel failures are
  /// logged and skipped so one bad panel never stalls the rest.
  Future<void> _autoUpload(MosaicProject project) async {
    final projectId = project.id;
    if (projectId == null) return;
    // Only a published mosaic has hub panels to receive an upload.
    final hubMosaicId = project.hubMosaicId;
    if (hubMosaicId == null || hubMosaicId.isEmpty) return;

    final resolver = _uploadConsentResolver;
    if (resolver == null) return;
    final consent = await resolver();
    if (consent == null || !consent.autoUpload) return;

    final panels = await _panelsDao.getForProject(projectId);
    for (final panel in panels) {
      // Only upload panels this rig actually captured: it must hold the claim
      // baton, carry an integrated master, and not be uploaded already.
      if (!panel.isClaimed || !panel.isIntegrated || panel.isUploaded) {
        continue;
      }
      try {
        await _service.uploadPanelMaster(
          projectId,
          panel.panelIndex,
          license: consent.license,
          attributionConsent: consent.attributionConsent,
        );
        _logger.info(
          'Auto-uploaded integrated panel ${panel.panelIndex} of mosaic '
          '$hubMosaicId (project $projectId).',
          source: _logSource,
        );
      } on Object catch (e) {
        _logger.warning(
          'Auto-upload of panel ${panel.panelIndex} (project $projectId) '
          'failed: $e',
          source: _logSource,
        );
      }
    }
  }

  /// Refresh [projectId]'s hub status and, when the hub is ready, fire the
  /// role-appropriate terminal action exactly once.
  Future<void> _drive(int projectId, String? role) async {
    // refreshStatus mirrors the hub status into collab_status and returns the
    // live mosaic; null means the project is not (or no longer) published.
    final CollabMosaic? mosaic;
    try {
      mosaic = await _service.refreshStatus(projectId);
    } on ConstellationException catch (e) {
      // Hub briefly unreachable / auth not configured — retry next sweep.
      _logger.debug(
        'Auto-driver could not refresh project $projectId: ${e.message}',
        source: _logSource,
      );
      return;
    }
    if (mosaic == null) return;

    if (role == 'owner') {
      if (mosaic.status == 'assembling') {
        await _runOnce(projectId, () async {
          _logger.info(
            'Auto-assembling owner mosaic ${mosaic!.mosaicId} '
            '(project $projectId) — all panels in.',
            source: _logSource,
          );
          await _service.assembleMosaic(projectId);
        });
      }
      return;
    }

    // Participant (or any non-owner linked role): pull the finished mosaic once
    // the owner has published it back to the swarm.
    if (mosaic.status == 'complete') {
      await _runOnce(projectId, () async {
        _logger.info(
          'Auto-downloading finished mosaic ${mosaic!.mosaicId} '
          '(participant project $projectId).',
          source: _logSource,
        );
        await _service.downloadOutput(projectId);
      });
    }
  }

  /// Run [action] for [projectId] under the in-flight guard so a later tick
  /// cannot start a second copy while this one runs.
  Future<void> _runOnce(int projectId, Future<void> Function() action) async {
    if (!_inFlight.add(projectId)) return;
    try {
      await action();
    } finally {
      _inFlight.remove(projectId);
    }
  }
}
