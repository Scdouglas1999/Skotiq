import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../celestial_object.dart';
import '../coordinate_system.dart';
import 'hyg_depth.dart';

/// Deep-star tile format ("SKDT") — the on-disk unit of the downloadable
/// deep-star catalog tier (Tycho-2 / Gaia subset below the bundled HYG floor).
///
/// The sky is divided into a fixed grid of 24 RA bands (1h each) x 18 Dec
/// bands (10 deg each) — deliberately the SAME geometry as
/// `CelestialSpatialIndex` so tile-level culling agrees with how the renderer
/// already culls HYG stars. One tile = one file `tile_rRR_dDD.skdt`.
///
/// Binary layout (little-endian), version 1:
/// ```
/// offset size  field
///      0    4  magic 'SKDT' ('NSDT' on tiles published before the rename)
///      4    2  format version (u16) = 1
///      6    1  raBand  (u8, 0..23)
///      7    1  decBand (u8, 0..17)
///      8    4  star count (u32)
///     12    4  reserved/flags (u32) = 0
///     16  12*N records, sorted ascending by magnitude (brightest first):
///              u32 ra  in micro-hours   (ra_hours  * 1e6, 0..24e6)
///              i32 dec in micro-degrees (dec_deg   * 1e6)
///              i16 magnitude in milli-mag (mag * 1000)
///              i16 B-V color index in milli-mag (bv * 1000),
///                  0x7FFF (32767) = unknown
/// ```
/// 12 bytes/star: ~1.2 MB per 100k stars. Positions are quantized to
/// ~3.6 mas (RA at equator) / 3.6 mas (Dec) — far below screen resolution.
class DeepStarTileScheme {
  DeepStarTileScheme._();

  /// RA bands (1 hour each) — matches `CelestialSpatialIndex.raCells`.
  static const int raBands = 24;

  /// Dec bands (10 degrees each) — matches `CelestialSpatialIndex.decCells`.
  static const int decBands = 18;

  /// File name for a tile.
  static String tileFileName(int raBand, int decBand) =>
      'tile_r${raBand.toString().padLeft(2, '0')}'
      '_d${decBand.toString().padLeft(2, '0')}.skdt';

  /// RA band for an RA in hours (0-24).
  static int raBandOf(double raHours) {
    final r = raHours % 24.0;
    final normalized = r < 0 ? r + 24.0 : r;
    return (normalized / 24.0 * raBands).floor().clamp(0, raBands - 1);
  }

  /// Dec band for a declination in degrees (-90..+90).
  static int decBandOf(double decDeg) =>
      ((decDeg + 90.0) / 180.0 * decBands).floor().clamp(0, decBands - 1);

  /// Tile keys (raBand, decBand) intersecting a viewport, using the same
  /// generous region bounds as `CelestialSpatialIndex.queryBrightestInViewport`
  /// (1.5x-FOV margin, RA wraparound, pole widening) so the deep tier culls
  /// consistently with the HYG star path.
  static List<(int, int)> tilesForViewport(
    double centerRaHours,
    double centerDecDeg,
    double fovDegrees,
  ) {
    final region = ViewportRegion.compute(
      centerRaHours,
      centerDecDeg,
      fovDegrees,
    );

    final startDec = decBandOf(region.minDec);
    final endDec = decBandOf(region.maxDec);

    final keys = <(int, int)>[];
    if (region.wrapsWholeSkyInRa) {
      for (var r = 0; r < raBands; r++) {
        for (var d = startDec; d <= endDec; d++) {
          keys.add((r, d));
        }
      }
      return keys;
    }

    // Contiguous RA band range with wraparound, mirroring queryViewport.
    final minRa = centerRaHours - region.raHalfWidthHours;
    final maxRa = centerRaHours + region.raHalfWidthHours;
    final startRa = raBandOf(minRa);
    final endRa = raBandOf(maxRa);

    void addRange(int from, int to) {
      for (var r = from; r <= to; r++) {
        for (var d = startDec; d <= endDec; d++) {
          keys.add((r, d));
        }
      }
    }

    if (maxRa >= 24.0 || minRa < 0.0) {
      if (startRa <= endRa) {
        addRange(startRa, endRa);
      } else {
        addRange(startRa, raBands - 1);
        addRange(0, endRa);
      }
    } else {
      addRange(startRa, endRa);
    }
    return keys;
  }
}

