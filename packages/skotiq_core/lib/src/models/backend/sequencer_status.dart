/// Sequencer status and checkpoint types.
library;

/// Current status of the sequence executor
class SequencerStatus {
  /// Current state (idle, running, paused, stopped, error)
  final String state;

  /// ID of the currently executing node
  final String? currentNodeId;

  /// Human-readable name of the current node
  final String? currentNodeName;

  /// Overall progress (0.0 to 1.0)
  final double progress;

  /// Status message
  final String? message;

  /// Live run-vitals snapshot for the in-flight run, when one is active.
  ///
  /// Carried on the status poll so a slave can mirror the master's Session
  /// Vitals tile (captured/rejected/autofocus/flips/dithers/triggers and the
  /// integration/overhead split). `null` when no run is active or the host did
  /// not include vitals. The local executor never populates these on a slave,
  /// so without this the slave's Vitals tile reads idle next to a live progress
  /// bar.
  final SequencerRunVitals? runVitals;

  const SequencerStatus({
    required this.state,
    this.currentNodeId,
    this.currentNodeName,
    required this.progress,
    this.message,
    this.runVitals,
  });

  /// Create from JSON (for network transport)
  factory SequencerStatus.fromJson(Map<String, dynamic> json) {
    return SequencerStatus(
      state: json['state'] as String,
      currentNodeId: json['currentNodeId'] as String?,
      currentNodeName: json['currentNodeName'] as String?,
      progress: (json['progress'] as num).toDouble(),
      message: json['message'] as String?,
      runVitals: json['runVitals'] is Map<String, dynamic>
          ? SequencerRunVitals.fromJson(
              json['runVitals'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'state': state,
    'currentNodeId': currentNodeId,
    'currentNodeName': currentNodeName,
    'progress': progress,
    'message': message,
    if (runVitals != null) 'runVitals': runVitals!.toJson(),
  };

  /// Check if sequencer is running
  bool get isRunning => state == 'running';

  /// Check if sequencer is paused
  bool get isPaused => state == 'paused';

  /// Check if sequencer is idle
  bool get isIdle => state == 'idle';
}

/// Live run-vitals counters mirrored from the master's in-flight
/// `SequenceRunStats` so a slave can reconstruct its Session Vitals tile.
///
/// This is a flat wire shape (no provider dependency) holding exactly the
/// counters the Vitals tile and warnings panel read; the client maps it back
/// onto a `SequenceRunStats` in the remote sync handler.
class SequencerRunVitals {
  final DateTime startTime;
  final DateTime? endTime;
  final int framesCaptured;
  final int framesRejected;
  final double integrationSecs;
  final int triggerFires;
  final int autofocusRuns;
  final int meridianFlips;
  final int ditherCount;
  final List<String> warningMessages;

  /// Errors recorded against the live run, so a remote/headless operator sees
  /// a failure (a meridian flip, say) before the terminal event rather than
  /// reading the run as healthy. Defaults to `const []` so an older master
  /// that omits the key still deserializes.
  final List<String> errorMessages;

  /// The directory this run's rejected frames are being moved into, or null
  /// until one is rejected. A remote operator watching a reject storm needs
  /// the path to the files, not just the count.
  final String? rejectFolder;

  /// Why this run ended badly, or null while it is healthy — the first real
  /// fault, never a teardown step the cancellation cascade tripped over.
  /// The whole cascade is in [errorMessages], in the order it happened.
  final String? terminalCause;

  const SequencerRunVitals({
    required this.startTime,
    this.endTime,
    required this.framesCaptured,
    required this.framesRejected,
    required this.integrationSecs,
    required this.triggerFires,
    required this.autofocusRuns,
    required this.meridianFlips,
    required this.ditherCount,
    this.warningMessages = const [],
    this.errorMessages = const [],
    this.rejectFolder,
    this.terminalCause,
  });

  factory SequencerRunVitals.fromJson(Map<String, dynamic> json) {
    return SequencerRunVitals(
      startTime:
          DateTime.tryParse(json['startTime'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      endTime: json['endTime'] is String
          ? DateTime.tryParse(json['endTime'] as String)
          : null,
      framesCaptured: (json['framesCaptured'] as num?)?.toInt() ?? 0,
      framesRejected: (json['framesRejected'] as num?)?.toInt() ?? 0,
      integrationSecs: (json['integrationSecs'] as num?)?.toDouble() ?? 0.0,
      triggerFires: (json['triggerFires'] as num?)?.toInt() ?? 0,
      autofocusRuns: (json['autofocusRuns'] as num?)?.toInt() ?? 0,
      meridianFlips: (json['meridianFlips'] as num?)?.toInt() ?? 0,
      ditherCount: (json['ditherCount'] as num?)?.toInt() ?? 0,
      warningMessages:
          (json['warningMessages'] as List<dynamic>?)?.cast<String>() ??
          const [],
      errorMessages:
          (json['errorMessages'] as List<dynamic>?)?.cast<String>() ?? const [],
      rejectFolder: json['rejectFolder'] as String?,
      terminalCause: json['terminalCause'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'startTime': startTime.toIso8601String(),
    if (endTime != null) 'endTime': endTime!.toIso8601String(),
    'framesCaptured': framesCaptured,
    'framesRejected': framesRejected,
    'integrationSecs': integrationSecs,
    'triggerFires': triggerFires,
    'autofocusRuns': autofocusRuns,
    'meridianFlips': meridianFlips,
    'ditherCount': ditherCount,
    'warningMessages': warningMessages,
    'errorMessages': errorMessages,
    if (rejectFolder != null) 'rejectFolder': rejectFolder,
    if (terminalCause != null) 'terminalCause': terminalCause,
  };
}

/// Checkpoint information for crash recovery
class CheckpointInfo {
  /// Name of the sequence
  final String sequenceName;

  /// When the checkpoint was saved
  final DateTime timestamp;

  /// Number of exposures completed before checkpoint
  final int completedExposures;

  /// Total integration time completed in seconds
  final double completedIntegrationSecs;

  /// Whether the checkpoint can be resumed
  final bool canResume;

  /// Age of the checkpoint in seconds
  final int ageSeconds;

  const CheckpointInfo({
    required this.sequenceName,
    required this.timestamp,
    required this.completedExposures,
    required this.completedIntegrationSecs,
    required this.canResume,
    required this.ageSeconds,
  });

  /// Create from JSON (for network transport)
  factory CheckpointInfo.fromJson(Map<String, dynamic> json) {
    return CheckpointInfo(
      sequenceName: json['sequenceName'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      completedExposures: json['completedExposures'] as int,
      completedIntegrationSecs: (json['completedIntegrationSecs'] as num)
          .toDouble(),
      canResume: json['canResume'] as bool,
      ageSeconds: json['ageSeconds'] as int,
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'sequenceName': sequenceName,
    'timestamp': timestamp.toIso8601String(),
    'completedExposures': completedExposures,
    'completedIntegrationSecs': completedIntegrationSecs,
    'canResume': canResume,
    'ageSeconds': ageSeconds,
  };

  /// Get a human-readable age string
  String get ageString {
    if (ageSeconds < 60) return '${ageSeconds}s ago';
    if (ageSeconds < 3600) return '${ageSeconds ~/ 60}m ago';
    if (ageSeconds < 86400) return '${ageSeconds ~/ 3600}h ago';
    return '${ageSeconds ~/ 86400}d ago';
  }
}
