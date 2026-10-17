/// Riverpod wiring for the Night Narrator.
///
/// Two read surfaces (DB-watch streams, pinned-first / newest-first) and one
/// keepalive service provider that holds a [NarratorService] alive for the
/// active session — the same lifecycle shape `scienceProcessingServiceProvider`
/// uses, so the Narrator ingests for exactly as long as a session is running.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../database/database.dart' show CapturedImage, NarratorEventRow;
import '../services/science/narrator/narrator_context.dart'
    show NarratorFilterIntegration;
import '../services/science/narrator/narrator_event.dart';
import '../services/science/narrator/narrator_service.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'session_provider.dart';

/// Map a persisted [NarratorEventRow] to the public [NarratorEvent] value type,
/// decoding (and validating) its evidence payload. A malformed `evidenceJson`
/// decodes to `null` rather than throwing, so one bad row never breaks a feed.
NarratorEvent narratorEventFromRow(NarratorEventRow row) {
  return NarratorEvent(
    id: row.id,
    sessionId: row.sessionId,
    capturedImageId: row.capturedImageId,
    timestamp: row.timestamp,
    eventType: row.eventType,
    category: narratorCategoryFromName(row.category),
    severity: narratorSeverityFromName(row.severity),
    headline: row.headline,
    body: row.body,
    evidence: NarratorEvidence.fromJsonString(row.evidenceJson),
    dedupeKey: row.dedupeKey,
    pinned: row.pinned,
  );
}

/// Reconstruct a [NarratorEvent] from the wire JSON the appliance's
/// `/api/narrator/*` endpoints emit (see `NarratorHandlers._rowToWireJson`).
/// Mirrors [narratorEventFromRow] but reads a decoded map instead of a DB row,
/// so the remote feed renders identically to the local one.
NarratorEvent narratorEventFromWireJson(Map<String, dynamic> json) {
  return NarratorEvent(
    id: (json['id'] as num).toInt(),
    sessionId: (json['sessionId'] as num?)?.toInt(),
    capturedImageId: (json['capturedImageId'] as num?)?.toInt(),
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      (json['timestamp'] as num).toInt(),
    ),
    eventType: json['eventType'] as String,
    category: narratorCategoryFromName(json['category'] as String),
    severity: narratorSeverityFromName(json['severity'] as String),
    headline: json['headline'] as String,
    body: json['body'] as String?,
    evidence: NarratorEvidence.fromJsonString(json['evidenceJson'] as String?),
    dedupeKey: json['dedupeKey'] as String,
    pinned: (json['pinned'] as bool?) ?? false,
  );
}

/// Remote narrator feed stream: the NarratorService runs on the appliance, so a
/// remote client cannot watch the DB. Instead we fetch a REST snapshot and
/// re-fetch (debounced) whenever a backend event arrives — new captures are
/// exactly what produce new narrator events — giving a near-live feed without a
/// dedicated WS event type.
Stream<List<NarratorEvent>> _remoteNarratorStream(
  Ref ref,
  NetworkBackend backend,
  Future<List<Map<String, dynamic>>> Function() fetch,
) {
  final controller = StreamController<List<NarratorEvent>>();
  Timer? debounce;

  Future<void> refetch() async {
    try {
      final raw = await fetch();
      final events = raw.map(narratorEventFromWireJson).toList(growable: false);
      if (!controller.isClosed) controller.add(events);
    } catch (_) {
      // Transient (reconnect / host busy): keep the last good snapshot rather
      // than flashing an empty feed.
    }
  }

  refetch();
  final sub = backend.eventStream.listen((_) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 750), refetch);
  });
  ref.onDispose(() {
    debounce?.cancel();
    unawaited(sub.cancel());
    unawaited(controller.close());
  });
  return controller.stream;
}

