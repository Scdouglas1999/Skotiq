import 'linked_host.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'database_provider.dart';
import '../database/daos/transient_detections_dao.dart';
import '../database/database.dart';
import '../services/sky_atlas/sky_atlas_service.dart' show defaultAtlasRoot;
import '../services/transients/first_light_service.dart';
import '../services/transients/transient_submission_service.dart';
import '../backend/skotiq_backend.dart';
import 'backend_provider.dart';
import 'remote_snapshot_stream.dart';
import 'sky_atlas_provider.dart'
    show isAtlasChangingEvent, remoteAtlasRefetchMinInterval;
import 'package:skotiq_astro/skotiq_astro.dart';
import 'logging_service_provider.dart';
import 'science/photometric_catalog_service_provider.dart';
import 'transients/difference_image_seam_provider.dart';

/// Riverpod surface for Pillar B ("First Light") — difference-imaging transients.
///
/// [firstLightServiceProvider] builds the scan orchestrator from the transient
/// DAO + FFI seam + photometric catalog; [transientDetectionsProvider] is the
/// reactive newest-first feed the transient gallery and the Narrator's transient
/// surface render, scoped to a session.

/// Bound on the reactive First Light feeds: the most-recent N detections,
/// newest-first. Large enough that the visible recent set is unchanged across a
/// normal session, small enough that a multi-season log never has to be fully
/// sorted on every DB tick. Deeper history pages via the REST `offset`.
const int kFirstLightFeedLimit = 200;

/// The most-recent First Light scan coverage envelope (deep / thin / empty tile
/// counts for the last frame differenced), or null before any scan has run.
/// Surfaces "atlas not deep enough here yet" on the discovery view so a
/// thin-atlas no-op is distinguishable from a genuinely clean-sky night. Host
/// only — the scan runs where solved frames land; a slave reads detections, not
/// this local-scan signal.
final firstLightCoverageProvider = StateProvider<FirstLightCoverage?>(
  (ref) => null,
);

/// The First Light scan service.
final firstLightServiceProvider = Provider<FirstLightService>((ref) {
  return FirstLightService(
    dao: ref.watch(transientDetectionsDaoProvider),
    seam: ref.watch(differenceImageSeamProvider),
    catalog: PhotometricCatalogMatcher(
      ref.watch(photometricCatalogServiceProvider),
    ),
    logger: ref.watch(loggingServiceProvider),
    atlasRootResolver: defaultAtlasRoot,
    retention: ref.watch(livingSkyRetentionDaoProvider),
    // The scan compares a frame only against its own filter's template.
    filterResolver: (capturedImageId) async =>
        (await ref.read(imagesDaoProvider).getImageById(capturedImageId))
            ?.filter,
    // Publish each scan's coverage so the discovery surface can explain a
    // thin-atlas quiet night. Guard the read: the container may be mid-dispose
    // when a late scan completes.
    onCoverage: (coverage) {
      try {
        ref.read(firstLightCoverageProvider.notifier).state = coverage;
      } catch (_) {
        // Container disposed between scan kickoff and completion — drop it.
      }
    },
  );
});

/// Host-only submission seam for First Light discovery reports (real TNS
/// bot-API upload + AAVSO/MPC export). Wired with an http.Client + logger; the
/// TNS api key is read from the keyring by the caller, not injected here.
final transientSubmissionServiceProvider = Provider<TransientSubmissionService>(
  (ref) {
    final client = http.Client();
    ref.onDispose(client.close);
    return TransientSubmissionService(
      httpClient: client,
      logger: ref.watch(loggingServiceProvider),
    );
  },
);

/// Reactive newest-first transient detections across all sessions — backs the
/// standalone gallery, the export hub's candidate snapshot and the alert bell.
/// Bounded to the most-recent [kFirstLightFeedLimit] so the feed is an index
/// range over `idx_transient_detections_detected`, not a full sort of a
/// multi-season log; the visible recent set is unchanged.
///
/// Shares [_liveDetectionsFeed] with the First Light candidate feed rather than
/// subscribing to the DAO watch directly. The export hub renders its own Retry
/// on this provider (`science_export_hub.dart`, `ref.invalidate`), and that
/// button is only honest if invalidating re-runs the query — which, on a bare
/// drift stream, it does not.
final allTransientDetectionsProvider =
    StreamProvider<List<TransientDetectionRow>>((ref) {
      return _liveDetectionsFeed(ref.watch(transientDetectionsDaoProvider));
    });

