// command/event correlation for the headless API server.
//
// Every action POST (camera/expose, mount/slew, sequencer/start, etc.)
// generates a UUID v4 commandId, registers (operation, deviceId,
// commandId) with the correlator, and includes the id in its response.
// When the backend later emits a SkotiqEvent that "completes" the
// command ([commandCompletionOf]), broadcastEvent calls [stampEvent] which
// best-effort matches the event back to the oldest un-correlated command for
// that (operation, deviceId) pair and copies the commandId onto the event as
// `correlatingCommandId`.
//
// The matching is intentionally best-effort: a multi-client scenario
// where two phones slew the same mount within 100 ms can confuse the
// FIFO pairing. We document that limitation in the class doc rather
// than building a deterministic command-id round-trip through the FFI
// layer (which would require Rust-side support and is out of scope for
// this wave).
//
// TTL eviction (default 30 minutes) protects against unbounded growth
// when a registered command's matching event never arrives (e.g. driver
// hang, sequence cancelled before completion).

import 'dart:math';

import 'package:skotiq_core/backend.dart' show typedEventFromWire;
import 'package:skotiq_core/bridge_events.dart' as sk;
import 'package:skotiq_core/models.dart' show SkotiqEvent;

/// What a completion event finishes: the operations whose commands it can
/// complete, the one tried first first, and the device it names (null when
/// the event names none).
typedef CommandCompletion = ({List<String> operations, String? deviceId});

/// The commands [event] completes, or null when it completes none.
///
/// Read from the typed event the codec decodes, so a renamed event does not
/// compile here instead of quietly never matching, and a guider's `Paused`
/// can never complete a `sequencer.pause`.
CommandCompletion? commandCompletionOf(SkotiqEvent event) {
  CommandCompletion of(List<String> operations, [String? deviceId]) =>
      (operations: operations, deviceId: deviceId);
  return switch (typedEventFromWire(event)?.payload) {
    sk.EventPayload_Imaging(
      field0: sk.ImagingEvent_ExposureCompleted() ||
          sk.ImagingEvent_ExposureCompletedWithFrame() ||
          sk.ImagingEvent_ExposureFailed() ||
          sk.ImagingEvent_ExposureFailedOld(),
    ) =>
      of(const ['camera.expose']),
    sk.EventPayload_Imaging(field0: sk.ImagingEvent_ExposureCancelled()) => of(
      const ['camera.abort', 'camera.expose'],
    ),
    sk.EventPayload_Equipment(:final field0) => switch (field0) {
      sk.EquipmentEvent_MountSlewCompleted(:final deviceId) => of(const [
        'mount.slew',
        'mount.slew-alt-az',
      ], deviceId),
      sk.EquipmentEvent_MountParkCompleted(:final deviceId) => of(const [
        'mount.park',
      ], deviceId),
      sk.EquipmentEvent_MountUnparked(:final deviceId) => of(const [
        'mount.unpark',
      ], deviceId),
      sk.EquipmentEvent_FocuserMoveCompleted(:final deviceId) => of(const [
        'focuser.move-to',
        'focuser.move-relative',
      ], deviceId),
      sk.EquipmentEvent_FilterChanged(:final deviceId) => of(const [
        'filter-wheel.set-position',
      ], deviceId),
      sk.EquipmentEvent_RotatorMoveCompleted(:final deviceId) => of(const [
        'rotator.move-to',
      ], deviceId),
      _ => null,
    },
    sk.EventPayload_Sequencer(:final field0) => switch (field0) {
      sk.SequencerEvent_Started() ||
      sk.SequencerEvent_Completed() ||
      sk.SequencerEvent_Failed() => of(const [
        'sequencer.start',
        'sequencer.load-and-start',
      ]),
      sk.SequencerEvent_Stopped() => of(const ['sequencer.stop']),
      sk.SequencerEvent_Paused() => of(const ['sequencer.pause']),
      sk.SequencerEvent_Resumed() => of(const ['sequencer.resume']),
      _ => null,
    },
    _ => null,
  };
}

class _PendingCommand {
  final String commandId;
  final String operation;
  final String? deviceId;
  final DateTime registeredAt;
  bool stamped = false;

  _PendingCommand({
    required this.commandId,
    required this.operation,
    required this.deviceId,
    required this.registeredAt,
  });
}

