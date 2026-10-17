part of '../catalog_manager.dart';

// For gzip decompression

/// Wrap a catalog response body so a dead connection cannot hang the app.
///
/// Two failures a bare `await for` over the body cannot see:
///
/// * A stalled connection delivers no event, so there is no chunk to notice it
///   on. [idleTimeout] bounds the gap between chunks and raises
///   [CatalogDownloadStalled] when it is exceeded.
/// * A cancellation token read only inside the chunk handler is never reached
///   on a stalled transfer, which makes Cancel inert. [cancelPollInterval]
///   drives an independent poll.
///
/// Both terminate the transfer by erroring the returned stream, which unwinds
/// the caller's existing candidate/cleanup handling unchanged.
Stream<List<int>> _guardCatalogTransfer(
  Stream<List<int>> body, {
  required Duration idleTimeout,
  required Duration cancelPollInterval,
  Future<bool> Function()? isCancelled,
}) {
  final bounded = body.timeout(
    idleTimeout,
    onTimeout: (sink) {
      sink.addError(CatalogDownloadStalled(idleTimeout));
      sink.close();
    },
  );
  if (isCancelled == null) return bounded;

  final controller = StreamController<List<int>>();
  StreamSubscription<List<int>>? subscription;
  Timer? poll;
  var settled = false;
  var polling = false;

  void settle() {
    settled = true;
    poll?.cancel();
    poll = null;
  }

  controller.onListen = () {
    subscription = bounded.listen(
      controller.add,
      onError: (Object error, StackTrace stack) {
        settle();
        controller.addError(error, stack);
        controller.close();
      },
      onDone: () {
        settle();
        controller.close();
      },
    );
    poll = Timer.periodic(cancelPollInterval, (_) async {
      if (settled || polling) return;
      polling = true;
      try {
        final cancelled = await isCancelled();
        if (settled || !cancelled) return;
        settle();
        await subscription?.cancel();
        controller.addError(const CatalogCancelled());
        await controller.close();
      } catch (error, stack) {
        // A token that throws must fail the download, not become an
        // unhandled error in a timer nobody is awaiting.
        if (settled) return;
        settle();
        await subscription?.cancel();
        controller.addError(error, stack);
        await controller.close();
      } finally {
        polling = false;
      }
    });
  };
  controller.onPause = () => subscription?.pause();
  controller.onResume = () => subscription?.resume();
  controller.onCancel = () async {
    settle();
    await subscription?.cancel();
  };
  return controller.stream;
}

/// Open a catalog request under a bound.
///
/// `Client.send` has no timeout of its own, so a host that accepts the socket
/// and never returns response headers left the download awaiting forever —
/// before any stream existed for [_guardCatalogTransfer] to watch. The caller's
/// `finally { client.close(); }` aborts the abandoned request.
Future<http.StreamedResponse> _sendCatalogRequest(
  http.Client client,
  http.BaseRequest request,
) {
  final timeout = CatalogManager.connectTimeout;
  return client
      .send(request)
      .timeout(
        timeout,
        onTimeout: () => throw CatalogDownloadStalled(
          timeout,
          waitingFor: 'response headers',
        ),
      );
}

String _normalizeCatalogSearchText(String value) {
  final compact = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  return compact.replaceFirstMapped(
    RegExp(r'^(m|ngc|ic|hip|hd|hyg)0*(\d+)$'),
    (match) => '${match.group(1)}${int.parse(match.group(2)!)}',
  );
}

bool _catalogTextMatches(
  String value,
  String rawQuery,
  String normalizedQuery,
) {
  final rawValue = value.toLowerCase();
  if (rawValue.contains(rawQuery)) return true;
  final normalizedValue = _normalizeCatalogSearchText(value);
  return normalizedQuery.isNotEmpty &&
      (normalizedValue.contains(normalizedQuery) ||
          normalizedQuery.contains(normalizedValue));
}

bool _catalogTextEquals(String value, String rawQuery, String normalizedQuery) {
  return value.toLowerCase() == rawQuery ||
      _normalizeCatalogSearchText(value) == normalizedQuery;
}

/// What a catalog install actually delivers — the one dataset that exists.
///
/// Every figure here describes the assets [catalogDownloadCandidates] resolves
/// to, so a surface quoting them cannot drift from the bytes on disk.
const String kInstalledCatalogDescription =
    'HYG star database and the OpenNGC deep-sky catalog';

