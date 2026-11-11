import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as path;

/// Compile-time default base URL for the immutable GitHub release that hosts
/// the bulk catalogs as integrity-verified assets. This is the PRIMARY source:
/// third-party upstreams (Codeberg, raw.githubusercontent) are only used as a
/// fallback when a release asset is unreachable.
///
/// Repointable by a self-hoster at build time via
/// `--dart-define=SKOTIQ_CATALOG_BASE_URL=<url>` or at runtime through the
/// persisted override the catalog manager reads.
const String kCatalogReleaseBaseUrl = String.fromEnvironment(
  'SKOTIQ_CATALOG_BASE_URL',
  defaultValue:
      'https://github.com/Scdouglas1999/Skotiq/releases/download/catalogs-v1',
);

/// The catalogs Skotiq installs as files, and everything that is fixed about
/// each: its wire name (the enum name), where it downloads from, what it is
/// called on disk and how its download is verified.
///
/// Downloads are resolved through an ordered candidate list
/// ([downloadCandidates]): the GitHub release asset first, then the upstream
/// host. Each candidate's as-downloaded bytes are checked against [sha256]
/// before any decompression or parse.
enum SkyCatalog {
  /// HYG star database.
  ///
  /// Upstream fallback is the Codeberg Git-LFS `/media/` content URL. It must
  /// be `/media/`, not `/raw/`, which returns a 133-byte LFS pointer.
  stars(
    displayName: 'HYG Star Database',
    description:
        'Combined Hipparcos, Yale Bright Star, and Gliese catalogs with ~120,000 stars',
    version: '4.4',
    fileName: 'hyg_v44.csv',
    // Installs made before the v44 rename still hold hyg_v42.csv.
    legacyFileNames: ['hyg_v42.csv'],
    githubAssetName: 'hyg_v44.csv.gz',
    sha256: '00b349893b9a53106dd488d8371e8d2fa586043e500bb3cdb8bff3931682197d',
    upstreamUrl:
        'https://codeberg.org/astronexus/hyg/media/branch/main/data/hyg/CURRENT/hyg_v44.csv.gz',
    approximateSizeBytes: 35 * 1024 * 1024,
    requiredForPlateSolve: true,
  ),

  /// OpenNGC deep-sky objects.
  dso(
    displayName: 'OpenNGC Deep Sky Objects',
    description:
        'Open source NGC/IC deep sky objects catalog with ~13,000 objects',
    version: '2023.12',
    fileName: 'NGC.csv',
    githubAssetName: 'NGC.csv',
    sha256: '840fe0c9ee1332e551b2e722a0e92726cd7b157914a3d2177602832aadd3aa9e',
    upstreamUrl:
        'https://raw.githubusercontent.com/mattiaverga/OpenNGC/master/database_files/NGC.csv',
    approximateSizeBytes: 5 * 1024 * 1024,
  ),

  /// GLADE+ galaxies for deep annotation, queried from VizieR TAP
  /// (VII/291/gladep). No release asset and no canonical hash: the payload is
  /// built per [AnnotationPackage] by [gladePlusUrl].
  annotation(
    displayName: 'GLADE+ Galaxy Catalog',
    description: 'Galaxy List for the Advanced Detector Era - 22.5M galaxies',
    version: '2022',
    fileName: 'glade_plus_galaxies.csv',
    approximateSizeBytes: 50 * 1024 * 1024,
  );

  const SkyCatalog({
    required this.displayName,
    required this.description,
    required this.version,
    required this.fileName,
    required this.approximateSizeBytes,
    this.legacyFileNames = const [],
    this.githubAssetName = '',
    this.sha256 = '',
    this.upstreamUrl = '',
    this.requiredForPlateSolve = false,
  });

  final String displayName;
  final String description;
  final String version;

  /// File name under the catalog directory. For a gzipped download this is
  /// the decompressed file.
  final String fileName;

  /// Superseded file names an older install may still hold, newest first.
  /// Status, load and uninstall accept these so an upgrade does not orphan a
  /// catalog the user already downloaded.
  final List<String> legacyFileNames;

  /// Release asset under the catalog base URL; empty when there is none.
  final String githubAssetName;

  /// SHA-256 of the as-downloaded bytes (the compressed payload for a `.gz`
  /// asset). Empty when no canonical hash is known; the check is then skipped.
  final String sha256;

  /// Upstream fallback URL; empty for [annotation], whose URL depends on the
  /// selected [AnnotationPackage].
  final String upstreamUrl;

  /// Size estimate shown before a download.
  final int approximateSizeBytes;

  final bool requiredForPlateSolve;

  String get metadataFileName => '${name}_metadata.json';

  /// The catalog a wire or metadata name refers to, or null.
  static SkyCatalog? tryParse(String? name) {
    for (final catalog in values) {
      if (catalog.name == name) return catalog;
    }
    return null;
  }

  static String get wireNames => values.map((c) => c.name).join(', ');

