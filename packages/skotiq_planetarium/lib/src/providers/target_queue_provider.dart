import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../celestial_object.dart';
import '../coordinate_system.dart';

/// Status of a queued target
enum QueuedTargetStatus {
  pending, // Waiting to be imaged
  active, // Currently being imaged
  completed, // Imaging completed
  skipped, // User skipped this target
  failed, // Failed during imaging
}

/// A target in the imaging queue
class QueuedTarget {
  final String id;
  final CelestialObject? object;
  final CelestialCoordinate coordinates;
  final String displayName;
  final QueuedTargetStatus status;
  final int priority; // Lower number = higher priority
  final DateTime? addedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final int plannedExposures;
  final int completedExposures;
  final String? notes;
  final Map<String, dynamic>? sequencerData; // For sync with sequencer

  const QueuedTarget({
    required this.id,
    this.object,
    required this.coordinates,
    required this.displayName,
    this.status = QueuedTargetStatus.pending,
    this.priority = 100,
    this.addedAt,
    this.startedAt,
    this.completedAt,
    this.plannedExposures = 0,
    this.completedExposures = 0,
    this.notes,
    this.sequencerData,
  });

  QueuedTarget copyWith({
    String? id,
    CelestialObject? object,
    CelestialCoordinate? coordinates,
    String? displayName,
    QueuedTargetStatus? status,
    int? priority,
    DateTime? addedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    int? plannedExposures,
    int? completedExposures,
    String? notes,
    Map<String, dynamic>? sequencerData,
  }) {
    return QueuedTarget(
      id: id ?? this.id,
      object: object ?? this.object,
      coordinates: coordinates ?? this.coordinates,
      displayName: displayName ?? this.displayName,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      addedAt: addedAt ?? this.addedAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      plannedExposures: plannedExposures ?? this.plannedExposures,
      completedExposures: completedExposures ?? this.completedExposures,
      notes: notes ?? this.notes,
      sequencerData: sequencerData ?? this.sequencerData,
    );
  }

  double get completionPercentage {
    if (plannedExposures <= 0) return 0;
    return (completedExposures / plannedExposures * 100).clamp(0, 100);
  }

  bool get isCompleted => status == QueuedTargetStatus.completed;
  bool get isActive => status == QueuedTargetStatus.active;
  bool get isPending => status == QueuedTargetStatus.pending;
}

/// State of the target queue
class TargetQueueState {
  final List<QueuedTarget> targets;
  final String? activeTargetId;
  final bool isRunning;
  final bool autoAdvance; // Automatically move to next target when complete
  final DateTime? sessionStartTime;

  const TargetQueueState({
    this.targets = const [],
    this.activeTargetId,
    this.isRunning = false,
    this.autoAdvance = true,
    this.sessionStartTime,
  });

  TargetQueueState copyWith({
    List<QueuedTarget>? targets,
    String? activeTargetId,
    bool clearActiveTarget = false,
    bool? isRunning,
    bool? autoAdvance,
    DateTime? sessionStartTime,
  }) {
    return TargetQueueState(
      targets: targets ?? this.targets,
      activeTargetId: clearActiveTarget
          ? null
          : (activeTargetId ?? this.activeTargetId),
      isRunning: isRunning ?? this.isRunning,
      autoAdvance: autoAdvance ?? this.autoAdvance,
      sessionStartTime: sessionStartTime ?? this.sessionStartTime,
    );
  }

  QueuedTarget? get activeTarget {
    if (activeTargetId == null) return null;
    return targets.cast<QueuedTarget?>().firstWhere(
      (t) => t?.id == activeTargetId,
      orElse: () => null,
    );
  }

  List<QueuedTarget> get pendingTargets =>
      targets.where((t) => t.status == QueuedTargetStatus.pending).toList();

  List<QueuedTarget> get completedTargets =>
      targets.where((t) => t.status == QueuedTargetStatus.completed).toList();

  int get totalPlannedExposures =>
      targets.fold(0, (sum, t) => sum + t.plannedExposures);

  int get totalCompletedExposures =>
      targets.fold(0, (sum, t) => sum + t.completedExposures);

  double get overallProgress {
    if (totalPlannedExposures <= 0) return 0;
    return (totalCompletedExposures / totalPlannedExposures * 100).clamp(
      0,
      100,
    );
  }
}

/// Notifier for managing the target queue
class TargetQueueNotifier extends StateNotifier<TargetQueueState> {
  TargetQueueNotifier() : super(const TargetQueueState());
  int _idSequence = 0;

