/// Riverpod wiring for the Night Narrator.
///
/// Two read surfaces (DB-watch streams, pinned-first / newest-first) and one
/// keepalive service provider that holds a [NarratorService] alive for the
/// active session — the same lifecycle shape `scienceProcessingServiceProvider`
/// uses, so the Narrator ingests for exactly as long as a session is running.
library;

import '../database/daos/narrator_events_dao.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart' show DbCapturedImage, NarratorEventRow;
import '../services/science/narrator/narrator_context.dart'
    show NarratorFilterIntegration;
import '../services/science/narrator/narrator_event.dart';
import '../services/science/narrator/narrator_service.dart';
import '../backend/remote_host.dart';
import 'backend_provider.dart';
import 'host_role.dart';
import 'database_provider.dart';
import 'remote_snapshot_stream.dart';
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

/// Shortest gap between two fetches of a remote narrator feed. Narrator
/// entries are per-frame or per-event summaries; a companion seeing them a few
/// seconds late costs nothing, while re-fetching on every host event while
/// guiding asked the host for the feed once a second.
const Duration remoteNarratorRefetchMinInterval = Duration(seconds: 10);

/// The night's narrated events of whichever machine is the imaging host.
///
/// The narrator runs on the host and writes its database, which the host
/// watches. A linked client reads the host's feed, again after any host
/// event that is not per-tick telemetry ([remoteSnapshotStream]).
abstract interface class NarratorEventLog {
  /// One session's events, pinned first, then newest first.
  Stream<List<NarratorEvent>> watchSession(int sessionId);

  /// The newest events of any session.
  Stream<List<NarratorEvent>> watchRecent();
}

final narratorEventLogProvider = hostRoleProvider<NarratorEventLog>(
  here: (ref) => _LocalNarratorEventLog(ref.watch(narratorEventsDaoProvider)),
  linked: (ref, host) => _HostNarratorEventLog(ref, host.history),
);

final class _LocalNarratorEventLog implements NarratorEventLog {
  _LocalNarratorEventLog(this._dao);

  final NarratorEventsDao _dao;

  @override
  Stream<List<NarratorEvent>> watchSession(int sessionId) => _dao
      .watchFeedForSession(sessionId)
      .map((rows) => rows.map(narratorEventFromRow).toList(growable: false));

  @override
  Stream<List<NarratorEvent>> watchRecent() => _dao.watchRecentFeed().map(
    (rows) => rows.map(narratorEventFromRow).toList(growable: false),
  );
}

final class _HostNarratorEventLog implements NarratorEventLog {
  _HostNarratorEventLog(this._ref, this._host);

  final Ref _ref;
  final HostHistory _host;

  Stream<List<NarratorEvent>> _watch(
    Future<List<Map<String, dynamic>>> Function() fetch,
  ) => remoteSnapshotStream<NarratorEvent>(
    backend: _ref.read(backendProvider),
    fetch: fetch,
    decode: narratorEventFromWireJson,
    shouldRefetch: (event) =>
        !hostTelemetryEventTypes.contains(event.eventType),
    minInterval: remoteNarratorRefetchMinInterval,
  );

  @override
  Stream<List<NarratorEvent>> watchSession(int sessionId) =>
      _watch(() => _host.getNarratorFeed(sessionId));

  @override
  Stream<List<NarratorEvent>> watchRecent() =>
      _watch(_host.getRecentNarratorFeed);
}

final narratorFeedProvider = StreamProvider.family<List<NarratorEvent>, int>(
  (ref, sessionId) =>
      ref.watch(narratorEventLogProvider).watchSession(sessionId),
);

/// The newest events when no session is selected.
final recentNarratorFeedProvider = StreamProvider<List<NarratorEvent>>(
  (ref) => ref.watch(narratorEventLogProvider).watchRecent(),
);

/// Local captured-image stream for a session, used by the Narrator to derive
/// per-frame stats / grade events / solve history. Read only by the narrator,
/// which runs on the imaging host.
final sessionImagesStreamProvider =
    StreamProvider.family<List<DbCapturedImage>, int>((ref, sessionId) {
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
  List<DbCapturedImage> images,
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
