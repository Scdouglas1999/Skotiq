import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Types of long-running hardware operations that can be tracked.
enum OperationType {
  slewToTarget,
  autofocus,
  filterChange,
  plateSolve,
  cooling,
  warming,
  centeringLoop,
  domeSlew,
  parkMount,
  unparkMount,
  dither,
  guideSettle,
  focuserMove,
  rotatorMove,
}

/// Human-readable labels for operation types.
extension OperationTypeLabel on OperationType {
  String get label {
    switch (this) {
      case OperationType.slewToTarget:
        return 'Slewing to target';
      case OperationType.autofocus:
        return 'Autofocus';
      case OperationType.filterChange:
        return 'Changing filter';
      case OperationType.plateSolve:
        return 'Plate solving';
      case OperationType.cooling:
        return 'Cooling camera';
      case OperationType.warming:
        return 'Warming camera';
      case OperationType.centeringLoop:
        return 'Centering target';
      case OperationType.domeSlew:
        return 'Slewing dome';
      case OperationType.parkMount:
        return 'Parking mount';
      case OperationType.unparkMount:
        return 'Unparking mount';
      case OperationType.dither:
        return 'Dithering';
      case OperationType.guideSettle:
        return 'Settling guiding';
      case OperationType.focuserMove:
        return 'Moving focuser';
      case OperationType.rotatorMove:
        return 'Rotating';
    }
  }

  String get activeLabel {
    switch (this) {
      case OperationType.slewToTarget:
        return 'Slewing...';
      case OperationType.autofocus:
        return 'Focusing...';
      case OperationType.filterChange:
        return 'Changing filter...';
      case OperationType.plateSolve:
        return 'Solving...';
      case OperationType.cooling:
        return 'Cooling...';
      case OperationType.warming:
        return 'Warming...';
      case OperationType.centeringLoop:
        return 'Centering...';
      case OperationType.domeSlew:
        return 'Dome moving...';
      case OperationType.parkMount:
        return 'Parking...';
      case OperationType.unparkMount:
        return 'Unparking...';
      case OperationType.dither:
        return 'Dithering...';
      case OperationType.guideSettle:
        return 'Settling...';
      case OperationType.focuserMove:
        return 'Focusing...';
      case OperationType.rotatorMove:
        return 'Rotating...';
    }
  }
}

/// Represents the progress of an active operation.
class OperationProgress {
  /// The type of operation being performed.
  final OperationType type;

  /// Human-readable description of what's happening.
  final String description;

  /// Progress from 0.0 to 1.0, or null for indeterminate.
  final double? progress;

  /// When the operation started.
  final DateTime startedAt;

  /// Current step description (e.g., "Measuring HFR" for autofocus).
  final String? currentStep;

  /// Whether this operation can be cancelled by the user.
  final bool canCancel;

  /// A unique ID for this operation instance.
  final String id;

  const OperationProgress({
    required this.type,
    required this.description,
    required this.startedAt,
    required this.id,
    this.progress,
    this.currentStep,
    this.canCancel = false,
  });

  /// Create a copy with updated fields.
  OperationProgress copyWith({
    OperationType? type,
    String? description,
    double? progress,
    DateTime? startedAt,
    String? currentStep,
    bool? canCancel,
  }) {
    return OperationProgress(
      type: type ?? this.type,
      description: description ?? this.description,
      progress: progress ?? this.progress,
      startedAt: startedAt ?? this.startedAt,
      currentStep: currentStep ?? this.currentStep,
      canCancel: canCancel ?? this.canCancel,
      id: id,
    );
  }

  /// Get the elapsed time since the operation started.
  Duration get elapsed => DateTime.now().difference(startedAt);

  /// Format elapsed time as MM:SS.
  String get elapsedFormatted {
    final e = elapsed;
    final minutes = e.inMinutes;
    final seconds = e.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  String toString() =>
      'OperationProgress($type, $description, progress: $progress)';
}

/// State for the active operations provider.
class ActiveOperationsState {
  /// Currently active operations, keyed by type.
  /// Only one operation of each type can be active at a time.
  final Map<OperationType, OperationProgress> _operations;