/// Viewport region bounds shared by tile selection and per-star filtering.
///
/// Mirrors the math in `CelestialSpatialIndex.queryBrightestInViewport` so
/// the deep tier returns the same membership a grid query would.
class ViewportRegion {
  final double centerRaHours;
  final double minDec;
  final double maxDec;

  /// Half-width of the RA window in hours; >= 12 means the whole sky wraps.
  final double raHalfWidthHours;

  bool get wrapsWholeSkyInRa => raHalfWidthHours >= 12.0;

  const ViewportRegion({
    required this.centerRaHours,
    required this.minDec,
    required this.maxDec,
    required this.raHalfWidthHours,
  });

  factory ViewportRegion.compute(
    double centerRaHours,
    double centerDecDeg,
    double fovDegrees, {
    double aspectRatio = 1.0,
  }) {
    // Aspect-corrected: fovDegrees is the canvas SHORT axis, so the long axis
    // spans that much again times the aspect ratio. A square region leaves a
    // wide window's outer columns with no tile data (see CelestialSpatialIndex).
    final a = (aspectRatio.isFinite && aspectRatio > 0) ? aspectRatio : 1.0;
    final queryFov = fovDegrees * 1.5 * (a >= 1.0 ? a : 1.0);
    final decHalf = fovDegrees * 1.5 * (a < 1.0 ? 1.0 / a : 1.0) / 2;
    final minDec = (centerDecDeg - decHalf).clamp(-90.0, 90.0);
    final maxDec = (centerDecDeg + decHalf).clamp(-90.0, 90.0);
    final cosDec = math.cos(centerDecDeg.abs() * math.pi / 180);
    final raHalf = cosDec > 0.1
        ? (queryFov / 15 / cosDec).clamp(0.0, 12.0) / 2
        : 12.0;
    return ViewportRegion(
      centerRaHours: centerRaHours,
      minDec: minDec,
      maxDec: maxDec,
      raHalfWidthHours: raHalf,
    );
  }

  /// Whether a star at (raHours, decDeg) is inside the region.
  bool contains(double raHours, double decDeg) {
    if (decDeg < minDec || decDeg > maxDec) return false;
    if (wrapsWholeSkyInRa) return true;
    var dRa = (raHours - centerRaHours).abs();
    if (dRa > 12) dRa = 24 - dRa;
    return dRa <= raHalfWidthHours;
  }
}

/// One record in a deep-star tile, in catalog units.
class DeepStarRecord {
  /// RA in hours (0-24).
  final double raHours;

  /// Dec in degrees (-90..+90).
  final double decDeg;

  /// Visual magnitude.
  final double magnitude;

  /// B-V color index, or null when the source has no color.
  final double? bv;

  const DeepStarRecord({
    required this.raHours,
    required this.decDeg,
    required this.magnitude,
    this.bv,
  });
}

/// Encoder/decoder for the SKDT tile binary format.
class DeepStarTile {
  static const int formatVersion = 1;
  static const int headerBytes = 16;
  static const int recordBytes = 12;
  static const int _bvUnknown = 0x7FFF;

  /// 'SKDT' as bytes — the magic new tiles are written with.
  static const List<int> magic = [0x53, 0x4B, 0x44, 0x54];

  /// 'NSDT' as bytes — the magic on tiles published before the rename.
  /// Layout-identical to [magic]'s version; accepted on decode so already
  /// installed and already hosted tilesets keep working.
  static const List<int> legacyMagic = [0x4E, 0x53, 0x44, 0x54];

  final int raBand;
  final int decBand;

  /// Stars sorted ascending by magnitude (brightest first).
  final List<DeepStarRecord> records;

  DeepStarTile({
    required this.raBand,
    required this.decBand,
    required List<DeepStarRecord> records,
  }) : records = List<DeepStarRecord>.of(records)
         ..sort((a, b) => a.magnitude.compareTo(b.magnitude));

