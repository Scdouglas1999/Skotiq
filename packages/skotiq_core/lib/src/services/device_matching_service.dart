import 'dart:math' as math;
import '../models/equipment/unified_device.dart';
import 'device_service.dart';

/// Service for matching and grouping devices from different backends
/// that represent the same physical hardware.
///
/// For example, a ZWO ASI294MC Pro camera might appear as:
/// - "ZWO ASI294MC Pro" (Native SDK)
/// - "ASI294MC Pro" (ASCOM)
/// - "ZWO CCD ASI294MC Pro" (INDI)
/// - "ASI294MC Pro Camera #1" (Alpaca)
///
/// This service groups these into a single [UnifiedDevice].
class DeviceMatchingService {
  /// Minimum similarity score (0-1) to consider two devices the same
  static const double _similarityThreshold = 0.75;

  /// Known manufacturer prefixes to strip during normalization
  static const List<String> _manufacturerPrefixes = [
    'ZWO',
    'QHY',
    'QHYCCD',
    'ASCOM',
    'INDI',
    'Celestron',
    'Meade',
    'iOptron',
    'Sky-Watcher',
    'Skywatcher',
    'Orion',
    'Player One',
    'PlayerOne',
    'Atik',
    'SBIG',
    'FLI',
    'Moravian',
    'Starlight Xpress',
    'SVBony',
    'Touptek',
    'Altair',
    'ASI', // Often prepended
    'CCD', // Generic prefix
  ];

  /// Common suffixes to strip
  static const List<String> _commonSuffixes = [
    'Camera',
    'Mount',
    'Focuser',
    'Filter Wheel',
    'Filterwheel',
    'Rotator',
    'Guider',
    'Guide Camera',
    'Guide Cam',
    'Imaging Camera',
    'Driver',
    'ASCOM',
    'CCD',
    'CMOS',
  ];

  /// Patterns for device instance numbers (e.g., "#1", "(1)", " 1")
  static final RegExp _instancePattern = RegExp(
    r'[#\(\)]\s*\d+\s*[#\(\)]?$|\s+\d+$',
  );

  /// Group raw devices by physical identity
  List<UnifiedDevice> groupDevices(List<DeviceInfo> allDevices) {
    if (allDevices.isEmpty) return [];

    // Group by device type first
    final byType = <DeviceType, List<DeviceInfo>>{};
    for (final device in allDevices) {
      byType.putIfAbsent(device.deviceType, () => []).add(device);
    }

    final result = <UnifiedDevice>[];

    // Process each device type separately
    for (final entry in byType.entries) {
      final type = entry.key;
      final devices = entry.value;

      // Track which devices have been grouped
      final grouped = <int>{};

      for (int i = 0; i < devices.length; i++) {
        if (grouped.contains(i)) continue;

        final primary = devices[i];
        final primaryNormalized = normalizeName(primary.name);

        // Start a new group with this device
        final backends = <DriverType, DeviceInfo>{primary.driverType: primary};

        // Find all matching devices
        for (int j = i + 1; j < devices.length; j++) {
          if (grouped.contains(j)) continue;

          final candidate = devices[j];

          // CRITICAL: Never merge devices from the same backend
          // This prevents two identical cameras (e.g., two ASI294MC Pro) from merging
          if (primary.driverType == candidate.driverType) continue;

          // If names are identical but IDs differ, they're separate physical devices
          if (primary.name == candidate.name && primary.id != candidate.id) {
            continue;
          }

          final candidateNormalized = normalizeName(candidate.name);

          // Check similarity
          final similarity = calculateSimilarity(
            primaryNormalized,
            candidateNormalized,
          );

          if (similarity >= _similarityThreshold) {
            // Same physical device, different backend
            if (!backends.containsKey(candidate.driverType)) {
              backends[candidate.driverType] = candidate;
              grouped.add(j);
            }
          }
        }

        grouped.add(i);

        // Create unified device
        result.add(
          UnifiedDevice(
            canonicalName: primaryNormalized,
            displayName: _selectBestDisplayName(backends.values.toList()),
            type: type,
            availableBackends: backends,
          ),
        );
      }
    }

    // Sort by driver priority (native first), then by display name
    result.sort((a, b) {
      final aHasNative = a.availableBackends.containsKey(DriverType.native);
      final bHasNative = b.availableBackends.containsKey(DriverType.native);
      if (aHasNative != bHasNative) {
        return aHasNative ? -1 : 1;
      }
      return a.displayName.compareTo(b.displayName);
    });

    return result;
  }

