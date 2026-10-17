// Client-side orchestration for distributed collaborative mosaics.
//
// [ConstellationClient] is the raw REST surface (publish / claim / upload /
// download / assemble endpoints); this service is the workflow on top of it that
// the controller + headless seam drive:
//
//   * PUBLISH a durable MosaicProject's panel grid to the hub so its panels
//     become claimable distributed work items (persists hub_mosaic_id +
//     collab_role=owner),
//   * CLAIM panels with the hand-off baton (persists the claim token +
//     assigned account/rig provenance on each panel),
//   * UPLOAD a claimed panel's locally-integrated master FITS to the hub (only
//     a WCS-bearing, plate-solved master — an un-solved panel would be silently
//     dropped by the stitch >= 2-WCS-panel gate),
//   * ASSEMBLE (owner-only): pull every panel master the swarm uploaded, run the
//     EXISTING [MosaicProjectService.stitchProject] (the only real stitcher —
//     the pure-Dart hub cannot run the native gnomonic feather-blend), and push
//     the finished mosaic back so the hub serves it to every participant.
//
// Construction mirrors [ConstellationService]: a credentials resolver + an
// injectable client factory (so it is exercised with a `package:http/testing`
// MockClient) + a logger, kept DB-agnostic via resolvers.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../../database/daos/integrated_masters_dao.dart';
import '../../database/daos/mosaic_panels_dao.dart';
import '../../database/daos/mosaic_projects_dao.dart';
import '../../models/collaboration/collaboration_models.dart'
    show ContributionLicense;
import '../../models/imaging/integrated_master.dart'
    show AccumulationMode, IntegratedMaster, IntegratedMasterStatus;
import '../../models/imaging/mosaic_project.dart';
import '../constellation/constellation_client.dart';
import '../constellation/constellation_models.dart';
import '../constellation/constellation_service.dart'
    show ConstellationClientFactory, ConstellationCredentials;
import '../logging_service.dart';
import '../mosaic_project_service.dart';
import '../science/fits_header_writer.dart';
import 'mosaic_upload_consent.dart';

/// Resolves the temp directory a collaborative mosaic's pulled panel masters +
/// stitched output land in during assembly. Injected so the production wiring
/// uses the app support dir while tests use a [Directory.systemTemp] path.
typedef MosaicAssemblyDirResolver = Future<String> Function(String mosaicId);

/// Resolves the persisted mosaic-upload consent (the user's license + anonymity
/// + auto-upload choice), or null when no consent is on record. Injected so the
/// unattended/headless upload paths can fail closed without an interactive
/// sheet; the production wiring reads it from settings.
typedef MosaicUploadConsentResolver = Future<MosaicUploadConsent?> Function();

/// Client-side orchestration for collaborative mosaics.
class CollaborativeMosaicService {
  CollaborativeMosaicService({
    required Future<ConstellationCredentials?> Function() credentialsResolver,
    required MosaicProjectsDao projectsDao,
    required MosaicPanelsDao panelsDao,
    required IntegratedMastersDao mastersDao,
    required MosaicProjectService projectService,
    required LoggingService logger,
    required MosaicAssemblyDirResolver assemblyDirResolver,
    Future<String?> Function()? accountIdResolver,
    String? Function()? rigIdResolver,
    MosaicUploadConsentResolver? uploadConsentResolver,
    ConstellationClientFactory? clientFactory,
  }) : _credentialsResolver = credentialsResolver,
       _projectsDao = projectsDao,
       _panelsDao = panelsDao,
       _mastersDao = mastersDao,
       _projectService = projectService,
       _logger = logger,
       _assemblyDirResolver = assemblyDirResolver,
       _accountIdResolver = accountIdResolver,
       _rigIdResolver = rigIdResolver,
       _uploadConsentResolver = uploadConsentResolver,
       _clientFactory = clientFactory ?? _defaultClientFactory;

  final Future<ConstellationCredentials?> Function() _credentialsResolver;
  final MosaicProjectsDao _projectsDao;
  final MosaicPanelsDao _panelsDao;
  final IntegratedMastersDao _mastersDao;
  final MosaicProjectService _projectService;
  final LoggingService _logger;
  final MosaicAssemblyDirResolver _assemblyDirResolver;
  final Future<String?> Function()? _accountIdResolver;
  final String? Function()? _rigIdResolver;
  final MosaicUploadConsentResolver? _uploadConsentResolver;
  final ConstellationClientFactory _clientFactory;

