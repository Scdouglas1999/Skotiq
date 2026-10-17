import 'package:equatable/equatable.dart';
import '../../services/device_service.dart';

/// Priority order for driver backends (lower = higher priority)
const Map<DriverType, int> _backendPriority = {
  DriverType.native: 0,
  DriverType.ascom: 1,
  DriverType.alpaca: 2,
  DriverType.indi: 3,
  DriverType.simulator: 4,
};

/// Represents a single physical device that may be available through multiple backends.
///
/// For example, a ZWO ASI294MC Pro camera might be discoverable via:
/// - Native SDK (highest priority)
/// - ASCOM driver
/// - Alpaca remote connection
/// - INDI server
///
/// This class groups all those discovery results into a single logical device,
/// allowing the user to choose which backend to use for connection.
class UnifiedDevice extends Equatable {
  /// Canonical name for the device (cleaned/normalized for matching)
  final String canonicalName;

  /// Display name (most descriptive name from available backends)
  final String displayName;

  /// Device type (camera, mount, focuser, etc.)
  final DeviceType type;

  /// Map of backend -> device info for all available backends
  final Map<DriverType, DeviceInfo> availableBackends;

  /// The currently selected backend (user choice, or null for default)
  final DriverType? selectedBackend;

  const UnifiedDevice({
    required this.canonicalName,
    required this.displayName,
    required this.type,
    required this.availableBackends,
    this.selectedBackend,
  });

  /// The recommended backend based on static priority (Native > ASCOM > Alpaca > INDI > Simulator)
  /// For capability-aware selection, use [recommendedBackendForCapabilities] instead.
  DriverType get recommendedBackend {
    if (availableBackends.isEmpty) {
      throw StateError(
        'UnifiedDevice "$displayName" has no available backends',
      );
    }

    DriverType best = availableBackends.keys.first;
    int bestPriority = _backendPriority[best] ?? 99;

    for (final backend in availableBackends.keys) {
      final priority = _backendPriority[backend] ?? 99;
      if (priority < bestPriority) {
        best = backend;
        bestPriority = priority;
      }
    }

    return best;
  }

  /// Get recommended backend considering capability requirements.
  ///
  /// Capability-aware selection considers:
  /// - [requireRemoteOperation]: Prefer network-capable backends (Alpaca, INDI)
  /// - [preferLinuxCompatible]: Prefer cross-platform backends (INDI, Native, Alpaca)
  /// - [requireFullFeatureSet]: Prefer backends with complete feature support (Native, ASCOM)
  ///
  /// Falls back to [recommendedBackend] if no backends match the requirements.
  DriverType recommendedBackendForCapabilities({
    bool requireRemoteOperation = false,
    bool preferLinuxCompatible = false,
    bool requireFullFeatureSet = false,
  }) {
    if (availableBackends.isEmpty) {
      throw StateError(
        'UnifiedDevice "$displayName" has no available backends',
      );
    }

    // Score each backend based on requirements
    final scoredBackends = <DriverType, int>{};

    for (final backend in availableBackends.keys) {
      int score =
          100 -
          ((_backendPriority[backend] ?? 99) * 10); // Base score from priority

      // Remote operation capability (Alpaca and INDI support remote)
      if (requireRemoteOperation) {
        if (backend == DriverType.alpaca || backend == DriverType.indi) {
          score += 50; // Strongly prefer remote-capable
        } else {
          score -= 100; // Heavily penalize non-remote backends
        }
      }

      // Linux/cross-platform compatibility
      if (preferLinuxCompatible) {
        switch (backend) {
          case DriverType.ascom:
            score -= 30; // ASCOM is Windows-only
            break;
          case DriverType.indi:
          case DriverType.native:
          case DriverType.alpaca:
            score += 20; // Cross-platform friendly
            break;
          case DriverType.simulator:
            score += 10; // Simulator works everywhere
            break;
        }
      }

      // Full feature set (Native and ASCOM typically have best feature support)
      if (requireFullFeatureSet) {
        switch (backend) {
          case DriverType.native:
            score += 30; // Native SDK usually has all features
            break;
          case DriverType.ascom:
            score += 25; // ASCOM also comprehensive
            break;
          case DriverType.alpaca:
            score += 15; // Alpaca mirrors ASCOM
            break;
          case DriverType.indi:
            score += 10; // INDI varies by driver
            break;
          case DriverType.simulator:
            score += 5; // Simulator has limited features
            break;
        }
      }

      scoredBackends[backend] = score;
    }

    // Find the highest scoring backend
    DriverType best = availableBackends.keys.first;
    int bestScore = scoredBackends[best] ?? 0;

    for (final entry in scoredBackends.entries) {
      if (entry.value > bestScore) {
        best = entry.key;
        bestScore = entry.value;
      }
    }

    return best;
  }