  /// Add a target to the queue
  void addTarget(
    CelestialObject object, {
    int? priority,
    int plannedExposures = 0,
    String? notes,
  }) {
    final id = _newTargetId(object.id);
    final newTarget = QueuedTarget(
      id: id,
      object: object,
      coordinates: object.coordinates,
      displayName: object.name.isNotEmpty ? object.name : object.id,
      priority: priority ?? state.targets.length + 1,
      addedAt: DateTime.now(),
      plannedExposures: plannedExposures.clamp(0, 0x7FFFFFFF),
      notes: notes,
    );

    final updatedTargets = [...state.targets, newTarget];
    updatedTargets.sort((a, b) => a.priority.compareTo(b.priority));

    state = state.copyWith(targets: _normalizePriorities(updatedTargets));
  }

  /// Add a coordinate target (not a catalog object)
  void addCoordinateTarget(
    CelestialCoordinate coordinates,
    String name, {
    int? priority,
    int plannedExposures = 0,
    String? notes,
  }) {
    final id = _newTargetId('coord');
    final newTarget = QueuedTarget(
      id: id,
      coordinates: coordinates,
      displayName: name,
      priority: priority ?? state.targets.length + 1,
      addedAt: DateTime.now(),
      plannedExposures: plannedExposures.clamp(0, 0x7FFFFFFF),
      notes: notes,
    );

    final updatedTargets = [...state.targets, newTarget];
    updatedTargets.sort((a, b) => a.priority.compareTo(b.priority));

    state = state.copyWith(targets: _normalizePriorities(updatedTargets));
  }

  /// Remove a target from the queue
  void removeTarget(String targetId) {
    final updatedTargets = _normalizePriorities(
      state.targets.where((t) => t.id != targetId).toList(),
    );
    state = state.copyWith(
      targets: updatedTargets,
      activeTargetId: state.activeTargetId == targetId
          ? null
          : state.activeTargetId,
      clearActiveTarget: state.activeTargetId == targetId,
    );
  }

  /// Move a target to a new priority position
  void reorderTarget(String targetId, int newPriority) {
    final ordered = [...state.targets]
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final oldIndex = ordered.indexWhere((target) => target.id == targetId);
    if (oldIndex < 0) return;
    final target = ordered.removeAt(oldIndex);
    final newIndex = (newPriority - 1).clamp(0, ordered.length);
    ordered.insert(newIndex, target);
    state = state.copyWith(targets: _normalizePriorities(ordered));
  }

  /// Set the active target
  void setActiveTarget(String? targetId) {
    if (targetId == null) {
      state = state.copyWith(clearActiveTarget: true);
      return;
    }
    if (targetId == state.activeTargetId) return;
    if (!state.targets.any((target) => target.id == targetId)) return;

    // Update previous active target to pending if it wasn't completed
    final updatedTargets = state.targets.map((t) {
      if (t.id == state.activeTargetId &&
          t.status == QueuedTargetStatus.active) {
        return t.copyWith(status: QueuedTargetStatus.pending);
      }
      if (t.id == targetId) {
        return t.copyWith(
          status: QueuedTargetStatus.active,
          startedAt: DateTime.now(),
        );
      }
      return t;
    }).toList();

    state = state.copyWith(targets: updatedTargets, activeTargetId: targetId);
  }

  /// Mark the active target as completed
  void completeActiveTarget() {
    if (state.activeTargetId == null) return;

    final updatedTargets = state.targets.map((t) {
      if (t.id == state.activeTargetId) {
        return t.copyWith(
          status: QueuedTargetStatus.completed,
          completedAt: DateTime.now(),
          completedExposures: t.plannedExposures,
        );
      }
      return t;
    }).toList();

    state = state.copyWith(targets: updatedTargets, clearActiveTarget: true);

    // Auto-advance to next pending target if enabled
    if (state.autoAdvance) {
      final nextPending = updatedTargets.cast<QueuedTarget?>().firstWhere(
        (t) => t?.status == QueuedTargetStatus.pending,
        orElse: () => null,
      );
      if (nextPending != null) {
        setActiveTarget(nextPending.id);
      }
    }
  }

  /// Skip the active target
  void skipActiveTarget() {
    if (state.activeTargetId == null) return;

    final updatedTargets = state.targets.map((t) {
      if (t.id == state.activeTargetId) {
        return t.copyWith(status: QueuedTargetStatus.skipped);
      }
      return t;
    }).toList();

    state = state.copyWith(targets: updatedTargets, clearActiveTarget: true);

    // Auto-advance to next pending target if enabled
    if (state.autoAdvance) {
      final nextPending = updatedTargets.cast<QueuedTarget?>().firstWhere(
        (t) => t?.status == QueuedTargetStatus.pending,
        orElse: () => null,
      );
      if (nextPending != null) {
        setActiveTarget(nextPending.id);
      }
    }
  }