  static const _logSource = 'CollaborativeMosaicService';

  static ConstellationClient _defaultClientFactory(
    ConstellationCredentials c,
  ) =>
      ConstellationClient(hubBaseUrl: c.hubBaseUrl, bearerToken: c.bearerToken);

  Future<ConstellationClient> _requireClient() async {
    final creds = await _credentialsResolver();
    if (creds == null) {
      throw const ConstellationException(
        'No Constellation hub is configured. Sign in to a hub first.',
        kind: ConstellationErrorKind.auth,
      );
    }
    return _clientFactory(creds);
  }

  // Publish

  /// Publish [projectId]'s panel grid to the hub as a collaborative mosaic.
  /// Persists `hub_mosaic_id` + `collab_role = owner` on the project. Returns the
  /// created hub mosaic.
  Future<CollabMosaic> publishProject(int projectId) async {
    final project = await _projectsDao.getById(projectId);
    if (project == null) {
      throw ArgumentError('no mosaic project with id $projectId');
    }
    final panels = await _panelsDao.getForProject(projectId);
    if (panels.isEmpty) {
      throw StateError('mosaic project $projectId has no panels to publish');
    }
    // Panel centres are stored in RA HOURS / Dec degrees; the hub works in
    // degrees, so convert RA at the boundary. The mosaic centre is the mean of
    // the panel centres (the same point the grid was generated about) — a
    // CIRCULAR mean in RA, because a grid straddling the 0h seam has panels at
    // both 358.6 and 1.4 degrees, whose arithmetic mean is 180 degrees away
    // from the mosaic (a 5-panel row at 358.595/359.298/0/0.702/1.405 averages
    // to 144.0).
    final raDegs = <double>[];
    var decSum = 0.0;
    final panelSpecs =
        <({int panelIndex, double centerRaDeg, double centerDecDeg})>[];
    for (final panel in panels) {
      final raDeg = panel.centerRa * 15.0;
      raDegs.add(raDeg);
      decSum += panel.centerDec;
      panelSpecs.add((
        panelIndex: panel.panelIndex,
        centerRaDeg: raDeg,
        centerDecDeg: panel.centerDec,
      ));
    }
    final client = await _requireClient();
    try {
      final mosaic = await client.publishMosaic(
        name: project.name,
        rows: project.rows,
        cols: project.cols,
        centerRaDeg: _circularMeanDegrees(raDegs),
        centerDecDeg: decSum / panels.length,
        overlapPct: project.overlapPct,
        positionAngleDeg: project.positionAngleDeg,
        panels: panelSpecs,
      );
      await _projectsDao.setHubMosaic(projectId, mosaic.mosaicId, 'owner');
      _logger.info(
        'Published mosaic project $projectId to hub as ${mosaic.mosaicId} '
        '(${panels.length} panels).',
        source: _logSource,
      );
      return mosaic;
    } finally {
      client.close();
    }
  }

  /// Record that this device JOINED a hub mosaic as a participant — links the
  /// local project to [hubMosaicId] with `collab_role = participant` so its
  /// claim/upload calls resolve the hub mosaic. Idempotent.
  ///
  /// Throws [ArgumentError] when [projectId] names no local project. The link
  /// is an UPDATE, so without this check a join against a missing project
  /// updates zero rows and still reports success — the caller is told it is a
  /// participant while nothing was recorded, and every later claim/upload then
  /// fails for a reason the join already knew.
  Future<void> joinAsParticipant(int projectId, String hubMosaicId) async {
    final changed = await _projectsDao.setHubMosaic(
      projectId,
      hubMosaicId,
      'participant',
    );
    if (changed == 0) {
      throw ArgumentError('no mosaic project with id $projectId');
    }
  }