/// Reconstruct a [TransientDetectionRow] from the wire JSON the appliance's
/// `/api/firstlight/candidates` endpoint emits (see
/// `FirstLightHandlers._rowToWireJson`). Mirrors the DB row exactly so the
/// remote First Light surface renders identically to the local one.
TransientDetectionRow transientDetectionFromWireJson(
  Map<String, dynamic> json,
) {
  return TransientDetectionRow(
    id: (json['id'] as num).toInt(),
    sessionId: (json['sessionId'] as num?)?.toInt(),
    capturedImageId: (json['capturedImageId'] as num?)?.toInt(),
    tileId: (json['tileId'] as num).toInt(),
    detectedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['detectedAt'] as num).toInt(),
    ),
    raDeg: (json['raDeg'] as num).toDouble(),
    decDeg: (json['decDeg'] as num).toDouble(),
    residualFlux: (json['residualFlux'] as num).toDouble(),
    deltaMag: (json['deltaMag'] as num?)?.toDouble(),
    snr: (json['snr'] as num).toDouble(),
    fwhm: (json['fwhm'] as num).toDouble(),
    eccentricity: (json['eccentricity'] as num).toDouble(),
    positionAngleDeg: (json['positionAngleDeg'] as num?)?.toDouble() ?? 0.0,
    kind: json['kind'] as String,
    catalogMatch: json['catalogMatch'] as String?,
    confidence: (json['confidence'] as num).toDouble(),
    reviewed: (json['reviewed'] as bool?) ?? false,
    dismissed: (json['dismissed'] as bool?) ?? false,
  );
}

/// Backend-aware First Light candidate feed. Local: the DB-watched
/// across-sessions stream, updating the instant the difference pipeline
/// persists. Remote (companion) mode: a REST snapshot from the appliance,
/// refreshed when backend events arrive (a new capture is exactly what produces
/// a new scan), so the discovery surface works on desktop and mobile alike.
final firstLightCandidatesProvider =
    StreamProvider<List<TransientDetectionRow>>((ref) {
      final backend = ref.watch(backendProvider);
      final remote = ref.watch(linkedHostTransientsProvider);
      if (remote != null) {
        return _remoteFirstLightStream(
          ref,
          backend,
          () => remote.getFirstLightCandidates(),
        );
      }
      return _liveDetectionsFeed(ref.watch(transientDetectionsDaoProvider));
    });

/// Uses Drift's watch stream as an invalidation signal and publishes a fresh
/// one-shot read for every signal. Subscribing before the initial read avoids a
/// lost-update window, while fresh reads let Retry recover from cached stream
/// errors. Generation checks prevent older reads from overwriting newer ones.
Stream<List<TransientDetectionRow>> _liveDetectionsFeed(
  TransientDetectionsDao dao,
) {
  final controller = StreamController<List<TransientDetectionRow>>();
  StreamSubscription<List<TransientDetectionRow>>? changes;
  var started = 0;
  var published = 0;

  Future<void> publishFreshRead() async {
    final generation = ++started;
    try {
      final rows = await dao.recentDetections(limit: kFirstLightFeedLimit);
      // Reads are not guaranteed to complete in the order they began; a slower
      // older one must never overwrite a newer result.
      if (controller.isClosed || generation <= published) return;
      published = generation;
      controller.add(rows);
    } catch (error, stack) {
      if (controller.isClosed || generation <= published) return;
      published = generation;
      // A read that genuinely fails is still reported — only the watch
      // stream's own replayed error is absorbed (below).
      controller.addError(error, stack);
    }
  }

  controller.onListen = () {
    changes = dao
        .watchRecentDetections(limit: kFirstLightFeedLimit)
        .listen(
          (_) => publishFreshRead(),
          onError: (Object _, StackTrace __) => publishFreshRead(),
        );
    // Do not depend on drift replaying to a new subscriber for the first value.
    publishFreshRead();
  };

  controller.onCancel = () async {
    await changes?.cancel();
    changes = null;
    await controller.close();
  };

  return controller.stream;
}

/// REST snapshot stream for the remote First Light feed. Detections come from
/// the host's difference scan of a newly solved frame, so the feed is
/// re-fetched only on the events that follow one ([isAtlasChangingEvent]), at
/// most once every [remoteAtlasRefetchMinInterval].
Stream<List<TransientDetectionRow>> _remoteFirstLightStream(
  Ref ref,
  SkotiqBackend backend,
  Future<List<Map<String, dynamic>>> Function() fetch,
) {
  return remoteSnapshotStream<TransientDetectionRow>(
    backend: backend,
    fetch: fetch,
    decode: transientDetectionFromWireJson,
    shouldRefetch: isAtlasChangingEvent,
    minInterval: remoteAtlasRefetchMinInterval,
  );
}

/// Key for a real-pixel per-detection crop request: the detection id (for the
/// remote endpoint) plus the deterministic name inputs (tile id + sky position,
/// for the local file) and the [stage]. A value-record so two reads of the same
/// stamp share one fetch.
typedef FirstLightCropQuery = ({
  int detectionId,
  int tileId,
  double raDeg,
  double decDeg,
  String stage,
});

