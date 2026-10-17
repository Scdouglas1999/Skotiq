import 'dart:convert';

/// Replay Debug — categorical bucket for [ReplayDecision].
///
/// Wire keys are the snake_case identifiers Rust persists into the
/// `sequence_decisions.category` column. Adding variants is safe;
/// renaming is not.
enum DecisionCategory {
  schedulerPick('scheduler_pick'),
  triggerFired('trigger_fired'),
  recoveryEntered('recovery_entered'),
  budgetMet('budget_met'),
  adaptiveSwap('adaptive_swap'),
  frameAccepted('frame_accepted'),
  frameRejected('frame_rejected'),
  pluginNodeInvoked('plugin_node_invoked'),
  manualIntervention('manual_intervention'),
  systemEvent('system_event'),

  /// Unknown wire key — only happens if Rust adds a new variant
  /// before the Dart enum updates. We deliberately surface it as
  /// distinct so the Replay UI can render an "unknown" badge instead
  /// of silently dropping the row.
  unknown('unknown');

  const DecisionCategory(this.wireKey);

  /// Stable snake_case identifier used by the bridge + the
  /// `sequence_decisions.category` column.
  final String wireKey;

  /// Parse a wire key into the enum. Returns [DecisionCategory.unknown]
  /// for unrecognised inputs rather than throwing, so an unknown row renders
  /// with a placeholder instead of crashing the replay feed.
  static DecisionCategory fromWireKey(String s) {
    for (final c in DecisionCategory.values) {
      if (c.wireKey == s) return c;
    }
    return DecisionCategory.unknown;
  }

  /// Human-readable label for the filter chip / row badge.
  String get displayLabel {
    switch (this) {
      case DecisionCategory.schedulerPick:
        return 'Scheduler pick';
      case DecisionCategory.triggerFired:
        return 'Trigger fired';
      case DecisionCategory.recoveryEntered:
        return 'Recovery';
      case DecisionCategory.budgetMet:
        return 'Budget met';
      case DecisionCategory.adaptiveSwap:
        return 'Adaptive swap';
      case DecisionCategory.frameAccepted:
        return 'Frame accepted';
      case DecisionCategory.frameRejected:
        return 'Frame rejected';
      case DecisionCategory.pluginNodeInvoked:
        return 'Plugin node';
      case DecisionCategory.manualIntervention:
        return 'Operator';
      case DecisionCategory.systemEvent:
        return 'System';
      case DecisionCategory.unknown:
        return 'Unknown';
    }
  }
}

/// Replay Debug — one persisted decision row from the
/// `sequence_decisions` table. Immutable; rebuilt from the JSON blob on
/// every read.
class ReplayDecision {
  ReplayDecision({
    required this.id,
    required this.sequenceRunId,
    required this.timestamp,
    required this.category,
    required this.summary,
    required this.details,
    this.nodeId,
  });

  /// Auto-increment row id. `null` for in-flight decisions that
  /// haven't been persisted yet (the live event stream emits these
  /// before the DB write completes).
  final int? id;

  /// FK to `sequence_runs.id`. May be `null` for a decision emitted outside a
  /// tracked run (rare; the executor only emits inside the spawned task
  /// post-start, but the field models the schema honestly).
  final int? sequenceRunId;

  /// UTC timestamp the decision was made.
  final DateTime timestamp;

  /// Category bucket.
  final DecisionCategory category;

  /// One-line human-readable summary.
  final String summary;

  /// Opaque structured details (the JSON-decoded map). Empty map when
  /// the emit site did not attach any extra payload.
  final Map<String, dynamic> details;

  /// Optional node id this decision is associated with (scheduler /
  /// target / exposure).
  final String? nodeId;