/// Approximate on-disk size of both catalogs together, in megabytes. Once a
/// catalog is installed the settings card prints the MEASURED size; this is
/// only the pre-download estimate.
const int kInstalledCatalogApproxSizeMB = 60;

/// Roughly how many HYG stars an install delivers. The shipped file counts
/// 119,614 rows; rounded because it is an estimate shown before download.
const int kInstalledStarApproxCount = 120000;

/// Roughly how many OpenNGC deep-sky objects an install delivers.
const int kInstalledDsoApproxCount = 13000;

/// Faintest magnitude the OpenNGC data carries a value for.
///
/// OpenNGC is a compilation rather than a magnitude-limited survey, so this is
/// an inclusion bound, not a completeness claim — which is why the settings
/// card no longer prints a DSO "Depth" chip at all.
const double kInstalledDsoDepthMag = 20.0;

/// LEGACY metadata label for an installed catalog. **Not a choice.**
///
/// This was a three-way size/detail selector — Essential (~10 MB, ~9,000
/// stars, mag ≤ 6.5), Standard (~30 MB, ~40,000 stars, mag ≤ 8.0), Complete
/// (~60 MB, ~120,000 stars). None of it was real. There is one HYG asset and
/// one OpenNGC asset behind [catalogDownloadCandidates], and `_downloadCatalog`
/// fetches them regardless of the selected package: downloading Essential and
/// then Standard into an empty catalog directory produced BYTE-IDENTICAL files
/// — same SHA-256, 119,614 stars either way — and the settings card then
/// printed a different "Depth" for the same bytes. Nothing consumed
/// [starMagnitudeLimit] as a FILTER either; the render path takes its magnitude
/// limit from the view settings.
///
/// The tier selector is gone from both download surfaces. The enum survives
/// only so `stars_metadata.json` / `dso_metadata.json` written by an older
/// build still parses — and every variant now reports the SAME figures, because
/// the installed bytes are the same whichever name is on the sidecar.
/// Fabricating three depths for one file is the defect this replaces; do not
/// re-introduce per-variant numbers without per-variant data behind them.
enum CatalogPackage {
  /// Legacy label. Describes the single available dataset.
  essential(
    'Essential',
    kInstalledCatalogDescription,
    kInstalledCatalogApproxSizeMB,
    kHygFaintFloorMag,
    kInstalledDsoDepthMag,
    kInstalledStarApproxCount,
    kInstalledDsoApproxCount,
  ),

  /// Legacy label. Describes the single available dataset.
  standard(
    'Standard',
    kInstalledCatalogDescription,
    kInstalledCatalogApproxSizeMB,
    kHygFaintFloorMag,
    kInstalledDsoDepthMag,
    kInstalledStarApproxCount,
    kInstalledDsoApproxCount,
  ),

  /// The name written for every new install: the full HYG + OpenNGC data.
  complete(
    'Complete',
    kInstalledCatalogDescription,
    kInstalledCatalogApproxSizeMB,
    kHygFaintFloorMag,
    kInstalledDsoDepthMag,
    kInstalledStarApproxCount,
    kInstalledDsoApproxCount,
  );

  final String displayName;
  final String description;
  final int approximateSizeMB;

  /// Magnitude to which the installed star catalog is COMPLETE.
  ///
  /// [kHygFaintFloorMag] for every variant, because one file is installed.
  /// This read 15.0 for [complete] — the HYG loader's inclusion filter, not its
  /// depth — and 6.5 / 8.0 for the other two, which were invented outright.
  final double starMagnitudeLimit;

  /// Faintest magnitude the installed OpenNGC data carries. An inclusion
  /// bound, not a completeness claim — see [kInstalledDsoDepthMag].
  final double dsoMagnitudeLimit;

  /// Roughly how many HYG stars an install delivers. Identical across the
  /// variants, because the download is identical.
  final int approximateStarCount;

  /// Roughly how many OpenNGC deep-sky objects an install delivers. Same
  /// reason as [approximateStarCount].
  final int approximateDsoCount;

  const CatalogPackage(
    this.displayName,
    this.description,
    this.approximateSizeMB,
    this.starMagnitudeLimit,
    this.dsoMagnitudeLimit,
    this.approximateStarCount,
    this.approximateDsoCount,
  );
}

