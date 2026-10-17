import 'package:equatable/equatable.dart';

import 'hips_properties.dart';

/// Identifies a single HiPS tile within a survey by its HEALPix address.
///
/// A HiPS survey is a HEALPix pyramid: at each order `k` (`Norder`) the sphere
/// is partitioned into `12 * 4^k` diamond-shaped pixels, each rendered as one
/// image tile addressed by its NESTED-scheme pixel index `npix`. This value
/// type is the pure-Dart addressing primitive the framing tile layer keys its
/// fetch/cache/compositing on; it carries no image data and performs no I/O.
///
/// The on-server layout follows IVOA HiPS 1.0 section 4.5: tiles are grouped
/// into directory buckets of 10000 (`Dir = floor(npix / 10000) * 10000`) so a
/// single directory never holds more than 10000 files, giving the path
/// `Norder{k}/Dir{d}/Npix{n}.{ext}`. The whole-sky thumbnail used as the
/// coarsest level-of-detail fallback lives at `Norder{k}/Allsky.{ext}`.
///
/// Value equality is by [survey] + [norder] + [npix] so tile ids can be used as
/// map keys for a tile cache or as set members for request de-duplication.
class HipsTileId extends Equatable {
  /// Number of tiles in a HiPS directory bucket per the standard
  /// (`Dir = floor(npix / 10000) * 10000`).
  static const int tilesPerDirectory = 10000;

  /// Survey identifier this tile belongs to. This is an opaque key the
  /// addressing scheme does not interpret (callers typically use the CDS HiPS
  /// id such as `CDS/P/DSS2/red`); it participates in equality so tiles from
  /// different surveys never collide in a shared cache.
  final String survey;

  /// HEALPix order (`Norder`, the HiPS depth level) of the tile.
  final int norder;

  /// NESTED-scheme HEALPix pixel index (`Npix`) of the tile at [norder].
  final int npix;

  HipsTileId({required this.survey, required this.norder, required this.npix})
    : assert(survey.isNotEmpty, 'survey must not be empty'),
      assert(norder >= 0 && norder <= 29, 'norder out of HiPS range'),
      assert(npix >= 0, 'npix must be non-negative') {
    final tileCount = numberOfTiles(norder);
    if (npix >= tileCount) {
      throw ArgumentError.value(
        npix,
        'npix',
        'exceeds tile count $tileCount for Norder $norder '
            '(12 * 4^$norder)',
      );
    }
  }

  /// The number of HEALPix tiles at [order]: `12 * 4^order`.
  static int numberOfTiles(int order) {
    if (order < 0 || order > 29) {
      throw ArgumentError.value(order, 'order', 'out of HiPS range [0, 29]');
    }
    return 12 * (1 << (2 * order));
  }

  /// The directory bucket index for this tile: `floor(npix / 10000) * 10000`.
  ///
  /// This is the `{d}` in the `Dir{d}` path segment defined by HiPS 1.0
  /// section 4.5; it groups tiles so no directory exceeds
  /// [tilesPerDirectory] files.
  int get directoryBucket => (npix ~/ tilesPerDirectory) * tilesPerDirectory;

  /// Builds the relative tile path under a survey base URL, e.g.
  /// `Norder3/Dir0/Npix42.jpg`.
  ///
  /// [format] selects the file extension via [HipsTileFormat.fileExtension].
  String relativePath(HipsTileFormat format) =>
      'Norder$norder/Dir$directoryBucket/Npix$npix.${format.fileExtension}';

  /// Joins [baseUrl] with [relativePath] to form the absolute tile URL.
  ///
  /// A single trailing slash on [baseUrl] is tolerated and normalised so the
  /// result never contains a doubled or missing separator.
  String tileUrl(String baseUrl, HipsTileFormat format) {
    final normalizedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$normalizedBase/${relativePath(format)}';
  }

  /// Builds the relative path of the whole-sky thumbnail for [order] under a
  /// survey base URL, e.g. `Norder3/Allsky.jpg`.
  ///
  /// The Allsky map is a single small image containing every tile at [order];
  /// it is the coarsest, instantly-available level-of-detail used so the
  /// framing background is never blank while higher-order tiles stream in.
  static String allskyRelativePath(int order, HipsTileFormat format) {
    if (order < 0 || order > 29) {
      throw ArgumentError.value(order, 'order', 'out of HiPS range [0, 29]');
    }
    return 'Norder$order/Allsky.${format.fileExtension}';
  }

  /// Joins [baseUrl] with [allskyRelativePath] to form the absolute Allsky URL.
  static String allskyUrl(String baseUrl, int order, HipsTileFormat format) {
    final normalizedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$normalizedBase/${allskyRelativePath(order, format)}';
  }

  @override
  List<Object?> get props => [survey, norder, npix];

  @override
  String toString() => 'HipsTileId($survey, Norder$norder, Npix$npix)';
}