  /// Get backends sorted by capability score for a given set of requirements.
  /// Useful for UI to show users ranked backend options.
  List<DriverType> getSortedBackendsForCapabilities({
    bool requireRemoteOperation = false,
    bool preferLinuxCompatible = false,
    bool requireFullFeatureSet = false,
  }) {
    final backends = availableBackends.keys.toList();

    backends.sort((a, b) {
      final scoreA = _getCapabilityScore(
        a,
        requireRemoteOperation,
        preferLinuxCompatible,
        requireFullFeatureSet,
      );
      final scoreB = _getCapabilityScore(
        b,
        requireRemoteOperation,
        preferLinuxCompatible,
        requireFullFeatureSet,
      );
      return scoreB.compareTo(scoreA); // Higher score first
    });

    return backends;
  }

  int _getCapabilityScore(
    DriverType backend,
    bool requireRemote,
    bool preferLinux,
    bool requireFeatures,
  ) {
    int score = 100 - ((_backendPriority[backend] ?? 99) * 10);

    if (requireRemote) {
      score += (backend == DriverType.alpaca || backend == DriverType.indi)
          ? 50
          : -100;
    }
    if (preferLinux) {
      score += backend == DriverType.ascom ? -30 : 20;
    }
    if (requireFeatures) {
      score += backend == DriverType.native
          ? 30
          : backend == DriverType.ascom
          ? 25
          : 10;
    }
    return score;
  }

  /// The active backend (selected by user, or recommended if not selected)
  DriverType get activeBackend => selectedBackend ?? recommendedBackend;

  /// Get the device ID for the active backend
  String get activeDeviceId => availableBackends[activeBackend]!.id;

  /// Get the DeviceInfo for the active backend
  DeviceInfo get activeDevice => availableBackends[activeBackend]!;

  /// Check if a specific backend is available for this device
  bool hasBackend(DriverType backend) => availableBackends.containsKey(backend);

  /// Get the device ID for a specific backend (null if not available)
  String? getDeviceIdForBackend(DriverType backend) =>
      availableBackends[backend]?.id;

  /// List of all available backends, sorted by priority
  List<DriverType> get sortedBackends {
    final backends = availableBackends.keys.toList();
    backends.sort(
      (a, b) =>
          (_backendPriority[a] ?? 99).compareTo(_backendPriority[b] ?? 99),
    );
    return backends;
  }

  /// Create a copy with a different selected backend
  UnifiedDevice withSelectedBackend(DriverType? backend) {
    return UnifiedDevice(
      canonicalName: canonicalName,
      displayName: displayName,
      type: type,
      availableBackends: availableBackends,
      selectedBackend: backend,
    );
  }

  /// Add a backend to this unified device
  UnifiedDevice withBackend(DriverType backend, DeviceInfo device) {
    return UnifiedDevice(
      canonicalName: canonicalName,
      displayName: displayName,
      type: type,
      availableBackends: {...availableBackends, backend: device},
      selectedBackend: selectedBackend,
    );
  }

  @override
  List<Object?> get props => [
    canonicalName,
    displayName,
    type,
    availableBackends,
    selectedBackend,
  ];

  @override
  String toString() =>
      'UnifiedDevice($displayName, backends: ${availableBackends.keys.map((b) => b.displayName).join(", ")})';
}

/// Extension to get human-readable backend descriptions
extension DriverTypeDescription on DriverType {
  /// Get a description of this backend for tooltips
  String get description {
    switch (this) {
      case DriverType.native:
        return 'Direct SDK connection where the release includes the required vendor library';
      case DriverType.ascom:
        return 'Windows-only ASCOM COM driver. Use Alpaca for cross-platform ASCOM devices.';
      case DriverType.alpaca:
        return 'ASCOM Alpaca over network. Device capabilities are reported by the Alpaca server.';
      case DriverType.indi:
        return 'INDI protocol through a reachable INDI server. Feature support depends on the driver.';
      case DriverType.simulator:
        return 'Simulated device where that workflow is enabled for testing';
    }
  }

  /// Get a short label for chips
  String get shortLabel {
    switch (this) {
      case DriverType.native:
        return 'Native';
      case DriverType.ascom:
        return 'ASCOM COM';
      case DriverType.alpaca:
        return 'Alpaca';
      case DriverType.indi:
        return 'INDI';
      case DriverType.simulator:
        return 'Sim';
    }
  }
}
