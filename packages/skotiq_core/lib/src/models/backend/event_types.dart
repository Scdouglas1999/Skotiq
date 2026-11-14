/// Event types for Skotiq backend communication.
///
/// These types are used to communicate events between the Rust backend
/// and Dart frontend, as well as across network boundaries for remote operation.
library;

enum EventSeverity { info, warning, error, critical }

// Canonical event-type string broadcast over the WS
// `/events` channel when a single setting changes on the headless host. The
// payload `data` map carries `{ key, value, changedAt }`. Distinct from the
// coarse `HostStateChanged + entityType: settings` envelope which only tells
// remote clients to refresh — `settings.changed` lets `AppSettingsNotifier`
// apply the delta in-place without a round-trip GET. Originating clients
// filter their own echoes by matching `correlatingCommandId` against the
// `commandId` they received in the POST /api/settings response.
const String settingsChangedEventType = 'settings.changed';

/// The `key` of a `settings.changed` event whose `value` is the whole settings
/// document, sent when the host could not diff against the previous one.
const String settingsSnapshotKey = '__snapshot__';

// Hot-plug discovery event types. The Rust side publishes arrivals/removals
// as the first-class `EquipmentEvent::DeviceDiscovered` /
// `EquipmentEvent::DeviceLost` typed FRB variants (see
// `native/skotiq_native/bridge/src/hotplug.rs`), which the FFI layer maps
// to these event-type strings. The Dart provider `hotplugEventBridgeProvider`
// watches the backend event stream for these types and invalidates the
// equipment discovery providers so the equipment screen refreshes without a
// manual pull-to-refresh. The event `data` map carries
// `{ device_class, driver, id, name, display_name, unique_id? }` for an
// arrival and `{ device_class, driver, id }` for a removal.
const String deviceDiscoveredEventType = 'DeviceDiscovered';
const String deviceLostEventType = 'DeviceLost';

/// Event categories for filtering and routing
enum EventCategory {
  equipment,
  imaging,
  guiding,
  sequencer,
  safety,
  system,
  polarAlignment,

  /// /long-running job lifecycle events (autofocus, plate-solve,
  /// center-on-target, polar alignment, mosaic plan, etc.). Events in this
  /// category carry `data: {jobId, operation, progress?, message?, result?,
  /// error?}` so clients can correlate progress and completion back to the
  /// originating `POST /api/.../start` response.
  job,

  /// Session-ownership lifecycle events. Broadcast when an operator
  /// claims, releases, is taken over, or is auto-released after a heartbeat
  /// timeout. `data: {clientId, clientName, reason?, previousOwner?}` so
  /// the displaced client can show a toast attribution.
  session,

  /// Catalog management lifecycle events. Broadcast for star/DSO/
  /// annotation catalog downloads, hash-verification runs, uninstall, and
  /// reload triggered via `/api/catalog/...`. `data` is event-specific —
  /// see [CatalogHandlers] for the per-event shape. Catalog ops are owned
  /// by the headless server (NOT the connecting client) so a freshly
  /// imaged Pi can be populated remotely without ever touching the host
  /// GUI.
  catalog,
}

/// Skotiq event for backend-to-frontend communication
class SkotiqEvent {
  final int timestamp;
  final EventSeverity severity;
  final EventCategory category;
  final String eventType;
  final Map<String, dynamic> data;

  /// Monotonic server-assigned sequence number, present on events
  /// emitted by the headless API server. Null when the event is constructed
  /// locally (FFI bridge, NetworkBackend synthetic events) or by a server
  /// that pre-dates this field.
  ///
  /// Pair `(serverInstanceId, seq)` uniquely identifies an event across
  /// server restarts so a reconnecting client knows whether to attempt
  /// replay from the ring buffer or call /api/run-watch/snapshot to
  /// rehydrate.
  final int? seq;

  /// Random UUID generated once at server start, mirrored onto every
  /// outbound event. A change in this value between two events tells the
  /// client the server has restarted and the local sequence cursor is
  /// stale.
  final String? serverInstanceId;

  /// Command-id of the originating REST POST that the server
  /// best-effort matched against this event. Null on events that have no
  /// matching command (e.g. background telemetry).
  final String? correlatingCommandId;

  const SkotiqEvent({
    required this.timestamp,
    required this.severity,
    required this.category,
    required this.eventType,
    required this.data,
    this.seq,
    this.serverInstanceId,
    this.correlatingCommandId,
  });

  /// Convert to JSON for wire protocol (WebSocket/HTTP)
  Map<String, dynamic> toJson() => {
    'timestamp': timestamp,
    'severity': severity.name,
    'category': category.name,
    'eventType': eventType,
    'data': data,
    if (seq != null) 'seq': seq,
    if (serverInstanceId != null) 'serverInstanceId': serverInstanceId,
    if (correlatingCommandId != null)
      'correlatingCommandId': correlatingCommandId,
  };

  /// Return a copy of this event with [data], [seq], [serverInstanceId],
  /// and/or [correlatingCommandId] overridden. Used by the headless server to
  /// stamp metadata onto events before broadcasting without mutating the
  /// upstream object the FFI bridge handed us.
  SkotiqEvent copyWith({
    Map<String, dynamic>? data,
    int? seq,
    String? serverInstanceId,
    String? correlatingCommandId,
  }) {
    return SkotiqEvent(
      timestamp: timestamp,
      severity: severity,
      category: category,
      eventType: eventType,
      data: data ?? this.data,
      seq: seq ?? this.seq,
      serverInstanceId: serverInstanceId ?? this.serverInstanceId,
      correlatingCommandId: correlatingCommandId ?? this.correlatingCommandId,
    );
  }

  /// Create from JSON (used by NetworkBackend)
  factory SkotiqEvent.fromJson(Map<String, dynamic> json) {
    return SkotiqEvent.fromWireJson(json);
  }

  /// Parse a host's `/events` frame (the `type: event` wrapper around
  /// [toJson]). Throws [FormatException] for a frame that is not one.
  factory SkotiqEvent.fromWireJson(Map<String, dynamic> json) {
    final timestamp = json['timestamp'];
    final severity = _byName(EventSeverity.values, json['severity']);
    final category = _byName(EventCategory.values, json['category']);
    final eventType = json['eventType'];
    final data = json['data'];
    if (timestamp is! int ||
        severity == null ||
        category == null ||
        eventType is! String ||
        eventType.isEmpty ||
        data is! Map) {
      throw FormatException('Not a SkotiqEvent: $json');
    }
    final seq = json['seq'];
    final serverInstanceId = json['serverInstanceId'];
    final correlatingCommandId = json['correlatingCommandId'];
    return SkotiqEvent(
      timestamp: timestamp,
      severity: severity,
      category: category,
      eventType: eventType,
      data: Map<String, dynamic>.from(data),
      seq: seq is int ? seq : null,
      serverInstanceId: serverInstanceId is String ? serverInstanceId : null,
      correlatingCommandId: correlatingCommandId is String
          ? correlatingCommandId
          : null,
    );
  }

  @override
  String toString() =>
      'SkotiqEvent($eventType, $category, $severity, $data'
      '${seq != null ? ', seq=$seq' : ''}'
      '${correlatingCommandId != null ? ', cmd=$correlatingCommandId' : ''})';
}

T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
