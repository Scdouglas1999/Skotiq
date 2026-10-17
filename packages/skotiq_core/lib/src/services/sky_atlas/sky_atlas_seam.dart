import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

/// Injectable seam over the `api_sky_atlas*` FFI surface.
///
/// The sky-atlas native entry points are free functions on the generated
/// bridge that take a single JSON string and return a JSON string
/// (`docs/skotiq_5_0_contracts.md`). Calling them directly from
/// [SkyAtlasService] would make the service's orchestration — region bookkeeping,
/// DAO persistence, per-tile rollups — only exercisable with the Rust dynamic
/// library loaded. This seam mirrors the sibling [PostSessionSeam] injection
/// pattern: [BridgeSkyAtlasSeam] forwards to the bridge, and tests substitute a
/// fake so the service body runs end-to-end without native code.
///
/// The boundary stays at the JSON-envelope level (`Map` in, `Map` out); the
/// strongly-typed models in `sky_atlas_models.dart` decode the results.
abstract class SkyAtlasSeam {
  /// Dispatch the sky-atlas op named by [args]'s `action` field. Used for
  /// `fold` / `finalize` / `tilePng` / `coverage` / `exportDelta` / `info`.
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args);

  /// Co-add a cone into a sharable FITS (+ optional PNG) cutout.
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args);

  /// Aggregate the integration depth of a circular region.
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args);

  /// Deepening growth curve for a region (cumulative frames/seconds per fold).
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args);

  /// Additively merge a pulled community `.nst` delta into a local base tile
  /// (`{ basePath, deltaPath, trust, subtract, outPath }`). Backs the
  /// Constellation pull-back blend into "Your Sky".
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args);
}

/// Production seam: forwards each call to the FFI bridge and JSON-decodes the
/// result string. A bridge call that returns a non-object payload, or one whose
/// `ok` flag is false, is surfaced as a [SkyAtlasSeamException] rather than a
/// silently-degraded empty map.
class BridgeSkyAtlasSeam implements SkyAtlasSeam {
  const BridgeSkyAtlasSeam();

  @override
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> args) async {
    final raw = await bridge.apiSkyAtlas(argsJson: jsonEncode(args));
    return _decode(raw, args['action']?.toString() ?? 'atlas');
  }

  @override
  Future<Map<String, dynamic>> queryCutout(Map<String, dynamic> args) async {
    final raw = await bridge.apiSkyAtlasQueryCutout(argsJson: jsonEncode(args));
    return _decode(raw, 'queryCutout');
  }

  @override
  Future<Map<String, dynamic>> regionInfo(Map<String, dynamic> args) async {
    final raw = await bridge.apiSkyAtlasRegionInfo(argsJson: jsonEncode(args));
    return _decode(raw, 'regionInfo');
  }

  @override
  Future<Map<String, dynamic>> growth(Map<String, dynamic> args) async {
    final raw = await bridge.apiSkyAtlasGrowth(argsJson: jsonEncode(args));
    return _decode(raw, 'growth');
  }

  @override
  Future<Map<String, dynamic>> mergeDelta(Map<String, dynamic> args) async {
    final raw = await bridge.apiSkyAtlasMergeDelta(argsJson: jsonEncode(args));
    return _decode(raw, 'mergeDelta');
  }

  Map<String, dynamic> _decode(String raw, String op) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw SkyAtlasSeamException('atlas $op returned malformed JSON: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw SkyAtlasSeamException('atlas $op returned a non-object payload');
    }
    if (decoded['ok'] == false) {
      throw SkyAtlasSeamException(
        'atlas $op failed: ${decoded['error'] ?? 'unknown error'}',
      );
    }
    return decoded;
  }
}

/// Raised when a sky-atlas bridge call fails or returns an unusable payload.
class SkyAtlasSeamException implements Exception {
  final String message;
  const SkyAtlasSeamException(this.message);
  @override
  String toString() => 'SkyAtlasSeamException: $message';
}

/// Production seam provider. Override in tests with a fake that records the
/// dispatched maps and returns canned results.
final skyAtlasSeamProvider = Provider<SkyAtlasSeam>((ref) {
  return const BridgeSkyAtlasSeam();
});
