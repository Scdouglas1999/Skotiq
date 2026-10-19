// session ownership for the headless API server.
//
// Without ownership, two phones can race on `POST /api/sequencer/start` or
// `POST /api/mount/slew` and conflicts resolve at the driver level with
// opaque "device busy" errors. This module adds a single operator slot
// owned by one bearer token at a time. Other clients with `control` scope
// remain "viewers" until they explicitly take over.
//
// Destructive (mutating, non-status) endpoints require the caller to be
// the current operator or they 409 with a hint to use take-over. Status
// and read-only endpoints stay open to any control/view scope client.
//
// Ownership is held in-memory only. A server restart clears the slot,
// matching the existing per-restart contract for jobs and events.

import 'dart:async';

import 'package:skotiq_core/skotiq_core.dart';

/// Snapshot of the current operator. Immutable; manager rebuilds a new
/// snapshot on every claim/release/heartbeat.
class SessionOwner {
  /// SHA-256 hex of the owning bearer token. We store the digest rather
  /// than the raw token so a memory dump (or accidental log line) does
  /// not expose admin credentials. The manager compares against the same
  /// digest of the request's bearer token on every isOwner() check.
  final String tokenDigest;

  /// Client-provided device id (UUID, MAC, hostname...). Optional —
  /// presented to the displaced client so it can show "Pixel 7" instead
  /// of an opaque token. Caller-supplied: do not trust for any auth gate.
  final String? clientId;

  /// Human-readable name. Used in the take-over event and the status
  /// endpoint's response so the UI can render "Tablet took over".
  final String? clientName;

  final DateTime claimedAt;

  /// Heartbeat marker updated on every WS frame from the owner. The auto-
  /// release sweep evicts owners whose last activity is older than the
  /// configured timeout.
  final DateTime lastSeenAt;

  const SessionOwner({
    required this.tokenDigest,
    required this.clientId,
    required this.clientName,
    required this.claimedAt,
    required this.lastSeenAt,
  });