/// Session-scoped feed (pinned-first, newest-first). Local: DB-watched, updates
/// the instant the service persists. Remote: REST snapshot + event-driven
/// refresh from the appliance feed.
final narratorFeedProvider = StreamProvider.family<List<NarratorEvent>, int>((
  ref,
  sessionId,
) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _remoteNarratorStream(
      ref,
      backend,
      () => backend.getNarratorFeed(sessionId),
    );
  }
  return ref
      .watch(narratorEventsDaoProvider)
      .watchFeedForSession(sessionId)
      .map((rows) => rows.map(narratorEventFromRow).toList(growable: false));
});

/// Sessionless recent feed (last N across all sessions). For the dashboard
/// tile before a session is selected and standalone surfaces.
final recentNarratorFeedProvider = StreamProvider<List<NarratorEvent>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _remoteNarratorStream(
      ref,
      backend,
      () => backend.getRecentNarratorFeed(),
    );
  }
  return ref
      .watch(narratorEventsDaoProvider)
      .watchRecentFeed()
      .map((rows) => rows.map(narratorEventFromRow).toList(growable: false));
});

/// Local captured-image stream for a session, used by the Narrator to derive
/// per-frame stats / grade events / solve history. Local-DAO only: the Narrator
/// runs where captures land (local / appliance), so remote (companion) mode
/// yields empty and those detectors simply stay quiet there.
final sessionImagesStreamProvider =
    StreamProvider.family<List<CapturedImage>, int>((ref, sessionId) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return Stream.value(const <CapturedImage>[]);
      }
      return ref.watch(imagesDaoProvider).watchImagesForSession(sessionId);
    });

/// Accumulated per-filter integration (accepted light-frame seconds) for a
/// session, derived from the captured-images stream. Mirrors the app-side
/// `runDashboardSessionIntegrationProvider` aggregation but lives in core so the
/// Narrator's [IntegrationMilestoneDetector] can pull it. Remote (companion)
/// mode has no local image stream, so it yields empty and the milestone simply
/// stays quiet there — the appliance/local side is where captures land.
final sessionFilterIntegrationProvider =
    StreamProvider.family<List<NarratorFilterIntegration>, int>((
      ref,
      sessionId,
    ) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return Stream.value(const <NarratorFilterIntegration>[]);
      }
      // The active session's target name (when set) so the integration
      // milestone can read "…on NGC 7000". Cheaply available from the session
      // state — the captured-image rows the aggregation queries only carry a
      // targetId, not a name. A null name simply drops the "on …" clause.
      final targetName = ref.watch(
        sessionStateProvider.select((s) => s.targetName),
      );
      return ref
          .watch(imagesDaoProvider)
          .watchImagesForSession(sessionId)
          .map((images) => _aggregateFilterIntegration(images, targetName));
    });

List<NarratorFilterIntegration> _aggregateFilterIntegration(
  List<CapturedImage> images,
  String? targetName,
) {
  final acceptedSecs = <String, double>{};
  for (final img in images) {
    if (img.frameType != 'light') continue;
    if (!img.isAccepted) continue;
    final filter = (img.filter == null || img.filter!.isEmpty)
        ? 'Unfiltered'
        : img.filter!;
    acceptedSecs[filter] = (acceptedSecs[filter] ?? 0.0) + img.exposureDuration;
  }
  final name = (targetName == null || targetName.isEmpty) ? null : targetName;
  return acceptedSecs.entries
      .map(
        (e) => NarratorFilterIntegration(
          filter: e.key,
          seconds: e.value,
          targetName: name,
        ),
      )
      .toList(growable: false);
}

/// Keeps a [NarratorService] alive while a session is running. Watches the
/// active session id; when it changes, the current service is disposed and a
/// new one is started for the new session. Sessionless captures get a service with
/// a null session id so the per-frame pushed detectors still work.
final narratorServiceProvider = Provider<NarratorService>((ref) {
  final sessionId = ref.watch(
    sessionStateProvider.select((s) => s.dbSessionId),
  );
  final service = NarratorService(ref, sessionId: sessionId);
  // Fire-and-forget start; the service is resilient to being read before
  // start() completes (its hooks just queue inputs).
  // ignore: discarded_futures
  service.start();
  ref.onDispose(service.dispose);
  return service;
});