  /// Update exposure progress for the active target
  void updateExposureProgress(int completedExposures) {
    if (state.activeTargetId == null) return;

    var reachedPlan = false;
    final updatedTargets = state.targets.map((t) {
      if (t.id == state.activeTargetId) {
        final completed = t.plannedExposures > 0
            ? completedExposures.clamp(0, t.plannedExposures)
            : completedExposures.clamp(0, 0x7FFFFFFF);
        reachedPlan = t.plannedExposures > 0 && completed >= t.plannedExposures;
        return t.copyWith(
          completedExposures: completed,
          status: reachedPlan
              ? QueuedTargetStatus.completed
              : QueuedTargetStatus.active,
        );
      }
      return t;
    }).toList();

    state = state.copyWith(targets: updatedTargets);
    if (reachedPlan) completeActiveTarget();
  }

  /// Start the imaging session
  void startSession() {
    if (state.targets.isEmpty) return;

    // Set first pending target as active
    final firstPending = state.targets.cast<QueuedTarget?>().firstWhere(
      (t) => t?.status == QueuedTargetStatus.pending,
      orElse: () => null,
    );
    if (firstPending == null) return;
    state = state.copyWith(isRunning: true, sessionStartTime: DateTime.now());
    setActiveTarget(firstPending.id);
  }

  /// Stop/pause the imaging session
  void stopSession() {
    state = state.copyWith(isRunning: false);
  }

  /// Clear all targets
  void clearQueue() {
    state = const TargetQueueState();
  }

  /// Clear only completed targets
  void clearCompletedTargets() {
    final updatedTargets = _normalizePriorities(
      state.targets
          .where((t) => t.status != QueuedTargetStatus.completed)
          .toList(),
    );
    state = state.copyWith(targets: updatedTargets);
  }

