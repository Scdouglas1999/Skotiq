import 'package:equatable/equatable.dart';
import '../../services/device_service.dart';
import 'unified_device.dart';

enum DiscoveryStatus {
  /// Not yet started
  idle,

  discovering,

  completed,

  error,
}

class BackendDiscoveryState extends Equatable {
  final DriverType backend;

  final DiscoveryStatus status;

  /// Error message if status is error
  final String? error;

  final List<DeviceInfo> devices;

  final DateTime? completedAt;

  const BackendDiscoveryState({
    required this.backend,
    this.status = DiscoveryStatus.idle,
    this.error,
    this.devices = const [],
    this.completedAt,
  });

  bool get isDiscovering => status == DiscoveryStatus.discovering;

  /// Check if discovery completed (success or error)
  bool get isComplete =>
      status == DiscoveryStatus.completed || status == DiscoveryStatus.error;

  bool get isSuccess => status == DiscoveryStatus.completed;

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
  final Map<DriverType, BackendDiscoveryState> backendStates;

  /// All raw devices discovered (before grouping)
  final List<DeviceInfo> rawDevices;

  /// Devices grouped by physical identity
  final List<UnifiedDevice> groupedDevices;

  /// Overall error message (if discovery completely failed)
  final String? error;

  bool get isDiscovering =>
      backendStates.values.any((s) => s.status == DiscoveryStatus.discovering);

  bool get allComplete => backendStates.values.every((s) => s.isComplete);

  List<DriverType> get activeBackends => backendStates.entries
      .where((e) => e.value.isDiscovering)
      .map((e) => e.key)
      .toList();

  List<DriverType> get errorBackends => backendStates.entries
      .where((e) => e.value.hasError)
      .map((e) => e.key)
      .toList();

  List<DriverType> get successfulBackends => backendStates.entries
      .where((e) => e.value.isSuccess)
      .map((e) => e.key)
      .toList();

  int get totalRawDevices => rawDevices.length;

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

  BackendDiscoveryState? getBackendState(DriverType backend) =>
      backendStates[backend];

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