  /// Encode the tile to its binary form.
  Uint8List encode() {
    final bytes = Uint8List(headerBytes + recordBytes * records.length);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < 4; i++) {
      data.setUint8(i, magic[i]);
    }
    data.setUint16(4, formatVersion, Endian.little);
    data.setUint8(6, raBand);
    data.setUint8(7, decBand);
    data.setUint32(8, records.length, Endian.little);
    data.setUint32(12, 0, Endian.little);

    var off = headerBytes;
    for (final r in records) {
      final raMicro = (r.raHours * 1e6).round().clamp(0, 24000000);
      final decMicro = (r.decDeg * 1e6).round().clamp(-90000000, 90000000);
      final milliMag = (r.magnitude * 1000).round().clamp(-32768, 32766);
      final bv = r.bv;
      final milliBv = bv == null
          ? _bvUnknown
          : (bv * 1000).round().clamp(-32768, 32766);
      data.setUint32(off, raMicro, Endian.little);
      data.setInt32(off + 4, decMicro, Endian.little);
      data.setInt16(off + 8, milliMag, Endian.little);
      data.setInt16(off + 10, milliBv, Endian.little);
      off += recordBytes;
    }
    return bytes;
  }

  /// Decode a tile from its binary form.
  ///
  /// Throws [FormatException] on bad magic, unsupported version, or a
  /// truncated payload. Tiles carrying the pre-rename [legacyMagic] decode
  /// exactly like current [magic] tiles — the layouts are identical.
  static DeepStarTile decode(Uint8List bytes) {
    if (bytes.length < headerBytes) {
      throw const FormatException('SKDT tile truncated (no header)');
    }
    final data = ByteData.sublistView(bytes);
    var current = true;
    var legacy = true;
    for (var i = 0; i < 4; i++) {
      current &= data.getUint8(i) == magic[i];
      legacy &= data.getUint8(i) == legacyMagic[i];
    }
    if (!current && !legacy) {
      throw const FormatException('Not an SKDT tile (bad magic)');
    }
    final version = data.getUint16(4, Endian.little);
    if (version != formatVersion) {
      throw FormatException('Unsupported SKDT version $version');
    }
    final raBand = data.getUint8(6);
    final decBand = data.getUint8(7);
    final count = data.getUint32(8, Endian.little);
    final expected = headerBytes + recordBytes * count;
    if (bytes.length < expected) {
      throw FormatException(
        'SKDT tile truncated: ${bytes.length} bytes, expected $expected',
      );
    }

    final records = <DeepStarRecord>[];
    var off = headerBytes;
    for (var i = 0; i < count; i++) {
      final raMicro = data.getUint32(off, Endian.little);
      final decMicro = data.getInt32(off + 4, Endian.little);
      final milliMag = data.getInt16(off + 8, Endian.little);
      final milliBv = data.getInt16(off + 10, Endian.little);
      records.add(
        DeepStarRecord(
          raHours: raMicro / 1e6,
          decDeg: decMicro / 1e6,
          magnitude: milliMag / 1000.0,
          bv: milliBv == _bvUnknown ? null : milliBv / 1000.0,
        ),
      );
      off += recordBytes;
    }
    return DeepStarTile(raBand: raBand, decBand: decBand, records: records);
  }

  /// Convert decoded records to renderable [Star]s.
  ///
  /// Ids are deterministic per tile slot; names are empty so the renderer
  /// never tries to label deep-tier stars (it only labels mag < 2 anyway).
  /// The B-V color index is mapped to an approximate spectral letter because
  /// the star painter colors by spectral type.
  List<Star> toStars() {
    final stars = <Star>[];
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      stars.add(
        Star(
          id: 'DEEP_${raBand}_${decBand}_$i',
          name: '',
          coordinates: CelestialCoordinate(ra: r.raHours, dec: r.decDeg),
          magnitude: r.magnitude,
          colorIndex: r.bv,
          spectralType: spectralTypeFromBv(r.bv),
        ),
      );
    }
    return stars;
  }

  /// Approximate main-sequence spectral letter for a B-V color index.
  static String? spectralTypeFromBv(double? bv) {
    if (bv == null) return null;
    if (bv < -0.02) return 'B';
    if (bv < 0.30) return 'A';
    if (bv < 0.58) return 'F';
    if (bv < 0.81) return 'G';
    if (bv < 1.40) return 'K';
    return 'M';
  }
}