  /// JOIN a hub [mosaic] discovered in the swarm browser as a participant,
  /// creating the local mirror the claim/upload/download flow needs.
  ///
  /// A participant rig has no local [MosaicProject] for a peer's published
  /// mosaic, so [joinAsParticipant] (which links an EXISTING project) cannot be
  /// reached from the browser. This creates a durable local project mirroring
  /// the hub grid (rows × cols, overlap, PA) and its panels — converting the
  /// hub's RA DEGREES back to the RA HOURS the local panel rows store — then
  /// links it as a participant and returns the new project id so the caller can
  /// open the mosaic project screen and claim panels.
  ///
  /// Idempotent: if this device already has a local project linked to the same
  /// hub mosaic (a prior join, or the owner's own published project), its id is
  /// returned unchanged — no duplicate project, and an owner's `owner` role is
  /// left intact rather than being downgraded to `participant`.
  Future<int> joinMosaicAsParticipant(CollabMosaic mosaic) async {
    final existing = await _projectsDao.getByHubMosaicId(mosaic.mosaicId);
    if (existing?.id != null) return existing!.id!;

    // The cheap list payload omits panels; pull the detail so the local mirror
    // carries the real per-panel centres (the claim/upload join key).
    final detail = mosaic.panels.isNotEmpty
        ? mosaic
        : await getMosaic(mosaic.mosaicId);

    final projectId = await _projectsDao.create(
      name: detail.name,
      rows: detail.rows,
      cols: detail.cols,
      overlapPct: detail.overlapPct,
      positionAngleDeg: detail.positionAngleDeg,
    );
    for (final panel in detail.panels) {
      await _panelsDao.upsert(
        projectId: projectId,
        panelIndex: panel.panelIndex,
        // Hub centres are in RA DEGREES; local panel rows store RA HOURS.
        centerRa: panel.centerRaDeg / 15.0,
        centerDec: panel.centerDecDeg,
      );
    }
    await joinAsParticipant(projectId, mosaic.mosaicId);
    _logger.info(
      'Joined hub mosaic ${mosaic.mosaicId} as participant — local project '
      '$projectId mirrors ${detail.panels.length} panels.',
      source: _logSource,
    );
    return projectId;
  }

  // Claim

  /// Claim [indices] of [projectId]'s published mosaic via the hub baton.
  /// Persists each panel's claim token + assigned account/rig provenance.
  /// Returns the granted claims (a panel held by another rig is skipped).
  Future<List<MosaicPanelClaim>> claimPanels(
    int projectId,
    List<int> indices,
  ) async {
    final hubMosaicId = await _requireHubMosaicId(projectId);
    final panels = await _panelsDao.getForProject(projectId);
    final byIndex = <int, MosaicProjectPanel>{
      for (final p in panels) p.panelIndex: p,
    };
    final rigId = _rigIdResolver?.call();
    final accountId = await _resolveAccountId();
    final client = await _requireClient();
    final claims = <MosaicPanelClaim>[];
    try {
      for (final index in indices) {
        final panel = byIndex[index];
        if (panel?.id == null) {
          _logger.warning(
            'claimPanels: project $projectId has no panel index $index — '
            'skipped.',
            source: _logSource,
          );
          continue;
        }
        try {
          final claim = await client.claimPanel(
            hubMosaicId,
            index,
            rigId: rigId,
          );
          await _panelsDao.setClaim(
            panel!.id!,
            claimToken: claim.claimToken,
            rigId: rigId,
            accountId: accountId,
          );
          claims.add(claim);
        } on ConstellationException catch (e) {
          if (e.kind == ConstellationErrorKind.conflict) {
            // Held by another rig — skip, do not abort the batch.
            _logger.info(
              'claimPanels: panel $index already held by another rig — skipped.',
              source: _logSource,
            );
            continue;
          }
          rethrow;
        }
      }
      return claims;
    } finally {
      client.close();
    }
  }

  /// Release a claimed panel back to the pool.
  ///
  /// Clears the LOCAL claim record too when the hub accepted the release: the
  /// stored `claim_token` is the credential upload presents, so leaving it
  /// behind would let a later upload attempt push under a claim this rig no
  /// longer holds and be rejected by the hub for a reason the local state does
  /// not show.
  Future<bool> releasePanel(int projectId, int panelIndex) async {
    final hubMosaicId = await _requireHubMosaicId(projectId);
    final client = await _requireClient();
    try {
      final released = await client.releasePanel(hubMosaicId, panelIndex);
      if (released) {
        final panel = await _panelsDao.getByIndex(projectId, panelIndex);
        final panelId = panel?.id;
        if (panelId != null) {
          await _panelsDao.clearClaim(panelId);
        }
      }
      return released;
    } finally {
      client.close();
    }
  }