  /// Construct from the bridge's [SequencerEvent.DecisionLogged]
  /// payload. `id` is left `null` because the row hasn't been inserted
  /// yet; the service writes it and re-reads to get the assigned id.
  factory ReplayDecision.fromBridgeEvent({
    required String timestampIso,
    required String categoryWireKey,
    required String summary,
    required String detailsJson,
    String? nodeId,
    int? sequenceRunId,
  }) {
    final ts = DateTime.tryParse(timestampIso) ?? DateTime.now().toUtc();
    Map<String, dynamic> parsed;
    if (detailsJson.isEmpty) {
      parsed = const {};
    } else {
      try {
        final decoded = jsonDecode(detailsJson);
        parsed = decoded is Map<String, dynamic>
            ? decoded
            : <String, dynamic>{};
      } on FormatException {
        // Loud-fail policy: we keep the row but mark the
        // payload as malformed so the replay UI can render it instead
        // of silently dropping. Production code never lands here —
        // Rust always emits valid JSON via serde_json::to_string.
        parsed = <String, dynamic>{
          '__parse_error': 'malformed JSON',
          '__raw': detailsJson,
        };
      }
    }
    return ReplayDecision(
      id: null,
      sequenceRunId: sequenceRunId,
      timestamp: ts.toUtc(),
      category: DecisionCategory.fromWireKey(categoryWireKey),
      summary: summary,
      details: parsed,
      nodeId: nodeId,
    );
  }

  /// Construct from a raw DB row map (the keys are the column names).
  factory ReplayDecision.fromDbRow(Map<String, Object?> row) {
    final detailsJson = (row['details_json'] as String?) ?? '{}';
    Map<String, dynamic> parsed;
    try {
      final decoded = jsonDecode(detailsJson);
      parsed = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on FormatException {
      parsed = <String, dynamic>{
        '__parse_error': 'malformed JSON',
        '__raw': detailsJson,
      };
    }
    // Timestamps are stored as INTEGER millis since epoch (UTC) so
    // sorting + range queries hit the index. DateTime.fromMillisecondsSinceEpoch
    // returns a local-time DateTime; we flip to UTC explicitly so the
    // wall-clock comparisons in the replay UI are timezone-correct.
    final tsMillis = (row['timestamp_unix_ms'] as int?) ?? 0;
    return ReplayDecision(
      id: row['id'] as int?,
      sequenceRunId: row['sequence_run_id'] as int?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(tsMillis, isUtc: true),
      category: DecisionCategory.fromWireKey(
        (row['category'] as String?) ?? 'unknown',
      ),
      summary: (row['summary'] as String?) ?? '',
      details: parsed,
      nodeId: row['node_id'] as String?,
    );
  }

  /// Re-encode for storage. Used by the service when persisting a
  /// row received over the bridge.
  Map<String, Object?> toInsertColumns() => {
    'sequence_run_id': sequenceRunId,
    'timestamp_unix_ms': timestamp.toUtc().millisecondsSinceEpoch,
    'category': category.wireKey,
    'summary': summary,
    'details_json': jsonEncode(details),
    'node_id': nodeId,
  };

  /// Replay Debug — canonical wire form for the headless REST
  /// transport (host → remote client). This is the single serializer the
  /// host handler uses so the client's [fromWireJson] parser stays in
  /// lockstep with what the host emits. `details` rides as a nested JSON
  /// object (not a re-encoded string) so the client parses structure, not
  /// a doubly-escaped blob.
  Map<String, Object?> toWireJson() => {
    'id': id,
    'sequence_run_id': sequenceRunId,
    'timestamp_unix_ms': timestamp.toUtc().millisecondsSinceEpoch,
    'category': category.wireKey,
    'summary': summary,
    'details': details,
    'node_id': nodeId,
  };

  /// Replay Debug — strict decoder for the headless wire form
  /// produced by [toWireJson]. This is the centralized parser for
  /// remote-client reads; it deliberately does NOT zero-fill malformed
  /// required structure. An unknown `category` is preserved as
  /// [DecisionCategory.unknown] (forward-compat with a newer host), but a
  /// missing/wrong-typed `id`, `timestamp_unix_ms`, `summary`, or a
  /// non-object `details` throws [FormatException] so the caller surfaces
  /// a real parse failure instead of a plausible-but-fabricated row.
  factory ReplayDecision.fromWireJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! int || id <= 0) {
      throw FormatException(
        'ReplayDecision wire row: `id` missing or not an integer '
        '(${id.runtimeType})',
      );
    }
    final runIdRaw = json['sequence_run_id'];
    if (runIdRaw != null && runIdRaw is! int) {
      throw FormatException(
        'ReplayDecision wire row $id: `sequence_run_id` is not an integer '
        'or null (${runIdRaw.runtimeType})',
      );
    }
    if (runIdRaw is int && runIdRaw <= 0) {
      throw FormatException(
        'ReplayDecision wire row $id: `sequence_run_id` must be positive',
      );
    }
    final tsMillis = json['timestamp_unix_ms'];
    if (tsMillis is! int || tsMillis < 0) {
      throw FormatException(
        'ReplayDecision wire row $id: `timestamp_unix_ms` missing or not an '
        'integer (${tsMillis.runtimeType})',
      );
    }
    final category = json['category'];
    if (category is! String || category.trim().isEmpty) {
      throw FormatException(
        'ReplayDecision wire row $id: `category` missing or not a string '
        '(${category.runtimeType})',
      );
    }
    final summary = json['summary'];
    if (summary is! String || summary.trim().isEmpty) {
      throw FormatException(
        'ReplayDecision wire row $id: `summary` missing or not a string '
        '(${summary.runtimeType})',
      );
    }
    final detailsRaw = json['details'];
    if (detailsRaw is! Map) {
      throw FormatException(
        'ReplayDecision wire row $id: `details` missing or not a JSON object '
        '(${detailsRaw.runtimeType})',
      );
    }
    final nodeIdRaw = json['node_id'];
    if (nodeIdRaw != null && nodeIdRaw is! String) {
      throw FormatException(
        'ReplayDecision wire row $id: `node_id` is not a string or null '
        '(${nodeIdRaw.runtimeType})',
      );
    }
    if (nodeIdRaw is String && nodeIdRaw.trim().isEmpty) {
      throw FormatException(
        'ReplayDecision wire row $id: `node_id` must be non-empty or null',
      );
    }
    return ReplayDecision(
      id: id,
      sequenceRunId: runIdRaw as int?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(tsMillis, isUtc: true),
      category: DecisionCategory.fromWireKey(category),
      summary: summary,
      details: Map<String, dynamic>.from(detailsRaw),
      nodeId: nodeIdRaw as String?,
    );
  }

  ReplayDecision copyWith({int? id}) => ReplayDecision(
    id: id ?? this.id,
    sequenceRunId: sequenceRunId,
    timestamp: timestamp,
    category: category,
    summary: summary,
    details: details,
    nodeId: nodeId,
  );

  @override
  String toString() =>
      'ReplayDecision(id=$id, run=$sequenceRunId, ${category.wireKey}: $summary)';
}