  /// Normalize a device name for matching
  String normalizeName(String name) {
    var normalized = name.trim();

    // Remove ASCOM. or INDI. prefix patterns
    normalized = normalized.replaceAll(
      RegExp(r'^ASCOM\.\w+\.', caseSensitive: false),
      '',
    );
    normalized = normalized.replaceAll(
      RegExp(r'^INDI\.\w+\.', caseSensitive: false),
      '',
    );

    // Extract instance numbers (#1, (1), etc.) first to preserve them
    final instanceMatch = _instancePattern.firstMatch(normalized);
    String instanceStr = '';
    if (instanceMatch != null) {
      instanceStr = instanceMatch.group(0) ?? '';
      normalized = normalized.substring(0, instanceMatch.start).trim();
    }

    // Remove known manufacturer prefixes
    for (final prefix in _manufacturerPrefixes) {
      if (normalized.toLowerCase().startsWith(prefix.toLowerCase())) {
        normalized = normalized.substring(prefix.length).trim();
        // Handle cases like "ZWO " or "ZWO-"
        if (normalized.startsWith(' ') ||
            normalized.startsWith('-') ||
            normalized.startsWith('_')) {
          normalized = normalized.substring(1).trim();
        }
      }
    }

    // Remove common suffixes
    for (final suffix in _commonSuffixes) {
      if (normalized.toLowerCase().endsWith(suffix.toLowerCase())) {
        normalized = normalized
            .substring(0, normalized.length - suffix.length)
            .trim();
      }
    }

    // Remove extra whitespace and common separators
    normalized = normalized
        .replaceAll(RegExp(r'[-_]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();

    if (instanceStr.isNotEmpty) {
      final cleanInstance = instanceStr
          .replaceAll(RegExp(r'[-_]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .toLowerCase();
      if (cleanInstance.isNotEmpty) {
        normalized = '$normalized $cleanInstance';
      }
    }

    return normalized;
  }

  /// Calculate similarity between two normalized names using Levenshtein distance
  /// Returns a value between 0 (completely different) and 1 (identical)
  double calculateSimilarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    if (a == b) return 1.0;

    // Also check if one contains the other (common case)
    if (a.contains(b) || b.contains(a)) {
      // Give a high score if one is a substring of the other
      final shorter = a.length < b.length ? a : b;
      final longer = a.length >= b.length ? a : b;
      return shorter.length / longer.length * 0.95 + 0.05; // Min 0.05 bonus
    }

    // Check for model number match (e.g., "294mc pro" should match "asi294mc pro")
    final modelA = extractModelNumber(a);
    final modelB = extractModelNumber(b);
    if (modelA != null && modelB != null && modelA == modelB) {
      return 0.9; // Strong match if model numbers are identical
    }

    // Fall back to Levenshtein distance
    final distance = _levenshteinDistance(a, b);
    final maxLen = math.max(a.length, b.length);

    return 1.0 - (distance / maxLen);
  }

  /// Extract model number/identifier from a device name
  /// E.g., "ASI294MC Pro" -> "294mcpro", "EQ6-R Pro" -> "eq6rpro"
  String? extractModelNumber(String name) {
    // Remove spaces and convert to lowercase
    final compact = name.replaceAll(RegExp(r'\s+'), '').toLowerCase();

    // Look for common model number patterns
    // Numbers followed by letters (294mc, 533mm, eq6)
    final match = RegExp(r'\d+[a-z]*(?:mc|mm|pro|r)?').firstMatch(compact);
    if (match != null) {
      return match.group(0);
    }

    // If no pattern found, return the compact string for direct comparison
    return compact.length > 3 ? compact : null;
  }

  /// Compute Levenshtein distance between two strings
  int _levenshteinDistance(String s1, String s2) {
    if (s1.isEmpty) return s2.length;
    if (s2.isEmpty) return s1.length;

    // Create two rows for the DP table
    var previousRow = List<int>.generate(s2.length + 1, (i) => i);
    var currentRow = List<int>.filled(s2.length + 1, 0);

    for (int i = 0; i < s1.length; i++) {
      currentRow[0] = i + 1;

      for (int j = 0; j < s2.length; j++) {
        final cost = s1[i] == s2[j] ? 0 : 1;
        currentRow[j + 1] = math.min(
          math.min(
            currentRow[j] + 1, // insertion
            previousRow[j + 1] + 1, // deletion
          ),
          previousRow[j] + cost, // substitution
        );
      }

      // Swap rows
      final temp = previousRow;
      previousRow = currentRow;
      currentRow = temp;
    }

    return previousRow[s2.length];
  }

  /// Select the best display name from a list of devices
  /// Prefers more complete/descriptive names
  String _selectBestDisplayName(List<DeviceInfo> devices) {
    if (devices.isEmpty) return 'Unknown Device';
    if (devices.length == 1) return devices.first.name;

    // Score each name
    String best = devices.first.name;
    int bestScore = _scoreDisplayName(best);

    for (final device in devices.skip(1)) {
      final score = _scoreDisplayName(device.name);
      if (score > bestScore) {
        best = device.name;
        bestScore = score;
      }
    }

    return best;
  }

  /// Score a display name for quality (higher = better)
  int _scoreDisplayName(String name) {
    int score = 0;

    // Prefer names with manufacturer
    for (final prefix in _manufacturerPrefixes.take(10)) {
      if (name.toLowerCase().contains(prefix.toLowerCase())) {
        score += 10;
        break;
      }
    }

    // Prefer moderate length (not too short, not too long)
    if (name.length >= 10 && name.length <= 40) {
      score += 5;
    }

    // Prefer names without ASCOM. or INDI. prefix
    if (!name.startsWith('ASCOM.') && !name.startsWith('INDI.')) {
      score += 5;
    }

    // Prefer names without instance numbers
    if (!_instancePattern.hasMatch(name)) {
      score += 3;
    }

    return score;
  }
}
