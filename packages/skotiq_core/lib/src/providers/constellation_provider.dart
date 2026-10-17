import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../database/database.dart' show CoImagingSessionRow;
import '../database/daos/coimaging_sessions_dao.dart';
import '../database/daos/constellation_contributions_dao.dart';
import '../database/daos/integrated_masters_dao.dart';
import '../database/daos/living_sky_retention_dao.dart';
import '../database/daos/mosaic_panels_dao.dart';
import '../database/daos/mosaic_projects_dao.dart';
import '../database/daos/settings_dao.dart';
import '../models/scheduler/scheduler_status.dart' show SchedulerState;
import '../services/coimaging/coimaging_session_service.dart';
import '../services/constellation/constellation_models.dart';
import '../services/constellation/constellation_service.dart';
import '../services/logging_service.dart';
import '../services/mosaic/collaborative_mosaic_service.dart';
import '../services/mosaic/mosaic_upload_consent.dart';
import '../services/mosaic_project_service.dart';
import 'database_provider.dart';
import 'scheduler_provider.dart' show schedulerEngineProvider;
import 'settings_provider.dart' show appSettingsProvider;
import 'sky_atlas_provider.dart';
import '../utils/skotiq_data_directory.dart';

/// Riverpod surface for the Constellation community hub client.
///
/// [followTheNightProvider] is read only by the Constellation screen's
/// follow-the-night card; the planner and scheduler tabs do not consume it.

/// Settings keys the hub credentials persist under (LAN-only, self-hosted).
const String constellationHubUrlSettingKey = 'constellation.hub_url';
const String constellationHubTokenSettingKey = 'constellation.hub_token';

/// Settings key the hub-issued account id persists under. Recorded at
/// registration so follow-the-night can tell whether the baton's `holder`
/// account id is *this* user (drives the "Release" affordance on held cards).
const String constellationAccountIdSettingKey = 'constellation.account_id';

/// Resolve the persisted hub account id (the id the hub records the baton
/// `holder` against), or null when the user has not registered yet.
Future<String?> resolveConstellationAccountId(SettingsDao settings) async {
  final id = await settings.getSetting(constellationAccountIdSettingKey);
  return (id == null || id.isEmpty) ? null : id;
}

/// Resolve the configured hub credentials from settings, or null when the user
/// has not signed in to any hub yet.
Future<ConstellationCredentials?> resolveConstellationCredentials(
  SettingsDao settings,
) async {
  final url = await settings.getSetting(constellationHubUrlSettingKey);
  final token = await settings.getSetting(constellationHubTokenSettingKey);
  if (url == null || url.isEmpty || token == null || token.isEmpty) {
    return null;
  }
  final parsed = Uri.tryParse(url);
  if (parsed == null || !parsed.hasScheme) return null;
  return ConstellationCredentials(hubBaseUrl: parsed, bearerToken: token);
}

/// The Constellation orchestration service.
final constellationServiceProvider = Provider<ConstellationService>((ref) {
  final settings = ref.watch(settingsDaoProvider);
  return ConstellationService(
    atlas: ref.watch(skyAtlasServiceProvider),
    logger: ref.watch(loggingServiceProvider),
    contributionsDao: ref.watch(constellationContributionsDaoProvider),
    retentionDao: ref.watch(livingSkyRetentionDaoProvider),
    credentialsResolver: () => resolveConstellationCredentials(settings),
    accountIdResolver: () => resolveConstellationAccountId(settings),
    // HOST-ONLY raw-subframe resolver: the user's own accepted LIGHT frames for
    // the target. Reads the LOCAL images table directly (never the remote-aware
    // provider), so on a slave it yields nothing and the SUBS path no-ops —
    // raw subs can only ever leak the host's own pixels, never a pulled frame.
    rawSubframeResolver: (targetId) async {
      final images = await ref
          .read(imagesDaoProvider)
          .getImagesForTarget(targetId);
      return images
          .where(
            (i) =>
                i.frameType == 'light' && i.isAccepted && i.filePath.isNotEmpty,
          )
          .map(
            (i) => RawSubframe(
              filePath: i.filePath,
              capturedImageId: i.id,
              exposureSeconds: i.exposureDuration,
            ),
          )
          .toList(growable: false);
    },
    localTargetsResolver: () async {
      // Resolve through the remote-aware targets provider so a slave maps the
      // MASTER's targets (its own local table is never populated); on the host
      // this yields the same db.Target rows the local DAO would.
      final targets = await ref.read(allDbTargetsProvider.future);
      return targets
          .map(
            (t) => (
              targetId: t.id,
              name: t.name,
              // Target rows store RA in decimal hours; the hub/atlas work in
              // degrees, so convert here at the boundary.
              raDeg: t.ra * 15.0,
              decDeg: t.dec,
            ),
          )
          .toList(growable: false);
    },
  );
});