  /// Owner/admin recovery: force-release [panelIndex] of [projectId] even when
  /// it is held by another rig or already carries an uploaded master — the
  /// eviction path the per-account [releasePanel] cannot provide. The hub
  /// enforces that only the mosaic owner or an admin may do this and resets the
  /// slot to `pending` (clearing any uploaded master), so a squatting claim or a
  /// poisoned upload can be re-opened for a fresh rig. Returns whether a panel
  /// was evicted.
  Future<bool> forceReleasePanel(int projectId, int panelIndex) async {
    final hubMosaicId = await _requireHubMosaicId(projectId);
    final client = await _requireClient();
    try {
      return await client.forceReleasePanel(hubMosaicId, panelIndex);
    } finally {
      client.close();
    }
  }

  // Upload

  /// Upload the locally-integrated master for [panelIndex] of [projectId] to the
  /// hub. Resolves the panel's `integrated_masters` master FITS (built by
  /// [MosaicProjectService.integratePanels]), ENSURES it carries a WCS in its
  /// HEADER — stamping the DB-only persisted CD-matrix into the header when only
  /// the DB has it, since the DB never travels and an un-self-describing panel
  /// would be silently dropped by the stitch gate — pushes it under the held
  /// claim, and records the uploaded master id.
  ///
  /// Consent gate: a panel master is full-resolution integrated data, so it
  /// only leaves the device under an EXPLICIT sharing [license] + attribution
  /// ([attributionConsent]) choice — either passed directly (the interactive
  /// contribute sheet / the unattended poller, which present/resolve the choice)
  /// or, when both are omitted, resolved from the persisted consent record (the
  /// headless endpoint). Fails CLOSED: with no explicit choice and no recorded
  /// consent — or a non-shareable license — the upload is refused rather than
  /// defaulting to a silent ccBy + forced name attribution.
  Future<CollabMosaicPanel> uploadPanelMaster(
    int projectId,
    int panelIndex, {
    ContributionLicense? license,
    bool? attributionConsent,
  }) async {
    final consent = await _resolveUploadConsent(license, attributionConsent);
    final hubMosaicId = await _requireHubMosaicId(projectId);
    final panel = await _panelsDao.getByIndex(projectId, panelIndex);
    if (panel == null || panel.id == null) {
      throw ArgumentError(
        'mosaic project $projectId has no panel index $panelIndex',
      );
    }
    final masterId = panel.integratedMasterId;
    if (masterId == null) {
      throw StateError(
        'panel $panelIndex has no integrated master to upload — integrate it '
        'first',
      );
    }
    final master = await _mastersDao.getById(masterId);
    final fitsPath = master?.masterFitsPath;
    if (master == null || fitsPath == null || fitsPath.trim().isEmpty) {
      throw StateError(
        'panel $panelIndex master has no FITS path on disk to upload',
      );
    }
    // WCS gate: the uploaded FITS must SELF-DESCRIBE its WCS — the DB never
    // travels to the hub, so a DB-only-solved master (CRVAL/CD persisted in
    // integrated_masters by the post-session plate-solve but never stamped into
    // the FITS header) would reach the assembler header-less and be silently
    // dropped by stitchProject's >= 2-WCS-panel gate. If the header already
    // carries a WCS, ship as-is; else stamp the persisted CD-matrix into the
    // header so the bytes carry it; else the panel is genuinely un-plate-solved
    // and the upload is refused up front rather than poisoning the assembly.
    if (!await _fitsHeaderHasWcs(fitsPath)) {
      if (master.hasWcs) {
        await _stampWcsHeader(master, fitsPath);
      } else {
        throw StateError(
          'panel $panelIndex master is not plate-solved (no WCS) — plate-solve '
          'it before uploading or assembly will drop it',
        );
      }
    }
    final rigId = _rigIdResolver?.call();
    final client = await _requireClient();
    try {
      final uploaded = await client.pushPanelMaster(
        hubMosaicId,
        panelIndex,
        fitsPath,
        license: consent.license.wireName,
        rigId: rigId,
        claimToken: panel.claimToken,
        attributionConsent: consent.attributionConsent,
      );
      await _panelsDao.setUploaded(panel.id!, masterId);
      _logger.info(
        'Uploaded panel $panelIndex master ($fitsPath) for project $projectId.',
        source: _logSource,
      );
      return uploaded;
    } finally {
      client.close();
    }
  }

  // Assemble (owner)