/// Replay Debug — the two persisted replay settings, as a single
/// immutable value. Carried over the headless wire (host → remote client)
/// so a remote client reads the host's authoritative policy instead of
/// its own empty local database.
class ReplayDebugSettings {
  const ReplayDebugSettings({
    required this.enabled,
    required this.retentionDays,
  });

  /// Whether the Rust executor should emit DecisionLogged events.
  final bool enabled;

  /// Prune window in days. Always in the valid band `1..3650`.
  final int retentionDays;

  Map<String, Object?> toWireJson() => {
    'enabled': enabled,
    'retentionDays': retentionDays,
  };

  /// Strict decoder for the host's `/api/replay/settings` payload. Throws
  /// [FormatException] on a missing/wrong-typed field or an out-of-band
  /// retention value rather than fabricating a default — a remote client
  /// must see a real error, never a false "everything's fine" reading.
  factory ReplayDebugSettings.fromWireJson(Map<String, dynamic> json) {
    final enabled = json['enabled'];
    if (enabled is! bool) {
      throw FormatException(
        'ReplayDebugSettings wire: `enabled` missing or not a bool '
        '(${enabled.runtimeType})',
      );
    }
    final retention = json['retentionDays'];
    if (retention is! int) {
      throw FormatException(
        'ReplayDebugSettings wire: `retentionDays` missing or not an integer '
        '(${retention.runtimeType})',
      );
    }
    if (retention < 1 || retention > 3650) {
      throw FormatException(
        'ReplayDebugSettings wire: `retentionDays` out of range 1..3650 '
        '($retention)',
      );
    }
    return ReplayDebugSettings(enabled: enabled, retentionDays: retention);
  }

  @override
  bool operator ==(Object other) =>
      other is ReplayDebugSettings &&
      other.enabled == enabled &&
      other.retentionDays == retentionDays;

  @override
  int get hashCode => Object.hash(enabled, retentionDays);

  @override
  String toString() =>
      'ReplayDebugSettings(enabled=$enabled, retentionDays=$retentionDays)';
}