/// Collaborative-mosaic orchestration over the configured hub. Reuses the same
/// settings-backed hub credentials Pillar C resolves, the durable mosaic
/// DAOs, and the existing [MosaicProjectService] (the only real stitcher) for
/// owner-side assembly. A no-hub config simply makes its calls throw an auth
/// error, exactly like [ConstellationService].
final collaborativeMosaicServiceProvider = Provider<CollaborativeMosaicService>(
  (ref) {
    final settings = ref.watch(settingsDaoProvider);
    return CollaborativeMosaicService(
      credentialsResolver: () => resolveConstellationCredentials(settings),
      accountIdResolver: () => resolveConstellationAccountId(settings),
      // Consent gate: the headless upload endpoint (no interactive sheet)
      // ships a panel master only under the operator's persisted license +
      // attribution choice; absence fails the upload closed.
      uploadConsentResolver: () => resolveMosaicUploadConsent(settings),
      projectsDao: ref.watch(mosaicProjectsDaoProvider),
      panelsDao: ref.watch(mosaicPanelsDaoProvider),
      mastersDao: ref.watch(integratedMastersDaoProvider),
      projectService: ref.watch(mosaicProjectServiceProvider),
      logger: ref.watch(loggingServiceProvider),
      assemblyDirResolver: (mosaicId) async {
        final dir = await resolveSkotiqDataDirectory();
        return p.join(dir.path, 'collaborative_mosaics', mosaicId);
      },
    );
  },
);