  /// Owner-only central assembly for a mosaic the hub has moved to `assembling`:
  /// pull EVERY panel master the swarm uploaded into a temp dir, link each onto
  /// its local panel, run the EXISTING [MosaicProjectService.stitchProject] (the
  /// only real stitcher — the pure-Dart hub cannot run the native gnomonic
  /// feather-blend), then push the finished mosaic back so the hub serves it to
  /// every participant. Marks the project `collab_status = complete`.
  ///
  /// Returns the stitch outcome ([MosaicStitchOutcome]) so the caller can report
  /// panel/skip counts.
  Future<MosaicStitchOutcome> assembleMosaic(int projectId) async {
    final project = await _projectsDao.getById(projectId);
    if (project == null) {
      throw ArgumentError('no mosaic project with id $projectId');
    }
    final hubMosaicId = project.hubMosaicId;
    if (hubMosaicId == null || hubMosaicId.isEmpty) {
      throw StateError(
        'project $projectId is not a published collaborative '
        'mosaic',
      );
    }
    if (project.collabRole != 'owner') {
      throw StateError(
        'only the mosaic owner may assemble; this device is '
        '${project.collabRole ?? 'not a participant'}',
      );
    }
    final panels = await _panelsDao.getForProject(projectId);
    if (panels.isEmpty) {
      throw StateError('mosaic project $projectId has no panels to assemble');
    }
    final dir = await _assemblyDirResolver(hubMosaicId);
    await Directory(dir).create(recursive: true);

    final client = await _requireClient();
    try {
      // All-panels-uploaded gate: the hub only flips a mosaic to `assembling`
      // once EVERY panel has landed. Refuse to assemble (and publish) until the
      // hub reports `assembling`, so a premature/partial assemble can never push
      // an incomplete mosaic that the hub then serves to all participants as the
      // finished result. Keep the local mirror of the status in sync while here.
      final hubMosaic = await client.getMosaic(hubMosaicId);
      await _projectsDao.setCollabStatus(projectId, hubMosaic.status);
      if (hubMosaic.status != 'assembling') {
        throw StateError(
          'mosaic $hubMosaicId is not ready to assemble (hub status '
          '"${hubMosaic.status}") — assembly is gated until every panel has '
          'been uploaded',
        );
      }
      // Pull each panel's authoritative hub master + (re)link it onto the local
      // panel so the existing stitcher consumes the swarm's contributions. The
      // mosaic is `assembling`, so every panel MUST have an uploaded master on
      // the hub — a 404 here means the hub state is inconsistent, so abort
      // rather than silently stitch + publish an incomplete mosaic.
      for (final panel in panels) {
        final panelId = panel.id;
        if (panelId == null) continue;
        final outPath = '$dir/panel_${panel.panelIndex}.fits';
        try {
          await client.pullPanelMaster(hubMosaicId, panel.panelIndex, outPath);
        } on ConstellationException catch (e) {
          if (e.kind == ConstellationErrorKind.notFound) {
            throw StateError(
              'panel ${panel.panelIndex} of mosaic $hubMosaicId reports the '
              'mosaic is assembling but its master could not be pulled — '
              'aborting assembly rather than publishing an incomplete mosaic',
            );
          }
          rethrow;
        }
        // Persist a master row pointing at the pulled FITS and link it. The
        // pulled panel masters are plate-solved (WCS in the header), which
        // stitchProject reads via the [_fitsHeaderHasWcs] probe. Geometry is
        // read from the same header — a swarm panel arrives as bare bytes, so
        // a 0x0 row would misreport every contributor's panel in the UI.
        final (panelWidth, panelHeight) = await _fitsImageSize(outPath);
        final newMasterId = await _mastersDao.insertMaster(
          targetId: project.targetId,
          name: '${project.name} Panel ${panel.panelIndex + 1} (hub)',
          masterFitsPath: outPath,
          status: IntegratedMasterStatus.finalized,
          accumulationMode: AccumulationMode.batch,
          width: panelWidth,
          height: panelHeight,
        );
        await _panelsDao.setMaster(panelId, newMasterId);
      }

      final outcome = await _projectService.stitchProject(
        projectId,
        outputDirectory: dir,
        fitsHasWcs: _fitsHeaderHasWcs,
      );

      // Push the finished mosaic so the hub republishes it to all participants.
      final stitched = await _mastersDao.getById(outcome.outputMasterId);
      final outFits = stitched?.masterFitsPath;
      if (outFits == null || outFits.trim().isEmpty) {
        throw StateError('stitched mosaic has no output FITS path to upload');
      }
      await client.pushMosaicOutput(hubMosaicId, outFits);
      await _projectsDao.setCollabStatus(projectId, 'complete');
      _logger.info(
        'Assembled + published mosaic $hubMosaicId from '
        '${outcome.panelCount} panels (${outcome.skips.length} skipped).',
        source: _logSource,
      );
      return outcome;
    } finally {
      client.close();
    }
  }