  /// Every file name that counts as this catalog on disk, current name first.
  List<String> get candidateFileNames => [fileName, ...legacyFileNames];

  /// The file name to read under [directory]: [fileName] when it is present
  /// with content, otherwise the first legacy name that is, otherwise
  /// [fileName] so callers still get the canonical (missing) path.
  String resolveInstalledName(String directory) {
    for (final candidate in candidateFileNames) {
      final file = File(path.join(directory, candidate));
      if (file.existsSync() && file.lengthSync() > 0) return candidate;
    }
    return fileName;
  }

  /// URLs to try in order: the release asset under [baseUrl], then the
  /// upstream host. Empty entries and duplicates are dropped, so [annotation]
  /// collapses to its TAP query for [tier].
  List<String> downloadCandidates({
    required String baseUrl,
    AnnotationPackage tier = AnnotationPackage.standard,
  }) {
    final candidates = <String>[];
    final base = baseUrl.trim();
    if (githubAssetName.isNotEmpty && base.isNotEmpty) {
      final normalized = base.endsWith('/')
          ? base.substring(0, base.length - 1)
          : base;
      candidates.add('$normalized/$githubAssetName');
    }
    final upstream = this == annotation ? gladePlusUrl(tier) : upstreamUrl;
    if (upstream.isNotEmpty && !candidates.contains(upstream)) {
      candidates.add(upstream);
    }
    return candidates;
  }
}

/// Whether [actualSha256] satisfies [expectedSha256] (case-insensitive). An
/// empty expectation means no canonical hash is known and always matches.
bool catalogSha256Matches(String expectedSha256, String actualSha256) {
  final expected = expectedSha256.trim();
  if (expected.isEmpty) return true;
  return actualSha256.toLowerCase() == expected.toLowerCase();
}

/// Whether [bytes] satisfy [expectedSha256]; see [catalogSha256Matches].
bool catalogBytesMatchSha256(String expectedSha256, List<int> bytes) {
  final expected = expectedSha256.trim();
  if (expected.isEmpty) return true;
  return catalogSha256Matches(
    expected,
    crypto.sha256.convert(bytes).toString(),
  );
}

/// How deep a GLADE+ install goes. A real choice: each tier is a different
/// VizieR query and a different file.
enum AnnotationPackage {
  /// B ≤ 14, about 50,000 galaxies.
  essential(
    'Essential',
    'Bright galaxies (B ≤ 14) for basic annotation',
    5,
    14.0,
  ),

  /// B ≤ 17, about 500,000 galaxies.
  standard(
    'Standard',
    'Recommended for most astrophotographers (B ≤ 17)',
    50,
    17.0,
  ),

  /// All 22.5 million galaxies.
  complete('Complete', 'Full GLADE+ catalog - 22.5M galaxies', 2000, 99.0);

  final String displayName;
  final String description;
  final int approximateSizeMB;
  final double magnitudeLimit;

  const AnnotationPackage(
    this.displayName,
    this.description,
    this.approximateSizeMB,
    this.magnitudeLimit,
  );

  static AnnotationPackage? tryParse(Object? name) {
    for (final tier in values) {
      if (tier.name == name) return tier;
    }
    return null;
  }
}

/// VizieR TAP query for GLADE+ at [tier].
String gladePlusUrl(AnnotationPackage tier) {
  // VizieR requires double quotes around column names. Bmag is NULL for many
  // rows, so the filtered tiers also require a value.
  const columns =
      'SELECT "RAJ2000", "DEJ2000", "Bmag", "zhelio", "PGC" FROM "VII/291/gladep"';
  final query = tier == AnnotationPackage.complete
      ? columns
      : '$columns WHERE "Bmag" IS NOT NULL AND "Bmag" <= ${tier.magnitudeLimit}';
  return 'https://tapvizier.cds.unistra.fr/TAPVizieR/tap/sync'
      '?REQUEST=doQuery&LANG=ADQL&FORMAT=csv&QUERY=${Uri.encodeComponent(query)}';
}

/// What a star and deep-sky install delivers. Every figure describes the
/// assets [SkyCatalog.downloadCandidates] resolves to, so a surface quoting
/// them cannot drift from the bytes on disk. Once a catalog is installed the
/// settings card prints the measured size and count; these are the
/// pre-download estimates.
const String kInstalledCatalogDescription =
    'HYG star database and the OpenNGC deep-sky catalog';

/// Approximate on-disk size of both catalogs together, in megabytes.
const int kInstalledCatalogApproxSizeMB = 60;

/// Roughly how many HYG stars an install delivers (the shipped file has
/// 119,614 rows).
const int kInstalledStarApproxCount = 120000;

/// Roughly how many OpenNGC deep-sky objects an install delivers.
const int kInstalledDsoApproxCount = 13000;

/// `9000` -> `9,000`. The counts are round approximations, so no
/// locale-specific formatting is warranted.
String formatCatalogCount(int count) {
  final digits = count.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