/// Live co-imaging orchestration over the configured hub. Reuses the same
/// settings-backed hub credentials Pillar C resolves, the durable
/// [CoImagingSessionsDao] (membership + assigned framing offset), and the
/// per-tile contribution receipt store (for tagging which session deepened a
/// tile). A no-hub config makes its calls throw an auth error, exactly like
/// [ConstellationService].
final coImagingSessionServiceProvider = Provider<CoImagingSessionService>((
  ref,
) {
  final settings = ref.watch(settingsDaoProvider);
  return CoImagingSessionService(
    credentialsResolver: () => resolveConstellationCredentials(settings),
    sessionsDao: ref.watch(coImagingSessionsDaoProvider),
    contributionsDao: ref.watch(constellationContributionsDaoProvider),
    logger: ref.watch(loggingServiceProvider),
    // Consent gate: reuse the SAME persisted collaborative-contribution
    // consent the mosaic upload path captures (license + attribution + the
    // unattended auto-upload opt-in), so an unattended co-imaging fold ships
    // under the operator's actual choice and FAILS CLOSED (no contribution)
    // when no consent is on record — never a silent ccBy + forced attribution.
    //
    // This resolver gates ONLY the unattended egress paths — the capture-loop
    // auto-contribute (`recordCompletedSub`) and the headless
    // sub-complete / contribute hooks — which never pass an explicit license.
    // Those are inherently unattended, so they must honour `autoUpload` exactly
    // as [CollaborativeMosaicPoller._autoUpload] does: an operator who granted
    // sharing but kept `autoUpload == false` ("share only when I initiate")
    // must NOT have their subs auto-shared. Fail closed on `!autoUpload` so the
    // fold is skipped. Interactive contributions pass an explicit license +
    // attribution and bypass this resolver entirely, so a hands-on "contribute
    // now" is unaffected.
    consentResolver: () async {
      final consent = await resolveMosaicUploadConsent(settings);
      if (consent == null || !consent.autoUpload) return null;
      return (
        license: consent.license,
        attributionConsent: consent.attributionConsent,
      );
    },
    // Capture-loop auto-contribute: a completed sub on the session target folds
    // into the SAME shared-target tile through the existing additive-sum
    // upload. The shared target is joined locally first (so the cone centre
    // resolves from the session's own coordinates without re-browsing), then
    // the unchanged `contributeTarget` `.nst` path runs under the
    // operator's consented license and return the TRUE delta the hub accepted so
    // the combined accounting equals what was fused (never a hardcoded +1).
    fusionContributor: (request) async {
      final sharedTargetId = request.sharedTargetId;
      if (sharedTargetId == null) return CoImagingFusionResult.none;
      final constellation = ref.read(constellationServiceProvider);
      constellation.joinSharedTarget(
        SharedTarget(
          targetId: sharedTargetId,
          name: request.targetName,
          raDeg: request.centerRaDeg,
          decDeg: request.centerDecDeg,
          integrationSeconds: 0.0,
          contributors: 0,
          activeTileId: request.activeTileId,
        ),
      );
      final outcome = await constellation.contributeTarget(
        sharedTargetId,
        radiusDeg: request.radiusDeg,
        license: request.license,
        attributionConsent: request.attributionConsent,
      );
      return CoImagingFusionResult(
        framesPushed: outcome.framesPushed,
        integrationSecondsPushed: outcome.integrationSecondsPushed,
        acceptedTiles: outcome.acceptedCount,
      );
    },
  );
});

/// The client-side longitude-baton scheduler. A periodic tick that,
/// for each active co-imaging membership, evaluates the session target's
/// altitude at the rig's configured site and claims/releases the baton on the
/// rise/set, resuming/pausing the autopilot so an unattended appliance hands the
/// night east without operator input.
///
/// Reading this provider builds AND starts the scheduler; disposing it stops the
/// tick. The app shell and the headless bootstrap eager-read it so it runs for
/// the lifetime of the process (it is otherwise lazy and would never tick).
final coImagingBatonSchedulerProvider = Provider<CoImagingBatonScheduler>((
  ref,
) {
  final policy = _CoImagingAutopilotBatonPolicy(ref);
  final scheduler = CoImagingBatonScheduler(
    service: ref.watch(coImagingSessionServiceProvider),
    logger: ref.watch(loggingServiceProvider),
    // Resolve the rig's site each tick from app settings (degrees). A (0,0)
    // null-island default means "no site configured" -> skip without churning
    // the baton.
    siteResolver: () async {
      final app = ref.read(appSettingsProvider).valueOrNull;
      if (app == null) return null;
      final lat = app.latitude;
      final lng = app.longitude;
      if (lat == 0.0 && lng == 0.0) return null;
      return (latitudeDeg: lat, longitudeDeg: lng);
    },
    // One reconciled engine decision per tick (see the policy below): begin
    // capture when this site takes a baton for the target the autopilot is
    // imaging, hand it east (pause) when it sets — but ONLY a pause the
    // scheduler itself authored, and never an unrelated or operator/safety run.
    onReconcile: policy.reconcile,
  );
  scheduler.start();
  ref.onDispose(scheduler.stop);
  return scheduler;
});