  // Read

  /// List open/claimable collaborative mosaics on the configured hub.
  Future<List<CollabMosaic>> listMosaics() async {
    final client = await _requireClient();
    try {
      return await client.listMosaics();
    } finally {
      client.close();
    }
  }

  /// Fetch one hub mosaic's live state (per-panel claim/upload/output).
  Future<CollabMosaic> getMosaic(String hubMosaicId) async {
    final client = await _requireClient();
    try {
      return await client.getMosaic(hubMosaicId);
    } finally {
      client.close();
    }
  }

  /// The authoritative contributor-credit list the hub materialized for this
  /// mosaic (`GET /v1/attribution` keyed `mosaic`/[hubMosaicId]) — the source
  /// for contributor credits, read back consent-aware from the hub rather than
  /// reconstructed from the browse payload.
  Future<ArtifactAttribution> fetchMosaicAttribution(String hubMosaicId) async {
    final client = await _requireClient();
    try {
      return await client.fetchAttribution(
        artifactType: 'mosaic',
        artifactRef: hubMosaicId,
      );
    } finally {
      client.close();
    }
  }

  /// Refresh [projectId]'s local `collab_status` from the hub (e.g. the owner
  /// polling for `assembling`, or a participant polling for `complete`). Returns
  /// the hub mosaic, or null when the project is not published.
  Future<CollabMosaic?> refreshStatus(int projectId) async {
    final project = await _projectsDao.getById(projectId);
    final hubMosaicId = project?.hubMosaicId;
    if (hubMosaicId == null || hubMosaicId.isEmpty) return null;
    final mosaic = await getMosaic(hubMosaicId);
    await _projectsDao.setCollabStatus(projectId, mosaic.status);
    return mosaic;
  }

  /// Download the FINISHED collaborative mosaic the owner assembled + republished
  /// — the participant (or owner) end of the "publish the finished mosaic to
  /// every participant" loop. Pulls the hub's stitched output FITS, persists it
  /// as an `integrated_masters` row linked as the project's output, and marks the
  /// project `collab_status = complete`, so a participant rig's project surfaces
  /// the finished mosaic exactly as the owner's does after [assembleMosaic].
  ///
  /// The FITS always lands at a fixed name under the project's hub-scoped
  /// assembly dir — the destination is never caller-supplied, so an untrusted
  /// remote seam cannot steer the hub-served bytes to an arbitrary filesystem
  /// path. Returns the on-disk path of the pulled mosaic. Throws (via
  /// [ConstellationClient.pullMosaicOutput]) with
  /// [ConstellationErrorKind.notFound] when the mosaic is not complete yet.
  Future<String> downloadOutput(int projectId) async {
    final project = await _projectsDao.getById(projectId);
    if (project == null) {
      throw ArgumentError('no mosaic project with id $projectId');
    }
    final hubMosaicId = project.hubMosaicId;
    if (hubMosaicId == null || hubMosaicId.isEmpty) {
      throw StateError(
        'project $projectId is not a published collaborative mosaic',
      );
    }
    final dir = await _assemblyDirResolver(hubMosaicId);
    await Directory(dir).create(recursive: true);
    final dest = '$dir/mosaic_output.fits';
    final client = await _requireClient();
    try {
      await client.pullMosaicOutput(hubMosaicId, dest);
      // Geometry comes from the pulled bytes: the hub ships a FITS, not a row,
      // so without this the participant's copy of the finished mosaic records
      // itself as 0x0 while the file on disk is full size.
      final (outWidth, outHeight) = await _fitsImageSize(dest);
      final masterId = await _mastersDao.insertMaster(
        targetId: project.targetId,
        name: '${project.name} (collaborative mosaic)',
        masterFitsPath: dest,
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
        width: outWidth,
        height: outHeight,
      );
      await _projectsDao.setOutputMaster(projectId, masterId);
      await _projectsDao.setCollabStatus(projectId, 'complete');
      _logger.info(
        'Downloaded finished collaborative mosaic $hubMosaicId to $dest for '
        'project $projectId.',
        source: _logSource,
      );
      return dest;
    } finally {
      client.close();
    }
  }

