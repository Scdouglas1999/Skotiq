import 'package:freezed_annotation/freezed_annotation.dart';

part 'radar_frame.freezed.dart';
part 'radar_frame.g.dart';

/// Type of radar tile service
enum RadarTileType {
  /// Standard XYZ slippy map tiles (used by RainViewer, OpenStreetMap, etc.)
  /// URL format: .../256/{z}/{x}/{y}.png
  xyz,

  /// WMS (Web Map Service) tiles (used by NOAA NEXRAD, etc.)
  /// Uses bounding box parameters instead of tile coordinates
  wms,
}

/// Represents a single radar frame in the animation sequence
@freezed
abstract class RadarFrame with _$RadarFrame {
  const factory RadarFrame({
    /// When this radar frame was captured
    required DateTime timestamp,

    /// URL template for map tiles
    /// - For XYZ: template with {z}/{x}/{y} tokens
    /// - For WMS: base URL (without bbox parameter)
    required String tileUrlTemplate,

    /// Geographic bounds - northern boundary
    required double north,

    /// Geographic bounds - southern boundary
    required double south,

    /// Geographic bounds - eastern boundary
    required double east,

    /// Geographic bounds - western boundary
    required double west,

    /// Opacity for animation blending (0.0-1.0)
    @Default(1.0) double opacity,

    /// Per-cell radar intensity field over the frame's geographic bounds, in
    /// row-major order (outer list = rows running NORTH→SOUTH, inner list =
    /// columns running WEST→EAST), each value normalised to 0.0–1.0.
    ///
    /// This is the spatial radar signal decoded from the provider's tiles (the
    /// reflectivity colormap mapped to intensity per pixel, downsampled to this
    /// grid).
    ///
    /// The grid spans exactly [north]..[south] (rows) and [west]..[east]
    /// (columns); cell (r, c) covers the geographic sub-rectangle obtained by
    /// linearly interpolating those bounds. Null when the provider could not
    /// decode per-cell data (e.g. a tile-less WMS layer or a fetch/decode
    /// failure) — the analyzer then treats the frame as having no spatial data
    /// and reports its honest unavailable reason rather than fabricating motion.
    List<List<double>>? intensityGrid,

    /// True when this frame was produced but carries no usable radar signal
    /// (the tile fetch or decode failed). Such a frame is emitted — rather than
    /// silently dropped — so the analyzer/UI can report an honest "no spatial
    /// radar data" state instead of acting on a fabricated uniform field. A
    /// no-data frame never contributes density to the analysis.
    @Default(false) bool isNoData,

    /// True if this is a forecast frame vs historical
    @Default(false) bool isForecast,

    /// Type of tile service (XYZ or WMS)
    @Default(RadarTileType.xyz) RadarTileType tileType,

    /// WMS layer name(s) - only used when tileType is wms
    String? wmsLayers,

    /// Additional WMS parameters (e.g., time, styles) - only used when tileType is wms
    Map<String, String>? wmsAdditionalOptions,
  }) = _RadarFrame;

  factory RadarFrame.fromJson(Map<String, dynamic> json) =>
      _$RadarFrameFromJson(json);
}
