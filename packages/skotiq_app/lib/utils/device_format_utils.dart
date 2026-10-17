import 'package:skotiq_core/skotiq_core.dart';

/// Format a device ID into a user-friendly display name.
///
/// Handles the following formats:
/// - Native: `native:vendor:index` or `native:vendor_type:index`
/// - ASCOM: `ascom:ASCOM.Vendor.Type` or `ASCOM.Vendor.Type`
/// - Alpaca: `alpaca:host:port:device_number`
/// - PHD2 identifiers
/// - INDI: `indi:host:port:device_name`
///
/// This is the rich UI display formatter (vendor capitalization, indexing).
/// It is intentionally distinct from `friendlyNameFromDeviceId` in
/// skotiq_core (the no-discovery fallback used by `DeviceService`); the
/// canonical PHD2 recognition, however, is shared via [isPhd2DeviceId] so the
/// strict id forms are classified identically everywhere.
String formatDeviceId(String id) {
  final lowerId = id.toLowerCase();

  // Built-in multi-star guider has a fixed canonical ID. Recognize it before
  // the generic native:vendor:index path so the display name reads cleanly.
  // The name is the constant skotiq_core and the Rust discovery record
  // share, so the two Dart formatters cannot drift.
  if (lowerId.startsWith(kBuiltinGuiderIdPrefix)) {
    return kBuiltinGuiderDisplayName;
  }

  // Simulator ids (`sim_filterwheel_1`) are named by skotiq_core from the
  // same table the backend's discovery uses. Without this the fallback
  // `cleanupDeviceId` produced "Sim Filterwheel 1" here while the run
  // dashboard said "Simulated Filter Wheel" — one device, two names.
  if (lowerId.startsWith('sim_')) {
    final simulator = friendlyNameFromDeviceId(id);
    if (simulator != id) return simulator;
  }

  // Handle native device IDs: native:vendor:index or native:vendor_type:index
  if (lowerId.startsWith('native:')) {
    final parts = id.substring(7).split(':');
    if (parts.isNotEmpty) {
      final devicePart = parts[0];
      final index = parts.length > 1 ? int.tryParse(parts[1]) : null;

      // Handle vendor_type format (e.g., zwo_eaf)
      if (devicePart.contains('_')) {
        final subParts = devicePart.split('_');
        final vendor = capitalizeVendor(subParts[0]);
        final type = subParts.sublist(1).map((s) => s.toUpperCase()).join(' ');
        return '$vendor $type';
      }

      // Simple vendor format
      final vendor = capitalizeVendor(devicePart);
      if (index != null) {
        return '$vendor #${index + 1}';
      }
      return vendor;
    }
  }

  // Handle ASCOM device IDs: ascom:ASCOM.Vendor.Type or ASCOM.Vendor.Type
  if (lowerId.startsWith('ascom:') || lowerId.startsWith('ascom.')) {
    final ascomId = lowerId.startsWith('ascom:') ? id.substring(6) : id;
    final parts = ascomId.split('.');
    if (parts.length >= 2) {
      final vendorPart = parts.length > 1 ? parts[1] : parts[0];
      return formatAscomVendor(vendorPart);
    }
  }

  // Handle Alpaca device IDs
  if (lowerId.startsWith('alpaca:')) {
    final alpacaPart = id.substring(7);
    return 'Alpaca: $alpacaPart';
  }

  // Handle PHD2. Strict id forms (phd2 / phd2_guider / phd2:… / phd2://…)
  // go through the shared canonical recognizer; the looser `contains` checks
  // remain so display still labels free-form "PHD 2"-style names.
  if (isPhd2DeviceId(id) ||
      lowerId.contains('phd2') ||
      lowerId.contains('phd 2')) {
    return 'PHD2';
  }

  // Fallback: try to clean up the ID
  return cleanupDeviceId(id);
}

/// Capitalize a vendor name using known vendor mappings.
///
/// Maps lowercase vendor identifiers to their proper display names,
/// e.g. `zwo` -> `ZWO`, `skywatcher` -> `Sky-Watcher`.
String capitalizeVendor(String vendor) {
  const knownVendors = {
    'zwo': 'ZWO',
    'asi': 'ZWO ASI',
    'qhy': 'QHY',
    'playerone': 'PlayerOne',
    'svbony': 'SVBony',
    'atik': 'Atik',
    'fli': 'FLI',
    'moravian': 'Moravian',
    'touptek': 'Touptek',
    'pegasus': 'Pegasus',
    'pegasusastro': 'Pegasus Astro',
    'ioptron': 'iOptron',
    'skywatcher': 'Sky-Watcher',
    'celestron': 'Celestron',
    'meade': 'Meade',
    'losmandy': 'Losmandy',
    'moonlite': 'MoonLite',
    'optec': 'Optec',
    'lacerta': 'Lacerta',
    'esatto': 'Esatto',
    'primaluce': 'PrimaLuce',
  };

  final lower = vendor.toLowerCase();
  if (knownVendors.containsKey(lower)) {
    return knownVendors[lower]!;
  }

  // Default: capitalize first letter
  if (vendor.isEmpty) return vendor;
  return vendor[0].toUpperCase() + vendor.substring(1);
}

/// Format an ASCOM vendor string by adding spaces before capital letters
/// and numbers (e.g. `FocuserPro` -> `Focuser Pro`).
String formatAscomVendor(String vendor) {
  final spaced = vendor.replaceAllMapped(
    RegExp(r'([a-z])([A-Z0-9])'),
    (m) => '${m.group(1)} ${m.group(2)}',
  );
  return spaced;
}

/// Clean up an unrecognized device ID for display.
///
/// Strips common prefixes, replaces separators with spaces,
/// removes trailing index numbers, and capitalizes words.
String cleanupDeviceId(String id) {
  // Remove common prefixes
  var cleaned = id;
  for (final prefix in ['native:', 'ascom:', 'alpaca:', 'ASCOM.']) {
    if (cleaned.toLowerCase().startsWith(prefix.toLowerCase())) {
      cleaned = cleaned.substring(prefix.length);
    }
  }

  // Replace underscores and dots with spaces
  cleaned = cleaned.replaceAll('_', ' ').replaceAll('.', ' ');

  // Remove trailing numbers that look like indices
  cleaned = cleaned.replaceAll(RegExp(r'\s*:\s*\d+$'), '');

  // Capitalize words
  if (cleaned.isNotEmpty) {
    cleaned = cleaned.split(' ').map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1);
    }).join(' ');
  }

  return cleaned.isEmpty ? id : cleaned;
}