/// Entry for one tile in the tileset manifest.
class DeepStarManifestTile {
  final int raBand;
  final int decBand;
  final String file;
  final int sizeBytes;
  final String sha256;
  final int starCount;

  const DeepStarManifestTile({
    required this.raBand,
    required this.decBand,
    required this.file,
    required this.sizeBytes,
    required this.sha256,
    required this.starCount,
  });

  Map<String, Object?> toJson() => {
    'ra': raBand,
    'dec': decBand,
    'file': file,
    'bytes': sizeBytes,
    'sha256': sha256,
    'stars': starCount,
  };

  factory DeepStarManifestTile.fromJson(Map<String, Object?> json) =>
      DeepStarManifestTile(
        raBand: (json['ra'] as num).toInt(),
        decBand: (json['dec'] as num).toInt(),
        file: json['file'] as String,
        sizeBytes: (json['bytes'] as num).toInt(),
        sha256: json['sha256'] as String,
        starCount: (json['stars'] as num).toInt(),
      );
}

/// Manifest describing a complete deep-star tileset (`manifest.json` at the
/// tileset root, both on the hosting server and locally once installed).
class DeepStarManifest {
  static const String formatName = 'skotiq-deep-star-tiles';

  final int formatVersion;
  final String name;
  final String source;

  /// Bright cutoff of the tier: stars brighter than this are expected to come
  /// from the bundled HYG catalog and are excluded from tiles.
  final double magnitudeFloor;

  /// Faint limit of the tier.
  final double magnitudeLimit;

  final DateTime? generated;
  final List<DeepStarManifestTile> tiles;

  const DeepStarManifest({
    this.formatVersion = DeepStarTile.formatVersion,
    required this.name,
    required this.source,
    required this.magnitudeFloor,
    required this.magnitudeLimit,
    this.generated,
    required this.tiles,
  });

  int get totalStars => tiles.fold(0, (sum, t) => sum + t.starCount);
  int get totalBytes => tiles.fold(0, (sum, t) => sum + t.sizeBytes);

  Map<String, Object?> toJson() => {
    'format': formatName,
    'formatVersion': formatVersion,
    'name': name,
    'source': source,
    'magnitudeFloor': magnitudeFloor,
    'magnitudeLimit': magnitudeLimit,
    if (generated != null) 'generated': generated!.toIso8601String(),
    'tileCount': tiles.length,
    'totalStars': totalStars,
    'totalBytes': totalBytes,
    'tiles': tiles.map((t) => t.toJson()).toList(),
  };

  String encodeJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory DeepStarManifest.fromJson(Map<String, Object?> json) {
    if (json['format'] != formatName) {
      throw FormatException(
        'Not a deep-star tileset manifest (format=${json['format']})',
      );
    }
    final version = (json['formatVersion'] as num?)?.toInt() ?? 0;
    if (version != DeepStarTile.formatVersion) {
      throw FormatException('Unsupported manifest formatVersion $version');
    }
    return DeepStarManifest(
      formatVersion: version,
      name: json['name'] as String? ?? 'Deep-star tier',
      source: json['source'] as String? ?? 'unknown',
      // A manifest that omits its bright cutoff falls back to where HYG
      // actually runs out. The merge seam takes
      // max(kHygFaintFloorMag, magnitudeFloor), so a brighter default drops
      // every tier star between it and kHygFaintFloorMag — magnitudes the
      // bundled catalog does not hold either, leaving a hole exactly where the
      // tier exists to fill one.
      magnitudeFloor:
          (json['magnitudeFloor'] as num?)?.toDouble() ?? kHygFaintFloorMag,
      magnitudeLimit: (json['magnitudeLimit'] as num?)?.toDouble() ?? 13.0,
      generated: json['generated'] is String
          ? DateTime.tryParse(json['generated'] as String)
          : null,
      tiles: (json['tiles'] as List<dynamic>? ?? const [])
          .map(
            (t) => DeepStarManifestTile.fromJson(
              (t as Map).cast<String, Object?>(),
            ),
          )
          .toList(),
    );
  }

  static DeepStarManifest decodeJson(String text) => DeepStarManifest.fromJson(
    (jsonDecode(text) as Map).cast<String, Object?>(),
  );
}