/// Owns the single, reconciled decision the longitude-baton scheduler hands
/// the one process-global autopilot each tick.
///
/// It pauses/resumes the autopilot ONLY for a run it itself authored and ONLY
/// while the autopilot is actually imaging the co-imaging session target, so it:
///   * never re-opens the shutter on an operator, weather/safety, or
///     meridian-flip pause it did not issue (it resumes solely the pause it
///     marked as its own, for the SAME target that set);
///   * never pauses an unrelated, non-co-imaging plan (it pauses only when the
///     autopilot's current target matches a now-set session centre);
///   * makes one deterministic call per tick from the aggregated
///     [CoImagingBatonReconciliation], so two memberships can never thrash the
///     shared engine within a tick.
///
/// A co-imaging session is identified by its sky centre; the autopilot images a
/// local catalog target by id. They are linked by angular proximity (the same
/// [CoImagingSessionService.membershipMatchToleranceDeg] the frame/slew matcher
/// uses), resolving the engine's `currentTargetId` to coordinates via the local
/// targets table.
class _CoImagingAutopilotBatonPolicy {
  _CoImagingAutopilotBatonPolicy(this._ref);

  final Ref _ref;

  /// The autopilot target this scheduler paused when it set (null = no
  /// baton-authored pause outstanding). resume() is issued only against this
  /// exact pause, and only when the SAME target's baton is held again.
  int? _pausedTargetId;

  Future<void> reconcile(CoImagingBatonReconciliation r) async {
    final engine = _ref.read(schedulerEngineProvider);
    final status = engine.status;

    // --- Resume path: only a pause WE authored, only the SAME target, only
    //     while the engine is still in that pause. ---
    final pausedId = _pausedTargetId;
    if (pausedId != null) {
      if (status.state != SchedulerState.paused) {
        // The pause we authored no longer holds (the operator resumed/stopped,
        // or the run ended) — disown it so we never resume a run we don't own.
        _pausedTargetId = null;
      } else if (r.anyHeld && await _anyMatches(pausedId, r.held)) {
        await engine.resume();
        _pausedTargetId = null;
        return;
      }
    }

    // --- Pause path: only when the autopilot is RUNNING and actually imaging
    //     one of the now-released co-imaging targets (leave unrelated plans and
    //     already-paused/idle engines alone). ---
    if (status.state == SchedulerState.running && r.released.isNotEmpty) {
      final currentId = status.currentTargetId;
      if (currentId != null && await _anyMatches(currentId, r.released)) {
        await engine.pause();
        _pausedTargetId = currentId;
      }
    }
  }

  /// Whether the local catalog target [targetId] sits within the membership
  /// match tolerance of any of [rows]' session centres.
  Future<bool> _anyMatches(int targetId, List<CoImagingSessionRow> rows) async {
    if (rows.isEmpty) return false;
    final coords = await _coordsFor(targetId);
    if (coords == null) return false;
    for (final row in rows) {
      final tRa = row.targetRaDeg;
      final tDec = row.targetDecDeg;
      if (tRa == null || tDec == null) continue;
      final sep = CoImagingSessionService.angularSeparationDegrees(
        coords.raDeg,
        coords.decDeg,
        tRa,
        tDec,
      );
      if (sep <= CoImagingSessionService.membershipMatchToleranceDeg) {
        return true;
      }
    }
    return false;
  }

  /// The sky centre (degrees) of the local catalog target [targetId], or null
  /// when it is no longer in the table. RA is stored in hours -> degrees here.
  Future<({double raDeg, double decDeg})?> _coordsFor(int targetId) async {
    final targets = await _ref.read(allDbTargetsProvider.future);
    for (final t in targets) {
      if (t.id == targetId) return (raDeg: t.ra * 15.0, decDeg: t.dec);
    }
    return null;
  }
}

/// Active co-imaging sessions advertised on the configured hub.
final coImagingSessionsProvider = FutureProvider<List<CoImagingSession>>((ref) {
  return ref.watch(coImagingSessionServiceProvider).listSessions();
});