  SessionOwner _copyWith({DateTime? lastSeenAt}) {
    return SessionOwner(
      tokenDigest: tokenDigest,
      clientId: clientId,
      clientName: clientName,
      claimedAt: claimedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  /// Wire-format JSON used by REST responses + WS events. The token
  /// digest is NOT serialised — clients only need name/id/timestamps.
  Map<String, Object?> toJson() => {
    if (clientId != null) 'clientId': clientId,
    if (clientName != null) 'clientName': clientName,
    'claimedAt': claimedAt.toUtc().toIso8601String(),
    'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
  };
}

/// Reasons a take-over / release happened, used in the broadcast event
/// so a UI can render context-aware toasts.
const String ownerEventClaimed = 'OwnershipClaimed';
const String ownerEventTakenOver = 'OwnershipTakenOver';
const String ownerEventReleased = 'OwnershipReleased';
const String ownerEventAutoReleased = 'OwnershipAutoReleased';

/// Owner state machine.
///
/// Thread safety: single-threaded Dart event loop. The manager mutates
/// `_current` synchronously between event-loop turns; there is no
/// observable interleaving.
class SessionOwnershipManager {
  /// Time without a heartbeat before the slot is auto-released. Default
  /// 5 minutes — long enough for a phone to background briefly without
  /// losing control, short enough that a forgotten tablet doesn't lock
  /// out the rig for the night.
  final Duration heartbeatTimeout;

  /// Pluggable clock for tests.
  final DateTime Function() _now;

  /// Token-digest function. Tests inject a deterministic stub; production
  /// uses SHA-256 from the existing pairing helpers. Kept as a callable
  /// so this module has no crypto dependency of its own.
  final String Function(String token) _digestToken;

  /// Sink the manager calls on every ownership transition. Wired by
  /// [HeadlessApiServer] to broadcastEvent so OwnershipClaimed /
  /// TakenOver / Released / AutoReleased frames fan out to every
  /// connected client.
  final void Function(SkotiqEvent event) _emitEvent;

  SessionOwner? _current;
  Timer? _sweepTimer;

  /// How often we sweep for an idle owner. Faster than the timeout to
  /// keep the auto-release latency bounded.
  Duration get sweepInterval => Duration(
    milliseconds: (heartbeatTimeout.inMilliseconds ~/ 5).clamp(1000, 60000),
  );

  final StreamController<SessionOwner?> _changes =
      StreamController<SessionOwner?>.broadcast(sync: true);

  SessionOwnershipManager({
    required void Function(SkotiqEvent event) emitEvent,
    required String Function(String token) digestToken,
    this.heartbeatTimeout = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _emitEvent = emitEvent,
       _digestToken = digestToken,
       _now = now ?? DateTime.now;

  /// Current operator snapshot, or null when the slot is open.
  SessionOwner? get current => _current;

  /// Stream of snapshots emitted on every claim/release/take-over.
  Stream<SessionOwner?> get changes => _changes.stream;

  /// True when [token] hashes to the current owner's digest. Used by
  /// the destructive-endpoint guard to gate sequencer/mount/dome writes.
  bool isOwner(String token) {
    final owner = _current;
    if (owner == null) return false;
    return owner.tokenDigest == _digestToken(token);
  }

  /// Refresh the owner's heartbeat. Called whenever we observe activity
  /// from the operator — currently on every authenticated WS frame and
  /// every destructive REST POST. Idempotent and silent on non-owner
  /// tokens (so any auth'd client touching the API does not crash the
  /// heartbeat path).
  void touchHeartbeat(String token) {
    final owner = _current;
    if (owner == null) return;
    if (owner.tokenDigest != _digestToken(token)) return;
    _current = owner._copyWith(lastSeenAt: _now());
    // Heartbeat does not emit an event — the broadcast traffic would
    // dominate the event log and add no caller value. Status endpoints
    // read `lastSeenAt` directly off the snapshot.
  }

  /// Attempt to claim the operator slot. Returns the resulting owner if
  /// the slot was free (or if [token] already owns the slot — idempotent
  /// re-claim is a no-op). Returns null when another client holds the
  /// slot; the caller turns that into a 409 response.
  SessionOwner? claim({
    required String token,
    String? clientId,
    String? clientName,
  }) {
    final existing = _current;
    final digest = _digestToken(token);
    if (existing != null) {
      if (existing.tokenDigest == digest) {
        // Same token re-claiming — refresh heartbeat and identity so the
        // owner can update its display name without forcing a release.
        final refreshed = SessionOwner(
          tokenDigest: digest,
          clientId: clientId ?? existing.clientId,
          clientName: clientName ?? existing.clientName,
          claimedAt: existing.claimedAt,
          lastSeenAt: _now(),
        );
        _current = refreshed;
        return refreshed;
      }
      return null; // Slot taken by a different client.
    }
    final owner = SessionOwner(
      tokenDigest: digest,
      clientId: clientId,
      clientName: clientName,
      claimedAt: _now(),
      lastSeenAt: _now(),
    );
    _current = owner;
    _emit(ownerEventClaimed, owner, severity: EventSeverity.info);
    _changes.add(owner);
    _ensureSweepTimer();
    return owner;
  }

  /// Forcefully replace the current owner. Always succeeds — any
  /// control-scope client can preempt. Broadcasts an `OwnershipTakenOver`
  /// event so the previous owner's UI can show a displacement toast.
  ///
  /// [reason] is required (caller must explain) and stamped onto the
  /// event payload.
  SessionOwner takeOver({
    required String token,
    required String reason,
    String? clientId,
    String? clientName,
  }) {
    final previous = _current;
    final owner = SessionOwner(
      tokenDigest: _digestToken(token),
      clientId: clientId,
      clientName: clientName,
      claimedAt: _now(),
      lastSeenAt: _now(),
    );
    _current = owner;
    _emit(
      ownerEventTakenOver,
      owner,
      severity: EventSeverity.warning,
      extraData: {
        'reason': reason,
        if (previous != null)
          'previousOwner': {
            if (previous.clientId != null) 'clientId': previous.clientId,
            if (previous.clientName != null) 'clientName': previous.clientName,
            'claimedAt': previous.claimedAt.toUtc().toIso8601String(),
          },
      },
    );
    _changes.add(owner);
    _ensureSweepTimer();
    return owner;
  }

  /// Voluntary release by the owner. Returns true on success, false if
  /// [token] is not the current owner (the handler maps that to 403).
  /// Idempotent: releasing an empty slot is a no-op that returns true so
  /// a client retrying after a disconnect does not 403.
  bool release(String token) {
    final owner = _current;
    if (owner == null) return true;
    if (owner.tokenDigest != _digestToken(token)) {
      return false;
    }
    _current = null;
    _emit(ownerEventReleased, owner, severity: EventSeverity.info);
    _changes.add(null);
    return true;
  }

  /// Run the auto-release sweep once. Exposed for tests and called from
  /// the periodic [Timer] started by [_ensureSweepTimer].
  void sweepIdle() {
    final owner = _current;
    if (owner == null) return;
    if (_now().difference(owner.lastSeenAt) > heartbeatTimeout) {
      _current = null;
      _emit(
        ownerEventAutoReleased,
        owner,
        severity: EventSeverity.warning,
        extraData: {
          'reason': 'heartbeat_timeout',
          'timeoutSeconds': heartbeatTimeout.inSeconds,
        },
      );
      _changes.add(null);
    }
  }

  void _ensureSweepTimer() {
    if (_sweepTimer != null) return;
    _sweepTimer = Timer.periodic(sweepInterval, (_) => sweepIdle());
  }

  /// Drop the current owner without emitting an event. Used by tests
  /// and by [HeadlessApiServer.stop].
  void clear() {
    _current = null;
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  /// Tear down the broadcast controller. Manager is unusable afterwards.
  Future<void> dispose() async {
    clear();
    await _changes.close();
  }

  void _emit(
    String eventType,
    SessionOwner owner, {
    required EventSeverity severity,
    Map<String, Object?>? extraData,
  }) {
    final data = <String, Object?>{
      if (owner.clientId != null) 'clientId': owner.clientId,
      if (owner.clientName != null) 'clientName': owner.clientName,
      'claimedAt': owner.claimedAt.toUtc().toIso8601String(),
      'lastSeenAt': owner.lastSeenAt.toUtc().toIso8601String(),
      if (extraData != null) ...extraData,
    };
    final event = SkotiqEvent(
      timestamp: _now().toUtc().millisecondsSinceEpoch,
      severity: severity,
      category: EventCategory.session,
      eventType: eventType,
      data: data,
    );
    _emitEvent(event);
  }
}

/// Resolve whether [path] (without query string) is a destructive endpoint
/// that requires session ownership.
///
/// The rule: a POST that commands hardware or run state requires ownership;
/// status, equipment-detail, profile, history and analytics endpoints stay
/// open to viewers because they touch nothing. The enrolled paths are
/// [_ownershipRequiredPaths].
bool isOwnershipRequired({required String method, required String path}) {
  if (method.toUpperCase() != 'POST') return false;
  return _ownershipRequiredPaths.contains(path);
}

const Set<String> _ownershipRequiredPaths = {
  // Sequencer execution control
  '/api/sequencer/start',
  '/api/sequencer/stop',
  '/api/sequencer/pause',
  '/api/sequencer/resume',
  '/api/sequencer/request-meridian-flip',
  '/api/sequencer/skip',
  '/api/sequencer/skip-to-node',
  '/api/sequencer/reset',
  // Mount
  '/api/mount/slew',
  '/api/mount/slew-alt-az',
  '/api/mount/sync',
  '/api/mount/park',
  '/api/mount/unpark',
  '/api/mount/abort',
  '/api/mount/home',
  '/api/mount/find-home',
  '/api/mount/set-park',
  '/api/mount/move-axis',
  '/api/mount/pulse-guide',
  '/api/mount/set-tracking-rate',
  '/api/mount/tracking',
  // Dome
  '/api/dome/open',
  '/api/dome/close',
  '/api/dome/slew',
  '/api/dome/sync',
  '/api/dome/park',
  '/api/dome/home',
  '/api/dome/halt',
  // Camera
  '/api/camera/expose',
  '/api/camera/abort',
  '/api/camera/cooling',
  '/api/camera/readoutMode',
  '/api/camera/gain',
  '/api/camera/offset',
  // Focuser
  '/api/focuser/move-to',
  '/api/focuser/move-relative',
  '/api/focuser/halt',
  '/api/focuser/autofocus/start',
  '/api/focuser/autofocus/cancel',
  // Filter wheel
  '/api/filter-wheel/position',
  '/api/filter-wheel/names',
  '/api/filter-wheel/set-by-name',
  // Rotator
  '/api/rotator/move-to',
  '/api/rotator/move-relative',
  '/api/rotator/halt',
  '/api/rotator/sync',
  // Plate solve + framing
  '/api/plate-solve',
  '/api/framing/slew-to-target',
  '/api/framing/center-on-target',
  '/api/framing/sync',
  '/api/framing/rotate-to',
  '/api/framing/abort-slew',
  '/api/framing/park',
  '/api/framing/unpark',
  // Planetarium mount control (real hardware motion, same as the mount /
  // framing slew endpoints)
  '/api/planetarium/slew-to',
  '/api/planetarium/sync-to',
  '/api/planetarium/center-on',
  // Polar alignment
  '/api/polar-alignment/start',
  '/api/polar-alignment/all-sky/start',
  '/api/polar-alignment/stop',
  // Cover / calibrator / switch
  '/api/cover/open',
  '/api/cover/close',
  '/api/cover/brightness',
  '/api/cover/calibrator-on',
  '/api/cover/calibrator-off',
  '/api/switch/set',
};