/// Tracks in-flight commands so emitted events can be tagged with the
/// originating commandId.
///
/// The matching is **best-effort**, not a guarantee:
///
/// * Multiple clients racing the same operation/device in tight
///   succession will FIFO-pair their events against whichever command
///   the correlator saw first, which is correct for single-client
///   workflows.
/// * Events that arrive after [ttl] elapses are not correlated. The TTL
///   exists to prevent the pending set from growing without bound when
///   a driver hangs or a sequence is aborted before completion.
/// * `stampEvent` is idempotent in the sense that a second event for
///   the same (operation, deviceId) takes the next pending command
///   rather than re-using the already-stamped one.
class CommandCorrelator {
  /// Maximum time a registered command remains eligible for matching
  /// before it is evicted. 30 minutes accommodates plate-solve and
  /// autofocus (the slowest legitimate operations) with headroom.
  final Duration ttl;

  /// Function returning "now" — pluggable for tests.
  final DateTime Function() _now;

  final Random _rng;

  /// Pending commands keyed by `(operation, deviceId)` so a new event
  /// for that pair takes the oldest-registered match.
  final Map<String, List<_PendingCommand>> _pendingByKey = {};

  CommandCorrelator({
    this.ttl = const Duration(minutes: 30),
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _rng = random ?? Random.secure();

  /// Register a new command and return its UUID v4 string. Callers
  /// should embed the returned id in the action POST response body so
  /// the client knows which id to correlate later events with.
  ///
  /// [operation] uses the dotted-path convention (`camera.expose`,
  /// `mount.slew`, etc.) that [commandCompletionOf] names. Unknown
  /// operations are accepted (the id will still be returned to the
  /// caller) but [stampEvent] will never match them.
  String beginCommand({required String operation, String? deviceId}) {
    final commandId = _generateUuidV4();
    final key = _key(operation, deviceId);
    final command = _PendingCommand(
      commandId: commandId,
      operation: operation,
      deviceId: deviceId,
      registeredAt: _now(),
    );
    final list = _pendingByKey.putIfAbsent(key, () => <_PendingCommand>[]);
    list.add(command);
    return commandId;
  }

  /// Return the commandId that should be stamped on an event for
  /// `(operation, deviceId)`, or null if no matching command exists or
  /// the registered commands are all past TTL.
  ///
  /// "Matching" means: the oldest un-stamped pending command for the
  /// key, modulo TTL eviction.
  String? stampEvent({required String operation, String? deviceId}) {
    final now = _now();
    final key = _key(operation, deviceId);
    final list = _pendingByKey[key];
    if (list == null || list.isEmpty) {
      return null;
    }
    // Evict expired entries from the head. The list is ordered by
    // registration time so the first non-expired entry is the oldest
    // eligible match.
    while (list.isNotEmpty && now.difference(list.first.registeredAt) > ttl) {
      list.removeAt(0);
    }
    if (list.isEmpty) {
      _pendingByKey.remove(key);
      return null;
    }
    final match = list.first;
    match.stamped = true;
    // Remove the matched command so a subsequent event takes the next
    // pending one. This is the "FIFO best-effort pairing" semantic.
    list.removeAt(0);
    if (list.isEmpty) {
      _pendingByKey.remove(key);
    }
    return match.commandId;
  }

  /// Walk the entire pending table and drop any entries older than
  /// [ttl]. Called from a periodic sweep so a long-quiet idle does not
  /// retain orphans forever.
  void evictExpired() {
    final now = _now();
    final empty = <String>[];
    _pendingByKey.forEach((key, list) {
      list.removeWhere((cmd) => now.difference(cmd.registeredAt) > ttl);
      if (list.isEmpty) {
        empty.add(key);
      }
    });
    for (final k in empty) {
      _pendingByKey.remove(k);
    }
  }

  int get pendingCount {
    var sum = 0;
    for (final list in _pendingByKey.values) {
      sum += list.length;
    }
    return sum;
  }

  /// Drop every pending entry. Used by tests and by HeadlessApiServer.stop.
  void clear() {
    _pendingByKey.clear();
  }

  String _key(String operation, String? deviceId) {
    return deviceId == null || deviceId.isEmpty
        ? operation
        : '$operation::$deviceId';
  }

  /// Inline UUID v4 generator. We deliberately avoid `package:uuid` so
  /// this module has no extra dependency — the algorithm is documented
  /// in RFC 4122 §4.4.
  String _generateUuidV4() {
    // Fill 16 random bytes, then set the version (0100) and variant
    // (10xx) bits per RFC 4122.
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10xx
    String hex(int n) => n.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-'
        '${h.substring(20)}';
  }
}