  const ActiveOperationsState([
    Map<OperationType, OperationProgress>? operations,
  ]) : _operations = operations ?? const {};

  /// Get all active operations.
  List<OperationProgress> get all => _operations.values.toList();

  /// Check if any operations are active.
  bool get isEmpty => _operations.isEmpty;
  bool get isNotEmpty => _operations.isNotEmpty;

  /// Get a specific operation by type.
  OperationProgress? operator [](OperationType type) => _operations[type];

  /// Check if a specific operation type is active.
  bool isActive(OperationType type) => _operations.containsKey(type);

  /// Get the primary operation (first one, or null if none).
  OperationProgress? get primary => _operations.values.firstOrNull;

  /// Get count of active operations.
  int get count => _operations.length;

  /// Create a copy with an operation added.
  ActiveOperationsState withOperation(OperationProgress op) {
    return ActiveOperationsState({..._operations, op.type: op});
  }

  /// Create a copy with an operation removed.
  ActiveOperationsState withoutOperation(OperationType type) {
    final newOps = Map<OperationType, OperationProgress>.from(_operations);
    newOps.remove(type);
    return ActiveOperationsState(newOps);
  }

  /// Create a copy with an operation updated.
  ActiveOperationsState withUpdatedOperation(
    OperationType type,
    OperationProgress Function(OperationProgress) update,
  ) {
    final existing = _operations[type];
    if (existing == null) return this;
    return ActiveOperationsState({..._operations, type: update(existing)});
  }
}

/// Notifier for managing active operations.
class ActiveOperationsNotifier extends StateNotifier<ActiveOperationsState> {
  ActiveOperationsNotifier() : super(const ActiveOperationsState());

  int _operationCounter = 0;

  /// Start tracking a new operation.
  String startOperation({
    required OperationType type,
    required String description,
    double? progress,
    String? currentStep,
    bool canCancel = false,
  }) {
    final id = '${type.name}_${++_operationCounter}';
    final op = OperationProgress(
      type: type,
      description: description,
      progress: progress,
      startedAt: DateTime.now(),
      currentStep: currentStep,
      canCancel: canCancel,
      id: id,
    );
    state = state.withOperation(op);
    return id;
  }

  /// Update the progress of an operation.
  void updateProgress(
    OperationType type, {
    double? progress,
    String? currentStep,
    String? operationId,
  }) {
    if (operationId != null && state[type]?.id != operationId) return;
    state = state.withUpdatedOperation(type, (op) {
      return op.copyWith(progress: progress, currentStep: currentStep);
    });
  }

  /// Mark an operation as complete and remove it. When [operationId] is
  /// supplied, a stale completion from an older same-type request cannot clear
  /// the newer request that replaced it in the status map.
  void completeOperation(OperationType type, {String? operationId}) {
    if (operationId != null && state[type]?.id != operationId) return;
    state = state.withoutOperation(type);
  }

  /// Cancel an operation (if cancellable).
  void cancelOperation(OperationType type, {String? operationId}) {
    // The actual cancellation logic would be handled by the caller
    // This just removes the tracking
    completeOperation(type, operationId: operationId);
  }

  /// Clear all operations (e.g., on disconnect or error).
  void clearAll() {
    state = const ActiveOperationsState();
  }

  /// Check if a specific operation is active.
  bool isOperationActive(OperationType type) {
    return state.isActive(type);
  }
}

/// Provider for tracking active long-running operations.
final activeOperationsProvider =
    StateNotifierProvider<ActiveOperationsNotifier, ActiveOperationsState>((
      ref,
    ) {
      return ActiveOperationsNotifier();
    });

/// Convenience provider to get the primary (first) active operation.
final primaryOperationProvider = Provider<OperationProgress?>((ref) {
  return ref.watch(activeOperationsProvider).primary;
});

/// Convenience provider to check if any operation is active.
final hasActiveOperationProvider = Provider<bool>((ref) {
  return ref.watch(activeOperationsProvider).isNotEmpty;
});