/// `9000` -> `9,000`. Thousands separators only; the counts are round
/// approximations, so no locale-specific formatting is warranted.
String formatCatalogCount(int count) {
  final digits = count.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Compile-time default base URL for the immutable GitHub release that hosts
/// the bulk catalogs as integrity-verified assets. This is the PRIMARY source:
/// third-party upstreams (Codeberg, raw.githubusercontent) are only used as a
/// fallback when a release asset is unreachable.
///
/// Repointable by a self-hoster at build time via
/// `--dart-define=SKOTIQ_CATALOG_BASE_URL=<url>` or at runtime via
/// [CatalogManager.setCatalogBaseUrl] (persisted).
///
/// A release asset's full URL is `<base>/<CatalogSource.githubAssetName>`.
const String kCatalogReleaseBaseUrl = String.fromEnvironment(
  'SKOTIQ_CATALOG_BASE_URL',
  defaultValue:
      'https://github.com/Scdouglas1999/Skotiq/releases/download/catalogs-v1',
);

/// Catalog source information.
///
/// Downloads are resolved through an ordered candidate list (see
/// [catalogDownloadCandidates]): the GitHub release asset ([githubAssetName]
/// under [kCatalogReleaseBaseUrl] or a configured override) is tried FIRST,
/// then [downloadUrl] as the upstream fallback. Each candidate's AS-DOWNLOADED
/// bytes are checked against [sha256] before any decompression or parse.
class CatalogSource {
  final String name;
  final String description;
  final String version;

  /// Upstream FALLBACK download URL (the original third-party host). Used only
  /// when the GitHub release asset is unreachable. For gzipped sources this
  /// points at the compressed `.gz` file.
  final String downloadUrl;

  /// Local (materialized) file name under the catalog directory. For gzipped
  /// sources this is the DECOMPRESSED file, not the downloaded `.gz`.
  final String fileName;

  /// Superseded file names this catalog may already be materialized under,
  /// newest first.
  ///
  /// An install made before a rename still has the old file on disk. Status,
  /// load and delete all accept these so an upgrade does not orphan a catalog
  /// the user already downloaded (see [CatalogSource.resolveInstalledName]).
  final List<String> legacyFileNames;

  final String checksumUrl;

  /// File name of the immutable GitHub release asset that is the PRIMARY
  /// download source. The full primary URL is `<base>/<githubAssetName>` where
  /// `<base>` is the configured override or [kCatalogReleaseBaseUrl]. Empty
  /// when no release asset exists (e.g. the dynamically-built GLADE+ query).
  final String githubAssetName;

  /// Expected SHA-256 of the AS-DOWNLOADED bytes — the COMPRESSED payload for
  /// gzipped sources — verified before any gunzip/parse so a corrupt or wrong
  /// candidate is rejected and the next candidate is tried. Empty means no
  /// canonical hash is known (e.g. GLADE+) and the check is skipped.
  final String sha256;

  /// Whether the as-downloaded payload is gzip-compressed.
  final bool isGzipped;

  const CatalogSource({
    required this.name,
    required this.description,
    required this.version,
    required this.downloadUrl,
    required this.fileName,
    this.legacyFileNames = const [],
    this.checksumUrl = '',
    this.githubAssetName = '',
    this.sha256 = '',
    this.isGzipped = false,
  });

  /// Every file name that counts as this catalog on disk: the current one
  /// first, then the legacy names in order.
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
}

/// HYG Star Database source.
///
/// PRIMARY: the immutable `hyg_v44.csv.gz` GitHub release asset.
/// FALLBACK: Codeberg Git-LFS `/media/` content URL (v44). NOTE: this MUST be
/// the `/media/` URL, not `/raw/` (which returns a 133-byte LFS pointer). The
/// old v42 `/raw`/`/media` URL is dead (upstream rolled to v44) and is gone.
const hygStarCatalog = CatalogSource(
  name: 'HYG Star Database',
  description:
      'Combined Hipparcos, Yale Bright Star, and Gliese catalogs with ~120,000 stars',
  version: '4.4',
  githubAssetName: 'hyg_v44.csv.gz',
  // SHA-256 of the AS-DOWNLOADED (gzipped) bytes.
  sha256: '00b349893b9a53106dd488d8371e8d2fa586043e500bb3cdb8bff3931682197d',
  // Upstream fallback: /media/ LFS-content URL for v44 on Codeberg.
  downloadUrl:
      'https://codeberg.org/astronexus/hyg/media/branch/main/data/hyg/CURRENT/hyg_v44.csv.gz',
  fileName: 'hyg_v44.csv',
  // Installs made before the v44 rename still hold hyg_v42.csv.
  legacyFileNames: ['hyg_v42.csv'],
  isGzipped: true,
);

/// OpenNGC Deep Sky Object catalog source.
///
/// PRIMARY: the immutable `NGC.csv` GitHub release asset.
/// FALLBACK: mattiaverga/OpenNGC `master` on raw.githubusercontent.com.
const openNgcCatalog = CatalogSource(
  name: 'OpenNGC',
  description:
      'Open source NGC/IC deep sky objects catalog with ~13,000 objects',
  version: '2023.12',
  githubAssetName: 'NGC.csv',
  sha256: '840fe0c9ee1332e551b2e722a0e92726cd7b157914a3d2177602832aadd3aa9e',
  downloadUrl:
      'https://raw.githubusercontent.com/mattiaverga/OpenNGC/master/database_files/NGC.csv',
  fileName: 'NGC.csv',
  isGzipped: false,
);

/// Ordered list of URLs to try when downloading a catalog: the GitHub release
/// asset FIRST (built from [baseUrl] + [githubAssetName]), then the upstream
/// [upstreamUrl] fallback. [baseUrl] is the resolved release base (a persisted
/// override, or [kCatalogReleaseBaseUrl]).
///
/// Empty entries and duplicates are dropped, so a source with no release asset
/// (e.g. the dynamically-built GLADE+ query) collapses to just its upstream.
List<String> catalogDownloadCandidates({
  required String githubAssetName,
  required String upstreamUrl,
  required String baseUrl,
}) {
  final candidates = <String>[];
  final base = baseUrl.trim();
  final asset = githubAssetName.trim();
  if (asset.isNotEmpty && base.isNotEmpty) {
    final normalized = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    candidates.add('$normalized/$asset');
  }
  final upstream = upstreamUrl.trim();
  if (upstream.isNotEmpty && !candidates.contains(upstream)) {
    candidates.add(upstream);
  }
  return candidates;
}

/// [catalogDownloadCandidates] for a [CatalogSource].
List<String> resolveCatalogDownloadCandidates(
  CatalogSource source, {
  required String baseUrl,
}) => catalogDownloadCandidates(
  githubAssetName: source.githubAssetName,
  upstreamUrl: source.downloadUrl,
  baseUrl: baseUrl,
);

/// Whether [actualSha256] satisfies a catalog's [expectedSha256]
/// (case-insensitive). An empty [expectedSha256] means "no canonical hash
/// known" (e.g. GLADE+) and always matches.
bool catalogSha256Matches(String expectedSha256, String actualSha256) {
  final expected = expectedSha256.trim();
  if (expected.isEmpty) return true;
  return actualSha256.toLowerCase() == expected.toLowerCase();
}

/// Whether [bytes] (the AS-DOWNLOADED payload) satisfy a catalog's
/// [expectedSha256]. Used by the download path to reject a candidate whose
/// bytes don't match BEFORE any decompression/parse.
bool catalogBytesMatchSha256(String expectedSha256, List<int> bytes) {
  final expected = expectedSha256.trim();
  if (expected.isEmpty) return true;
  return catalogSha256Matches(expected, sha256.convert(bytes).toString());
}

/// Available annotation catalog packages for deep image annotation
/// Uses GLADE+ (Galaxy List for the Advanced Detector Era) via VizieR TAP
enum AnnotationPackage {
  /// Essential package: ~5MB
  /// - Galaxies: B-magnitude ≤ 14 (~50,000 galaxies)
  /// - Good for bright object annotation
  essential(
    'Essential',
    'Bright galaxies (B ≤ 14) for basic annotation',
    5,
    14.0,
  ),

  /// Standard package: ~50MB
  /// - Galaxies: B-magnitude ≤ 17 (~500,000 galaxies)
  /// - Recommended for most astrophotographers
  standard(
    'Standard',
    'Recommended for most astrophotographers (B ≤ 17)',
    50,
    17.0,
  ),

  /// Complete package: ~2GB
  /// - All 22.5M galaxies in GLADE+
  /// - Full deep annotation capability
  complete(
    'Complete',
    'Full GLADE+ catalog - 22.5M galaxies',
    2000,
    99.0, // No magnitude limit
  );

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
}

/// GLADE+ Galaxy Database source
/// Source: https://glade.elte.hu/ via VizieR TAP (VII/291/gladep)
/// Galaxy List for the Advanced Detector Era - 22.5 million galaxies
const gladePlusCatalog = CatalogSource(
  name: 'GLADE+ Galaxy Catalog',
  description: 'Galaxy List for the Advanced Detector Era - 22.5M galaxies',
  version: '2022',
  // URL is constructed dynamically based on selected tier via VizieR TAP
  downloadUrl: '', // Built dynamically using _buildGladePlusUrl()
  fileName: 'glade_plus_galaxies.csv',
);

/// Whether automatic download is available for annotation catalog
/// GLADE+ is always available via VizieR TAP
bool get isAnnotationDownloadAvailable => true;

/// Build VizieR TAP URL for GLADE+ catalog with magnitude filtering
String buildGladePlusUrl(AnnotationPackage package) {
  String query;
  if (package == AnnotationPackage.complete) {
    // Full catalog - no magnitude filter
    // Note: VizieR requires double quotes around column names
    query =
        'SELECT "RAJ2000", "DEJ2000", "Bmag", "zhelio", "PGC" FROM "VII/291/gladep"';
  } else {
    // Filtered by B-magnitude
    // Note: Bmag can be NULL for many entries, so we filter for non-null values
    query =
        'SELECT "RAJ2000", "DEJ2000", "Bmag", "zhelio", "PGC" FROM "VII/291/gladep" '
        'WHERE "Bmag" IS NOT NULL AND "Bmag" <= ${package.magnitudeLimit}';
  }
  return 'https://tapvizier.cds.unistra.fr/TAPVizieR/tap/sync'
      '?REQUEST=doQuery&LANG=ADQL&FORMAT=csv&QUERY=${Uri.encodeComponent(query)}';
}

/// Catalog installation status
class CatalogStatus {
  final bool isInstalled;
  final String? installedPath;
  final DateTime? installedDate;
  final CatalogPackage? installedPackage;
  final int? objectCount;
  final String? version;

  /// Size of the installed catalog file on disk, in bytes. Null when not
  /// installed or unknown.
  final int? fileSizeBytes;

  const CatalogStatus({
    required this.isInstalled,
    this.installedPath,
    this.installedDate,
    this.installedPackage,
    this.objectCount,
    this.version,
    this.fileSizeBytes,
  });

  factory CatalogStatus.notInstalled() =>
      const CatalogStatus(isInstalled: false);
}

/// Download progress information
class DownloadProgress {
  final String catalogName;

  /// Stable identity of the catalog being downloaded (`stars`, `dso`,
  /// `annotation`). Lets a UI attribute progress to a specific card and lets
  /// [CatalogManager.activeDownloads] key in-flight downloads, where
  /// [catalogName] is only a human-facing label.
  final String? catalogKey;
  final double progress; // 0.0 to 1.0
  final int bytesReceived;
  final int totalBytes;
  final String status;
  final bool isComplete;

  /// True when the download was deliberately cancelled by the user (as opposed
  /// to failing). Terminal, but not an error — the UI should treat it quietly.
  final bool cancelled;
  final String? error;

  const DownloadProgress({
    required this.catalogName,
    this.catalogKey,
    required this.progress,
    required this.bytesReceived,
    required this.totalBytes,
    required this.status,
    this.isComplete = false,
    this.cancelled = false,
    this.error,
  });

  /// Whether this update is a terminal one (success, cancellation, or failure)
  /// — i.e. the download is no longer in flight.
  bool get isTerminal => isComplete || cancelled || error != null;

  factory DownloadProgress.starting(String catalogName, {String? catalogKey}) =>
      DownloadProgress(
        catalogName: catalogName,
        catalogKey: catalogKey,
        progress: 0,
        bytesReceived: 0,
        totalBytes: 0,
        status: 'Starting download...',
      );

  factory DownloadProgress.complete(
    String catalogName,
    int bytes, {
    String? catalogKey,
  }) => DownloadProgress(
    catalogName: catalogName,
    catalogKey: catalogKey,
    progress: 1.0,
    bytesReceived: bytes,
    totalBytes: bytes,
    status: 'Complete',
    isComplete: true,
  );

  factory DownloadProgress.cancelled(
    String catalogName, {
    String? catalogKey,
  }) => DownloadProgress(
    catalogName: catalogName,
    catalogKey: catalogKey,
    progress: 0,
    bytesReceived: 0,
    totalBytes: 0,
    status: 'Cancelled',
    cancelled: true,
  );

  factory DownloadProgress.error(
    String catalogName,
    String error, {
    String? catalogKey,
  }) => DownloadProgress(
    catalogName: catalogName,
    catalogKey: catalogKey,
    progress: 0,
    bytesReceived: 0,
    totalBytes: 0,
    status: 'Error',
    error: error,
  );
}
