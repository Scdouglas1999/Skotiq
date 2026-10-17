import 'package:equatable/equatable.dart';
import '../../services/device_service.dart';
import 'unified_device.dart';

/// Status of discovery for a single backend
enum DiscoveryStatus {
  /// Not yet started
  idle,

  /// Currently discovering devices
  discovering,

  /// Discovery completed successfully
  completed,

  /// Discovery failed with an error
  error,
}

/// Discovery state for a single backend
class BackendDiscoveryState extends Equatable {
  /// The backend being discovered
  final DriverType backend;

  /// Current status
  final DiscoveryStatus status;

  /// Error message if status is error
  final String? error;

  /// Devices discovered from this backend
  final List<DeviceInfo> devices;

  /// When discovery completed
  final DateTime? completedAt;

  const BackendDiscoveryState({
    required this.backend,
    this.status = DiscoveryStatus.idle,
    this.error,
    this.devices = const [],
    this.completedAt,
  });

  /// Check if discovery is in progress
  bool get isDiscovering => status == DiscoveryStatus.discovering;

  /// Check if discovery completed (success or error)
  bool get isComplete =>
      status == DiscoveryStatus.completed || status == DiscoveryStatus.error;

  /// Check if discovery was successful
  bool get isSuccess => status == DiscoveryStatus.completed;

  /// Check if discovery had an error
  bool get hasError => status == DiscoveryStatus.error;

  BackendDiscoveryState copyWith({
    DriverType? backend,
    DiscoveryStatus? status,
    String? error,
    List<DeviceInfo>? devices,
    DateTime? completedAt,
    bool clearError = false,
  }) {
    return BackendDiscoveryState(
      backend: backend ?? this.backend,
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
      devices: devices ?? this.devices,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  @override
  List<Object?> get props => [backend, status, error, devices, completedAt];
}

/// Overall discovery state across all backends
class UnifiedDiscoveryState extends Equatable {
  /// Discovery state per backend
  final Map<DriverType, BackendDiscoveryState> backendStates;

  /// All raw devices discovered (before grouping)
  final List<DeviceInfo> rawDevices;

  /// Devices grouped by physical identity
  final List<UnifiedDevice> groupedDevices;

  /// Overall error message (if discovery completely failed)
  final String? error;

  /// Whether any backend is currently discovering
  bool get isDiscovering =>
      backendStates.values.any((s) => s.status == DiscoveryStatus.discovering);

  /// Whether all backends have completed discovery
  bool get allComplete => backendStates.values.every((s) => s.isComplete);

  /// Backends that are currently discovering
  List<DriverType> get activeBackends => backendStates.entries
      .where((e) => e.value.isDiscovering)
      .map((e) => e.key)
      .toList();

  /// Backends that had errors
  List<DriverType> get errorBackends => backendStates.entries
      .where((e) => e.value.hasError)
      .map((e) => e.key)
      .toList();

  /// Backends that completed successfully
  List<DriverType> get successfulBackends => backendStates.entries
      .where((e) => e.value.isSuccess)
      .map((e) => e.key)
      .toList();

  /// Total number of raw devices discovered
  int get totalRawDevices => rawDevices.length;

  /// Total number of unified (grouped) devices
  int get totalGroupedDevices => groupedDevices.length;

  /// Newest successful discovery timestamp across backends.
  DateTime? get lastDiscoveryCompletedAt {
    DateTime? newest;
    for (final backendState in backendStates.values) {
      final completed = backendState.completedAt;
      if (completed != null && (newest == null || completed.isAfter(newest))) {
        newest = completed;
      }
    }
    return newest;
  }

  const UnifiedDiscoveryState({
    this.backendStates = const {},
    this.rawDevices = const [],
    this.groupedDevices = const [],
    this.error,
  });

  /// Get discovery state for a specific backend
  BackendDiscoveryState? getBackendState(DriverType backend) =>
      backendStates[backend];

  /// Get grouped devices of a specific type
  List<UnifiedDevice> getDevicesByType(DeviceType type) =>
      groupedDevices.where((d) => d.type == type).toList();

  UnifiedDiscoveryState copyWith({
    Map<DriverType, BackendDiscoveryState>? backendStates,
    List<DeviceInfo>? rawDevices,
    List<UnifiedDevice>? groupedDevices,
    String? error,
    bool clearError = false,
  }) {
    return UnifiedDiscoveryState(
      backendStates: backendStates ?? this.backendStates,
      rawDevices: rawDevices ?? this.rawDevices,
      groupedDevices: groupedDevices ?? this.groupedDevices,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [backendStates, rawDevices, groupedDevices, error];
}
