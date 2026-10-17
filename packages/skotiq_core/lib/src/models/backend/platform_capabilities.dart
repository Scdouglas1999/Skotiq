/// Static platform support matrix for driver backends.
///
/// This describes launch-time availability. Individual devices can still report
/// narrower capabilities after they are discovered and connected.
class PlatformCapabilityMatrix {
  static const windows = 'windows';
  static const linux = 'linux';
  static const macos = 'macos';

  static const rows = <PlatformDriverCapability>[
    PlatformDriverCapability(
      backend: 'ascom',
      label: 'ASCOM COM',
      supportedPlatforms: [windows],
      unsupportedReason:
          'ASCOM COM requires Windows COM drivers and is not available on Linux or macOS.',
      deviceCoverage:
          'Camera, mount, focuser, filter wheel, rotator, dome, weather, safety monitor, switch, cover/calibrator',
      notes:
          'Use this for Windows-only ASCOM driver installations. Cross-platform ASCOM devices should use Alpaca.',
    ),
    PlatformDriverCapability(
      backend: 'alpaca',
      label: 'ASCOM Alpaca',
      supportedPlatforms: [windows, linux, macos],
      unsupportedReason: null,
      deviceCoverage:
          'Camera, mount, focuser, filter wheel, rotator, dome, weather, safety monitor, switch, cover/calibrator',
      notes:
          'Network API for ASCOM-compatible devices across supported desktop platforms.',
    ),
    PlatformDriverCapability(
      backend: 'indi',
      label: 'INDI',
      supportedPlatforms: [windows, linux, macos],
      unsupportedReason: null,
      deviceCoverage:
          'Camera, mount, focuser, filter wheel, rotator, dome, weather, safety monitor, cover/calibrator',
      notes:
          'Requires a reachable INDI server. Feature depth depends on each INDI driver.',
    ),
    PlatformDriverCapability(
      backend: 'native',
      label: 'Native SDK',
      supportedPlatforms: [windows, linux, macos],
      unsupportedReason: null,
      statusOverride: 'capability-gated',
      deviceCoverage:
          'Vendor cameras and native mount protocols where SDKs are installed.',
      notes:
          'Native vendor support is gated by OS SDK availability, packaged libraries, and installed drivers.',
    ),
    PlatformDriverCapability(
      backend: 'simulator',
      label: 'Simulator',
      supportedPlatforms: [windows, linux, macos],
      unsupportedReason: null,
      statusOverride: 'capability-gated',
      deviceCoverage: 'Workflow simulators where explicitly implemented.',
      notes:
          'Simulator availability is workflow-specific. Use ASCOM, Alpaca, or INDI simulator drivers for hardware-like smoke tests unless an in-app simulator path is explicitly enabled.',
    ),
  ];

  const PlatformCapabilityMatrix._();

  static PlatformCapabilityReport forPlatform(String platform) {
    final normalizedPlatform = normalizePlatform(platform);
    return PlatformCapabilityReport(
      platform: normalizedPlatform,
      drivers: rows,
    );
  }

  static String normalizePlatform(String platform) {
    final value = platform.trim().toLowerCase();
    if (value == 'macos' || value == 'darwin') return macos;
    if (value == 'linux') return linux;
    if (value == 'windows') return windows;
    return value.isEmpty ? 'unknown' : value;
  }
}

class PlatformCapabilityReport {
  final String platform;
  final List<PlatformDriverCapability> drivers;

  const PlatformCapabilityReport({
    required this.platform,
    required this.drivers,
  });

  Map<String, dynamic> toJson() => {
    'platform': platform,
    'drivers': drivers.map((driver) => driver.toJson(platform)).toList(),
  };
}

class PlatformDriverCapability {
  final String backend;
  final String label;
  final List<String> supportedPlatforms;
  final String? unsupportedReason;
  final String deviceCoverage;
  final String notes;
  final String? statusOverride;

  const PlatformDriverCapability({
    required this.backend,
    required this.label,
    required this.supportedPlatforms,
    required this.unsupportedReason,
    required this.deviceCoverage,
    required this.notes,
    this.statusOverride,
  });

  bool isAvailableOn(String platform) {
    final normalizedPlatform = PlatformCapabilityMatrix.normalizePlatform(
      platform,
    );
    return supportedPlatforms.contains(normalizedPlatform);
  }

  String statusFor(String platform) =>
      isAvailableOn(platform) ? statusOverride ?? 'available' : 'unsupported';

  String reasonFor(String platform) {
    if (isAvailableOn(platform)) {
      return notes;
    }
    return unsupportedReason ??
        'Unsupported on ${PlatformCapabilityMatrix.normalizePlatform(platform)}.';
  }

  Map<String, dynamic> toJson(String platform) => {
    'backend': backend,
    'label': label,
    'status': statusFor(platform),
    'supportedPlatforms': supportedPlatforms,
    'unsupportedReason': isAvailableOn(platform) ? null : reasonFor(platform),
    'deviceCoverage': deviceCoverage,
    'notes': notes,
  };
}