/// The sessions this rig is still an active participant of, rehydrated from the
/// durable membership table (no live hub round-trip).
final coImagingMembershipsProvider = FutureProvider<List<CoImagingSessionRow>>((
  ref,
) {
  return ref.watch(coImagingSessionServiceProvider).activeMemberships();
});

/// The live combined-preview channel for one co-imaging session: yields a
/// snapshot immediately, then one [CoImagingPreview] per contribution / join as
/// subs fuse. Backs the co-imaging card so its COMBINED integration / frames /
/// rig count deepen in real time instead of only on a manual refresh.
///
/// `autoDispose` so the long-lived SSE connection [CoImagingSessionService
/// .watchPreview] opens is released the moment no card is watching it (leaving
/// the Collaborative Sky surface, or the session closing).
final coImagingPreviewProvider = StreamProvider.autoDispose
    .family<CoImagingPreview, String>((ref, sessionId) {
      return ref.watch(coImagingSessionServiceProvider).watchPreview(sessionId);
    });

/// Whether a hub is configured (drives the "sign in" vs "connected" UI).
final constellationConfiguredProvider = FutureProvider<bool>((ref) async {
  final settings = ref.watch(settingsDaoProvider);
  final creds = await resolveConstellationCredentials(settings);
  return creds != null;
});

/// The swarm's shared-target listing on the configured hub.
final sharedTargetsProvider = FutureProvider<List<SharedTarget>>((ref) {
  return ref.watch(constellationServiceProvider).browseSharedTargets();
});

/// The user's local imageable targets, as candidates for "Share one of my
/// targets" (seeding a shared target on the hub). Reuses the remote-aware
/// targets provider and maps RA hours -> degrees at the boundary so the picker
/// and `proposeTarget` agree on units.
final shareableLocalTargetsProvider =
    FutureProvider<List<ShareableLocalTarget>>((ref) async {
      final targets = await ref.watch(allDbTargetsProvider.future);
      return targets
          .map(
            (t) => ShareableLocalTarget(
              targetId: t.id,
              name: t.name,
              raDeg: t.ra * 15.0,
              decDeg: t.dec,
            ),
          )
          .toList(growable: false);
    });

/// The tiles this device has contributed to the configured hub — the
/// retractable units. Empty on a slave (the local receipt table is the host's).
final myContributionsProvider = FutureProvider<List<ContributionRecord>>((ref) {
  return ref.watch(constellationServiceProvider).myContributions();
});

/// Community tiles pulled and blended into "Your Sky" for one target.
///
/// Pulling is a side-effecting fetch (it writes the cached blobs to disk), so
/// this provider performs the pull and returns the resulting [SwarmTile] index.
///
/// Pull with `finalized: false` — the additive `.nst` accumulator — the only
/// form [ConstellationService.pullTarget] folds into the local atlas (via
/// `mergeSwarmDelta`). A `finalized: true` FITS pull is a display-only blob
/// with no consumer, so nothing would reach Your Sky.
final swarmTilesProvider = FutureProvider.family<List<SwarmTile>, int>((
  ref,
  targetId,
) {
  return ref
      .watch(constellationServiceProvider)
      .pullTarget(targetId, finalized: false);
});

/// Follow-the-night suggestions: which shared targets are dark and available for
/// this user right now, ranked deepen-the-thinnest-first. Consumed by the
/// Constellation screen's follow-the-night card (not the planner/scheduler tabs).
/// Keyed by target id so a single-target card can watch just one; pass a
/// negative id (e.g. -1) to request the full sweep.
final followTheNightProvider =
    FutureProvider.family<List<FollowTheNightSuggestion>, int>((
      ref,
      targetId,
    ) async {
      final all = await ref
          .watch(constellationServiceProvider)
          .followTheNight();
      if (targetId < 0) return all;
      return all.where((s) => s.targetId == targetId).toList(growable: false);
    });