  String _newTargetId(String prefix) {
    return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_idSequence++}';
  }

  List<QueuedTarget> _normalizePriorities(List<QueuedTarget> targets) {
    return [
      for (var i = 0; i < targets.length; i++)
        targets[i].copyWith(priority: i + 1),
    ];
  }

  /// Toggle auto-advance setting
  void setAutoAdvance(bool enabled) {
    state = state.copyWith(autoAdvance: enabled);
  }

  /// Update target notes
  void updateTargetNotes(String targetId, String? notes) {
    final updatedTargets = state.targets.map((t) {
      if (t.id == targetId) {
        return t.copyWith(notes: notes);
      }
      return t;
    }).toList();

    state = state.copyWith(targets: updatedTargets);
  }

  /// Sync from sequencer - update queue based on sequencer data
  void syncFromSequencer(List<Map<String, dynamic>> sequencerTargets) {
    final existingById = <String, QueuedTarget>{
      for (final target in state.targets) target.id: target,
    };
    final existingBySequencerId = <String, QueuedTarget>{
      for (final target in state.targets)
        if (target.sequencerData?['sequencerId'] != null)
          target.sequencerData!['sequencerId'].toString(): target,
    };

    final syncedTargets = <QueuedTarget>[];

    for (var i = 0; i < sequencerTargets.length; i++) {
      final seqTarget = sequencerTargets[i];
      final sequencerId = seqTarget['sequencerId']?.toString();
      final sourceId = seqTarget['id']?.toString();
      final resolvedId = sourceId?.isNotEmpty == true
          ? sourceId!
          : (sequencerId?.isNotEmpty == true
                ? 'seq_$sequencerId'
                : 'seq_orphan_$i');

      final existing =
          existingById[resolvedId] ??
          (sequencerId != null ? existingBySequencerId[sequencerId] : null);

      final coordinates = _coordinatesFromSequencer(seqTarget, existing);
      if (coordinates == null) {
        continue;
      }

      final plannedExposures = _intFromAny(
        seqTarget['plannedExposures'] ?? seqTarget['totalExposures'],
      );
      final completedExposures = _intFromAny(
        seqTarget['completedExposures'] ?? seqTarget['completed'],
      );

      // Queue timestamps are history, not state: they may only come from the
      // sequencer payload or from what this queue already recorded. Stamping
      // "now" onto a target the sequencer added (or finished) at some earlier
      // point would invent an event time the operator could later read back as
      // fact, so an unreported time stays null — QueuedTarget models all three
      // as nullable precisely so "unknown" is expressible.
      final syncedStatus = _mapSequencerStatus(seqTarget['status']?.toString());
      final addedAt =
          existing?.addedAt ?? _dateTimeFromAny(seqTarget['addedAt']);
      final completedAt = syncedStatus == QueuedTargetStatus.completed
          ? (existing?.completedAt ??
                _dateTimeFromAny(seqTarget['completedAt']))
          : existing?.completedAt;

      final queuedTarget = QueuedTarget(
        id: resolvedId,
        object: existing?.object,
        coordinates: coordinates,
        displayName: (seqTarget['name']?.toString().trim().isNotEmpty ?? false)
            ? seqTarget['name'].toString().trim()
            : (existing?.displayName ?? resolvedId),
        status: syncedStatus,
        priority: _intFromAny(seqTarget['priority']) ?? (i + 1),
        addedAt: addedAt,
        startedAt:
            existing?.startedAt ?? _dateTimeFromAny(seqTarget['startedAt']),
        completedAt: completedAt,
        plannedExposures: plannedExposures ?? existing?.plannedExposures ?? 0,
        completedExposures:
            completedExposures ?? existing?.completedExposures ?? 0,
        notes: seqTarget['notes']?.toString() ?? existing?.notes,
        sequencerData: seqTarget,
      );

      syncedTargets.add(queuedTarget);
    }

    syncedTargets.sort((a, b) => a.priority.compareTo(b.priority));

    final hasActiveTarget = syncedTargets.any(
      (t) => t.status == QueuedTargetStatus.active,
    );
    final activeTargetId = hasActiveTarget
        ? syncedTargets
              .firstWhere((t) => t.status == QueuedTargetStatus.active)
              .id
        : (syncedTargets.any((t) => t.id == state.activeTargetId)
              ? state.activeTargetId
              : null);

    state = state.copyWith(
      targets: syncedTargets,
      activeTargetId: activeTargetId,
      clearActiveTarget: activeTargetId == null,
    );
  }

  QueuedTargetStatus _mapSequencerStatus(String? status) {
    switch (status) {
      case 'running':
      case 'active':
        return QueuedTargetStatus.active;
      case 'completed':
      case 'done':
        return QueuedTargetStatus.completed;
      case 'skipped':
        return QueuedTargetStatus.skipped;
      case 'failed':
      case 'error':
        return QueuedTargetStatus.failed;
      default:
        return QueuedTargetStatus.pending;
    }
  }

  int? _intFromAny(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  double? _doubleFromAny(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  /// A sequencer-reported instant, or null when the payload carries none.
  /// Accepts epoch milliseconds and ISO-8601; anything else is "not reported"
  /// rather than a guess.
  DateTime? _dateTimeFromAny(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    return DateTime.tryParse(value.toString());
  }

  CelestialCoordinate? _coordinatesFromSequencer(
    Map<String, dynamic> seqTarget,
    QueuedTarget? fallback,
  ) {
    final raDegrees = _doubleFromAny(seqTarget['raDegrees']);
    final decDegrees = _doubleFromAny(seqTarget['decDegrees']);
    if (raDegrees != null && decDegrees != null) {
      return CelestialCoordinate(ra: raDegrees / 15.0, dec: decDegrees);
    }

    final raHours = _doubleFromAny(seqTarget['ra']);
    final dec = _doubleFromAny(seqTarget['dec']);
    if (raHours != null && dec != null) {
      return CelestialCoordinate(ra: raHours, dec: dec);
    }

    return fallback?.coordinates;
  }

  /// Export queue to sequencer format
  List<Map<String, dynamic>> exportToSequencer() {
    return state.targets
        .map(
          (t) => {
            'id': t.id,
            'name': t.displayName,
            'ra': t.coordinates.ra,
            'dec': t.coordinates.dec,
            'raDegrees': t.coordinates.raDegrees,
            'priority': t.priority,
            'plannedExposures': t.plannedExposures,
            'notes': t.notes,
            if (t.object != null) 'objectId': t.object!.id,
            if (t.object != null && t.object is DeepSkyObject)
              'type': (t.object as DeepSkyObject).type.name,
          },
        )
        .toList();
  }
}

/// Provider for the target queue
final targetQueueProvider =
    StateNotifierProvider<TargetQueueNotifier, TargetQueueState>((ref) {
      return TargetQueueNotifier();
    });