  // Internals

  /// Resolve the consent a panel-master upload ships under, failing CLOSED.
  ///
  ///   * both [license] + [attributionConsent] given → an explicit interactive
  ///     / poller choice; used as-is (the license must be shareable);
  ///   * neither given → resolve the persisted consent record via the injected
  ///     resolver; absence (no record, or no resolver) refuses the upload;
  ///   * exactly one given → ambiguous, rejected — a caller must commit to a
  ///     full consent or defer entirely to the persisted record.
  Future<MosaicUploadConsent> _resolveUploadConsent(
    ContributionLicense? license,
    bool? attributionConsent,
  ) async {
    final MosaicUploadConsent consent;
    if (license != null && attributionConsent != null) {
      consent = MosaicUploadConsent(
        license: license,
        attributionConsent: attributionConsent,
      );
    } else if (license == null && attributionConsent == null) {
      final resolved = await _uploadConsentResolver?.call();
      if (resolved == null) {
        throw const ConstellationException(
          'This panel master cannot be uploaded without consent. Choose a '
          'sharing license and attribution preference first.',
          kind: ConstellationErrorKind.auth,
        );
      }
      consent = resolved;
    } else {
      throw ArgumentError(
        'uploadPanelMaster requires both license and attributionConsent, or '
        'neither (to use the persisted consent record).',
      );
    }
    if (!consent.license.isShareable) {
      throw StateError(
        'cannot upload a panel master under a non-shareable license '
        '(${consent.license.wireName})',
      );
    }
    return consent;
  }

  Future<String> _requireHubMosaicId(int projectId) async {
    final project = await _projectsDao.getById(projectId);
    if (project == null) {
      throw ArgumentError('no mosaic project with id $projectId');
    }
    final hubMosaicId = project.hubMosaicId;
    if (hubMosaicId == null || hubMosaicId.isEmpty) {
      throw StateError(
        'project $projectId is not published to a hub — publish it first',
      );
    }
    return hubMosaicId;
  }

  Future<String?> _resolveAccountId() async {
    try {
      return await _accountIdResolver?.call();
    } on Object catch (e) {
      _logger.debug('account-id resolve failed: $e', source: _logSource);
      return null;
    }
  }

  /// Stamp the master's persisted CD-matrix WCS (the `integrated_masters.wcs_*`
  /// columns the post-session plate-solve writes DB-only) into its FITS header
  /// so the uploaded bytes self-describe their astrometry. Mirrors the native
  /// `add_wcs_headers` card set exactly — the inverse of the stitcher's
  /// `wcs_from_header` — so both the assembler's header probe and the native
  /// stitch read it. CRPIX defaults to the geometric centre (1-based) when the
  /// solve omitted it, matching the native reader's fallback.
  Future<void> _stampWcsHeader(IntegratedMaster master, String fitsPath) async {
    final crval1 = master.wcsCrval1;
    final crval2 = master.wcsCrval2;
    final cd11 = master.wcsCd1_1;
    final cd22 = master.wcsCd2_2;
    if (crval1 == null || crval2 == null || cd11 == null || cd22 == null) {
      throw StateError(
        'panel master ${master.id} has an incomplete persisted WCS (CRVAL/CD) '
        '— cannot stamp it into the FITS header for upload',
      );
    }
    final crpix1 =
        master.wcsCrpix1 ?? (master.width > 0 ? master.width / 2.0 + 0.5 : 0.5);
    final crpix2 =
        master.wcsCrpix2 ??
        (master.height > 0 ? master.height / 2.0 + 0.5 : 0.5);
    await FitsHeaderWriter().updateKeywords(fitsPath, <FitsKeywordWrite>[
      FitsKeywordWrite.floating('CRVAL1', crval1),
      FitsKeywordWrite.floating('CRVAL2', crval2),
      FitsKeywordWrite.floating('CRPIX1', crpix1),
      FitsKeywordWrite.floating('CRPIX2', crpix2),
      FitsKeywordWrite.floating('CD1_1', cd11),
      FitsKeywordWrite.floating('CD1_2', master.wcsCd1_2 ?? 0.0),
      FitsKeywordWrite.floating('CD2_1', master.wcsCd2_1 ?? 0.0),
      FitsKeywordWrite.floating('CD2_2', cd22),
      FitsKeywordWrite.string('CTYPE1', 'RA---TAN'),
      FitsKeywordWrite.string('CTYPE2', 'DEC--TAN'),
      FitsKeywordWrite.string('CUNIT1', 'deg'),
      FitsKeywordWrite.string('CUNIT2', 'deg'),
      FitsKeywordWrite.floating('EQUINOX', 2000.0),
      FitsKeywordWrite.string('RADESYS', 'ICRS'),
    ]);
    _logger.info(
      'Stamped persisted CD-matrix WCS into panel master FITS header '
      '($fitsPath) before upload.',
      source: _logSource,
    );
  }

