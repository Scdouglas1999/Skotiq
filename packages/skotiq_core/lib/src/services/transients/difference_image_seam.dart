import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

/// Injectable seam over the `api_difference_image` FFI surface (Pillar B —
/// "First Light", `docs/skotiq_5_0_contracts.md`).
///
/// The native difference entry point is a free function on the generated bridge
/// taking a single JSON string and returning a JSON string.
/// Calling it directly from [FirstLightService] would make the service's
/// orchestration — cross-matching, dismissal suppression, DAO persistence —
/// only exercisable with the Rust dynamic library loaded. This seam mirrors the
/// sibling [SkyAtlasSeam] injection pattern: [BridgeDifferenceImageSeam]
/// forwards to the bridge, and tests substitute a fake so the service body runs
/// end-to-end without native code.
abstract class DifferenceImageSeam {
  /// Difference one plate-solved frame against the atlas template; returns the
  /// decoded `{ candidates, tilesChecked, tilesSkippedThin, … }` envelope.
  Future<Map<String, dynamic>> difference(Map<String, dynamic> args);

  /// Resolve a HEALPix tile id to its sky centre (`{ tileId, ra, dec }`).
  Future<Map<String, dynamic>> tileCenter(Map<String, dynamic> args);
}

/// Production seam: forwards each call to the FFI bridge and JSON-decodes the
/// result string. A bridge call that returns a non-object payload, or one whose
/// `ok` flag is false, is surfaced as a [DifferenceImageSeamException] rather
/// than a silently-degraded empty map.
class BridgeDifferenceImageSeam implements DifferenceImageSeam {
  const BridgeDifferenceImageSeam();

  @override
  Future<Map<String, dynamic>> difference(Map<String, dynamic> args) async {
    final raw = await bridge.apiDifferenceImage(argsJson: jsonEncode(args));
    return _decode(raw, 'difference', requireOk: true);
  }

  @override
  Future<Map<String, dynamic>> tileCenter(Map<String, dynamic> args) async {
    final raw = await bridge.apiDifferenceTileCenter(
      argsJson: jsonEncode(args),
    );
    // tileCenter has no `ok` flag — it always returns `{ tileId, ra, dec }`.
    return _decode(raw, 'tileCenter', requireOk: false);
  }

  Map<String, dynamic> _decode(
    String raw,
    String op, {
    required bool requireOk,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw DifferenceImageSeamException(
        'difference $op returned malformed JSON: $e',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw DifferenceImageSeamException(
        'difference $op returned a non-object payload',
      );
    }
    if (requireOk && decoded['ok'] == false) {
      throw DifferenceImageSeamException(
        'difference $op failed: ${decoded['error'] ?? 'unknown error'}',
      );
    }
    return decoded;
  }
}

/// Raised when a difference-image bridge call fails or returns an unusable
/// payload.
class DifferenceImageSeamException implements Exception {
  final String message;
  const DifferenceImageSeamException(this.message);
  @override
  String toString() => 'DifferenceImageSeamException: $message';
}

/// Production seam provider. Override in tests with a fake that records the
/// dispatched maps and returns canned candidate envelopes.
final differenceImageSeamProvider = Provider<DifferenceImageSeam>((ref) {
  return const BridgeDifferenceImageSeam();
});
