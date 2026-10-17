import 'radar_tile_decoder.dart';

/// Provider-specific radar reflectivity colormaps.
///
/// Each provider paints its tiles with a fixed colour ramp encoding rainfall
/// intensity (reflectivity, dBZ). To recover a per-cell intensity from the tile
/// pixels we match each opaque pixel to the nearest ramp anchor and read off its
/// normalised intensity. The anchors below are the canonical colours of each
/// provider's scheme; they are the single source of truth shared by the decoder
/// and its tests, so the colormap mapping is pinned and cannot silently drift.
class RadarColormaps {
  RadarColormaps._();

  /// RainViewer colour scheme 2 ("Universal Blue"), the default scheme our
  /// RainViewer tile URLs request (`.../2/1_1.png`). The ramp runs from light
  /// drizzle (pale blue) through heavy rain to violent storms (magenta).
  ///
  /// Anchors are evenly spaced across 0..1 so the mapping is monotonic with
  /// reflectivity: pale blue ≈ light, green/yellow ≈ moderate, red/magenta ≈
  /// heavy. Intensities ≥ the cloud-density threshold (0.3) therefore
  /// correspond to genuinely significant echoes, which is exactly what the
  /// cloud-motion analyzer tracks.
  static const RadarColormap rainViewerScheme2 = RadarColormap(
    name: 'RainViewer scheme 2 (Universal Blue)',
    stops: [
      // Light precipitation — pale to mid blue.
      RadarColorStop(r: 200, g: 230, b: 255, intensity: 0.10),
      RadarColorStop(r: 100, g: 180, b: 255, intensity: 0.25),
      RadarColorStop(r: 0, g: 120, b: 255, intensity: 0.40),
      // Moderate — greens to yellow.
      RadarColorStop(r: 0, g: 200, b: 90, intensity: 0.55),
      RadarColorStop(r: 230, g: 230, b: 0, intensity: 0.70),
      // Heavy — orange to red.
      RadarColorStop(r: 255, g: 150, b: 0, intensity: 0.82),
      RadarColorStop(r: 230, g: 0, b: 0, intensity: 0.92),
      // Extreme — magenta.
      RadarColorStop(r: 220, g: 0, b: 220, intensity: 1.0),
    ],
  );

  /// NWS / NEXRAD base-reflectivity (N0Q) colour ramp as served by the Iowa
  /// Environmental Mesonet `nexrad-n0q-900913` WMS layer (used by the NOAA
  /// provider). The canonical NWS reflectivity palette: light green at low dBZ,
  /// rising through yellow and red to white/violet at the most violent echoes.
  static const RadarColormap nexradN0q = RadarColormap(
    name: 'NWS NEXRAD N0Q base reflectivity',
    stops: [
      // Light returns — greens (~5–30 dBZ).
      RadarColorStop(r: 4, g: 233, b: 231, intensity: 0.08),
      RadarColorStop(r: 1, g: 159, b: 244, intensity: 0.16),
      RadarColorStop(r: 3, g: 0, b: 244, intensity: 0.24),
      RadarColorStop(r: 2, g: 253, b: 2, intensity: 0.35),
      RadarColorStop(r: 1, g: 197, b: 1, intensity: 0.45),
      RadarColorStop(r: 0, g: 142, b: 0, intensity: 0.52),
      // Moderate — yellows/oranges (~35–50 dBZ).
      RadarColorStop(r: 253, g: 248, b: 2, intensity: 0.62),
      RadarColorStop(r: 229, g: 188, b: 0, intensity: 0.70),
      RadarColorStop(r: 253, g: 149, b: 0, intensity: 0.78),
      // Heavy — reds (~55–65 dBZ).
      RadarColorStop(r: 253, g: 0, b: 0, intensity: 0.86),
      RadarColorStop(r: 212, g: 0, b: 0, intensity: 0.90),
      RadarColorStop(r: 188, g: 0, b: 0, intensity: 0.93),
      // Extreme — white then violet (>70 dBZ).
      RadarColorStop(r: 248, g: 0, b: 253, intensity: 0.97),
      RadarColorStop(r: 152, g: 84, b: 198, intensity: 1.0),
    ],
  );

  /// GOES infrared cloud-top brightness ramp (grayscale). Used by the GOES
  /// satellite provider: cold, high cloud tops are painted bright, clear warm
  /// ground dark, so per-pixel luminance is a real per-cell cloud field.
  static const LuminanceColormap goesInfrared = LuminanceColormap(
    name: 'GOES infrared cloud-top brightness',
  );
}