  /// Probe whether a FITS file's header carries a WCS solution. A plate-solved
  /// FITS carries a `CD1_1` (or `CDELT1`) plus a celestial `CTYPE1`. FITS headers
  /// are 80-char ASCII cards in 2880-byte blocks ending at the `END` card, so a
  /// cheap prefix read suffices — no native dependency. A read error degrades to
  /// false (treat as un-solved), never throws into the caller.
  Future<bool> _fitsHeaderHasWcs(String fitsPath) async {
    try {
      final file = File(fitsPath);
      if (!await file.exists()) return false;
      final raf = await file.open();
      try {
        // Read up to the first 16 header blocks (45 KiB) — far more than any
        // realistic primary header — and scan for the WCS keywords.
        const maxHeaderBytes = 2880 * 16;
        final len = await raf.length();
        final toRead = len < maxHeaderBytes ? len : maxHeaderBytes;
        final bytes = await raf.read(toRead);
        final text = String.fromCharCodes(bytes);
        final hasCtype =
            text.contains('CTYPE1') &&
            (text.contains('RA---') || text.contains('RA--'));
        final hasScale = text.contains('CD1_1') || text.contains('CDELT1');
        final hasRef = text.contains('CRVAL1') && text.contains('CRPIX1');
        return hasRef && (hasScale || hasCtype);
      } finally {
        await raf.close();
      }
    } on Object catch (e) {
      _logger.debug(
        'fitsHeaderHasWcs($fitsPath) failed: $e',
        source: _logSource,
      );
      return false;
    }
  }

  /// The `(width, height)` a FITS file declares in `NAXIS1`/`NAXIS2`, or
  /// `(0, 0)` when the file is missing or the keywords cannot be read.
  ///
  /// Hub-pulled masters (panel masters during assembly, and the finished mosaic
  /// a participant downloads) arrive as bare bytes with no accompanying row, so
  /// their geometry has to come from the pixels themselves. Recording 0x0
  /// instead makes every gallery, picker, and detail view report a real image as
  /// having no dimensions.
  Future<(int, int)> _fitsImageSize(String fitsPath) async {
    try {
      final file = File(fitsPath);
      if (!await file.exists()) return (0, 0);
      final raf = await file.open();
      try {
        const maxHeaderBytes = 2880 * 16;
        final len = await raf.length();
        final toRead = len < maxHeaderBytes ? len : maxHeaderBytes;
        final text = String.fromCharCodes(await raf.read(toRead));
        int axis(int n) {
          // FITS cards are fixed 80 columns: `NAXISn   = <value>`.
          final match = RegExp('NAXIS$n\\s*=\\s*(-?\\d+)').firstMatch(text);
          return int.tryParse(match?.group(1) ?? '') ?? 0;
        }

        final w = axis(1);
        final h = axis(2);
        return (w > 0 ? w : 0, h > 0 ? h : 0);
      } finally {
        await raf.close();
      }
    } on Object catch (e) {
      _logger.debug('fitsImageSize($fitsPath) failed: $e', source: _logSource);
      return (0, 0);
    }
  }
}

/// Mean of a set of angles on a circle, in degrees, normalised to [0, 360).
///
/// Averaging the raw numbers is wrong for RA: values either side of the 0h seam
/// (359.3 and 0.7) average to the antipode. Summing unit vectors and taking the
/// argument gives the direction the panels actually surround.
double _circularMeanDegrees(List<double> degrees) {
  var x = 0.0;
  var y = 0.0;
  for (final d in degrees) {
    final rad = d * math.pi / 180.0;
    x += math.cos(rad);
    y += math.sin(rad);
  }
  final mean = math.atan2(y, x) * 180.0 / math.pi;
  return (mean % 360.0 + 360.0) % 360.0;
}