/// Backend-aware REAL per-detection pixel crop (PNG bytes) for one stage
/// (`template` | `science` | `residual`). Local: read the stamp the difference
/// pass wrote into [firstLightCropDir] by its deterministic name. Remote
/// (companion): fetch `/api/firstlight/<id>/crops/<stage>` from the host. Returns
/// null when the stamp is absent (an older detection from before crops were
/// captured, or a scan that produced none) so the UI falls back to the schematic.
final firstLightCropProvider = FutureProvider.autoDispose
    .family<Uint8List?, FirstLightCropQuery>((ref, query) async {
      final remote = ref.watch(linkedHostTransientsProvider);
      if (remote != null) {
        try {
          final bytes = await remote.getFirstLightCrop(
            query.detectionId,
            query.stage,
          );
          return bytes.isEmpty ? null : bytes;
        } catch (_) {
          // 404 (no crop captured) or a transient reach failure → schematic.
          return null;
        }
      }
      final atlasRoot = await defaultAtlasRoot();
      final name = firstLightCropName(
        tileId: query.tileId,
        raDeg: query.raDeg,
        decDeg: query.decDeg,
        stage: query.stage,
      );
      final file = File('${firstLightCropDir(atlasRoot)}/$name');
      if (!await file.exists()) return null;
      return file.readAsBytes();
    });

/// A sky position to group a transient's cross-night history around. Carries
/// the match radius so the provider key is value-equal (a record) and two
/// lookups of the same source share one fetch.
typedef FirstLightHistoryQuery = ({
  double raDeg,
  double decDeg,
  double radiusDeg,
});

/// Backend-aware cross-night history for one transient: every persisted
/// detection within [FirstLightHistoryQuery.radiusDeg] of the position,
/// oldest-first. Local: a DB query refined to true angular separation. Remote
/// (companion): the host's `/api/firstlight/near` snapshot. Backs the
/// multi-night light-curve detail view so the same source seen over several
/// nights reads as one Δmag-vs-time history on desktop and mobile alike.
final firstLightHistoryProvider = FutureProvider.autoDispose
    .family<List<TransientDetectionRow>, FirstLightHistoryQuery>((
      ref,
      query,
    ) async {
      final remote = ref.watch(linkedHostTransientsProvider);
      final List<TransientDetectionRow> rows;
      if (remote != null) {
        final raw = await remote.getFirstLightHistory(
          raDeg: query.raDeg,
          decDeg: query.decDeg,
          radiusDeg: query.radiusDeg,
        );
        rows = raw.map(transientDetectionFromWireJson).toList(growable: false);
      } else {
        rows = await ref
            .watch(transientDetectionsDaoProvider)
            .detectionsNear(
              query.raDeg,
              query.decDeg,
              radiusDeg: query.radiusDeg,
            );
      }
      // Refine the coarse bounding box to a true angular separation so a
      // detection in the box corner but outside the cone does not group in.
      final kept = rows
          .where(
            (r) =>
                AstronomyCalculations.angularSeparation(
                  ra1Deg: query.raDeg,
                  dec1Deg: query.decDeg,
                  ra2Deg: r.raDeg,
                  dec2Deg: r.decDeg,
                ) <=
                query.radiusDeg,
          )
          .toList(growable: false);
      kept.sort((a, b) => a.detectedAt.compareTo(b.detectedAt));
      return kept;
    });

/// Triage a First Light candidate (mark reviewed/confirmed, or dismiss as an
/// artefact). Routes to the host over REST in companion mode, else writes the
/// local DB directly. Exposed as a callback the discovery surface invokes from
/// a card action so both desktop and mobile share one triage path.
final firstLightTriageProvider = Provider<FirstLightTriage>((ref) {
  final remote = ref.watch(linkedHostTransientsProvider);
  if (remote != null) {
    // Remote (slave) triage: the host applies the reviewed/dismissed flag, but
    // the remote feed is a debounced REST snapshot that otherwise only re-fetches
    // on an unrelated backend event — so the card's badge would stay stale until
    // a capture tick arrived. Await the host POST THEN invalidate the feed to
    // force an immediate re-fetch of /api/firstlight/candidates reflecting the
    // host's just-applied flags (badge updates within one round-trip). Await
    // before invalidating so a FAILED triage doesn't wipe the current state.
    return FirstLightTriage(
      review: (id) async {
        await remote.reviewFirstLightCandidate(id);
        ref.invalidate(firstLightCandidatesProvider);
      },
      dismiss: (id) async {
        await remote.dismissFirstLightCandidate(id);
        ref.invalidate(firstLightCandidatesProvider);
      },
    );
  }
  final service = ref.watch(firstLightServiceProvider);
  return FirstLightTriage(
    review: (id) => service.markReviewed(id, dismissed: false),
    dismiss: (id) => service.markReviewed(id, dismissed: true),
  );
});

/// Backend-agnostic triage callbacks for a First Light candidate.
class FirstLightTriage {
  const FirstLightTriage({required this.review, required this.dismiss});

  /// Mark the candidate reviewed (confirmed).
  final Future<void> Function(int id) review;

  /// Dismiss the candidate as a triaged artefact.
  final Future<void> Function(int id) dismiss;
}
