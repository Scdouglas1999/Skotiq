part of '../catalog_manager.dart';

/// Manages astronomical catalog downloads, installation, and access
class CatalogManager {
  static CatalogManager? _instance;
  static CatalogManager get instance => _instance ??= CatalogManager._();

  CatalogManager._();

  /// How long to wait for a server to accept the request and return response
  /// headers before abandoning a download candidate.
  ///
  /// Mutable only so tests can shorten it; production never writes it.
  @visibleForTesting
  static Duration connectTimeout = const Duration(seconds: 30);

  /// How long a transfer may go without delivering a byte before it is
  /// declared stalled. See [_guardCatalogTransfer].
  @visibleForTesting
  static Duration streamIdleTimeout = const Duration(seconds: 60);

  /// How often a running download polls its cancellation token, independent of
  /// chunk arrival. See [_guardCatalogTransfer].
  @visibleForTesting
  static Duration cancelPollInterval = const Duration(seconds: 1);

  /// The HTTP client the download paths use. A test seam: production always
  /// gets a real client, and every download path closes what it opens.
  @visibleForTesting
  static http.Client Function() httpClientFactory = http.Client.new;

  String? _catalogDirectory;
  final _downloadController = StreamController<DownloadProgress>.broadcast();

  /// In-flight legacy downloads keyed by catalog key (`stars`, `dso`,
  /// `annotation`). Kept on the singleton so download state outlives any
  /// individual widget: a settings screen can be disposed and recreated while
  /// a download runs, and read [activeDownloads] on rebuild to restore the
  /// live progress bar instead of looking idle.
  final Map<String, DownloadProgress> _activeDownloads = {};

  /// Lifecycle events for the unified catalog API used by the
  /// headless `/api/catalog/...` surface. Distinct from
  /// [downloadProgress] because the headless event stream wants
  /// structured per-name events (`CatalogDownloadStarted`,
  /// `CatalogVerified`, `CatalogUninstalled`, ...) that the legacy
  /// per-progress controller does not emit.
  final _eventController = StreamController<CatalogEvent>.broadcast();

  HygCatalogLoader? _starLoader;
  String? _starLoaderPath;
  OpenNgcCatalogLoader? _dsoLoader;
  String? _dsoLoaderPath;

  /// Stream of download progress updates
  Stream<DownloadProgress> get downloadProgress => _downloadController.stream;

  /// Snapshot of legacy downloads currently in flight, keyed by catalog key
  /// (`stars`, `dso`, `annotation`). A UI subscribing to [downloadProgress]
  /// should seed itself from this on first build so progress survives
  /// navigation away from and back to the catalog screen.
  Map<String, DownloadProgress> get activeDownloads =>
      Map.unmodifiable(_activeDownloads);

  /// Whether a download for [catalogKey] is currently in flight.
  bool isDownloading(String catalogKey) =>
      _activeDownloads.containsKey(catalogKey);

  /// Publish a progress update: update the in-flight registry, fan it out on
  /// [downloadProgress], and invoke the caller's [onProgress] callback. The
  /// single choke point that keeps the registry and the stream in lockstep.
  void _emitProgress(
    DownloadProgress progress,
    void Function(DownloadProgress)? onProgress,
  ) {
    final key = progress.catalogKey;
    if (key != null) {
      if (progress.isTerminal) {
        _activeDownloads.remove(key);
      } else {
        _activeDownloads[key] = progress;
      }
    }
    if (!_downloadController.isClosed) {
      _downloadController.add(progress);
    }
    onProgress?.call(progress);
  }

  /// Stream of structured lifecycle events used by the headless
  /// API. Every catalog install, verify, uninstall, or reload publishes
  /// an event here so `HeadlessApiServer` can fan it out over the WS
  /// event stream.
  Stream<CatalogEvent> get events => _eventController.stream;

  /// Check if catalog manager has been initialized
  bool get isInitialized => _catalogDirectory != null;

  /// Set the catalog storage directory
  Future<void> initialize(String catalogDirectory) async {
    _catalogDirectory = catalogDirectory;
    _invalidateLocalCatalogLoaders();

    // Ensure directory exists
    final dir = Directory(catalogDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    developer.log(
      '[Catalog] initialized with directory: $catalogDirectory',
      name: 'CatalogManager',
      level: 800,
    );

    await _sweepAbandonedPartials(dir);

    // Warm the name-search caches off the critical path so the FIRST
    // `search()` doesn't block for several seconds parsing the multi-MB
    // star/DSO files (B10). Fire-and-forget: a failed pre-warm just means the
    // first real search pays the parse cost, exactly as before.
    unawaited(prewarmSearchCaches());
  }

  /// Suffixes a download writes to before promoting the finished file into
  /// place. `.partial` is what the unified and legacy catalog downloads use;
  /// `.part` is what the deep-star tile fetcher writes, one per tile, inside
  /// the `deep_stars/` subdirectory — which is why the sweep below recurses
  /// rather than listing only the top level.
  static const List<String> _abandonedDownloadSuffixes = ['.partial', '.part'];

  /// Deletes the temp files left in the catalog directory by a download
  /// that never finished, and returns the bytes reclaimed.
  ///
  /// Every download writes to `<name>.partial` and promotes it on success; the
  /// `finally` that removes it only runs if the process lives that long. A
  /// crash, a kill, or a power cut during the multi-hundred-megabyte GLADE+
  /// download therefore strands the whole partial on disk forever: nothing
  /// deletes it, no screen mentions it, and the catalog page happily offers a
  /// fresh download beside it. (Observed: a 407 MiB
  /// `glade_plus_galaxies.csv.partial` six weeks old.) A partial is never
  /// resumable — each attempt truncates the temp file — so it is pure dead
  /// weight and reclaiming it at startup is safe.
  ///
  /// Runs before any download this process starts, so it can never race one.
  Future<int> _sweepAbandonedPartials(Directory dir) async {
    var reclaimed = 0;
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (!_abandonedDownloadSuffixes.any(entity.path.endsWith)) continue;
        try {
          final size = await entity.length();
          await entity.delete();
          reclaimed += size;
          developer.log(
            '[Catalog] removed abandoned download ${entity.path} '
            '(${(size / 1024 / 1024).toStringAsFixed(1)} MB reclaimed)',
            name: 'CatalogManager',
            level: 800,
          );
        } catch (e) {
          // A locked or unreadable leftover is not worth failing startup over.
          developer.log(
            '[Catalog] could not remove ${entity.path}: $e',
            name: 'CatalogManager',
            level: 900,
          );
        }
      }
    } catch (e) {
      developer.log(
        '[Catalog] could not scan for abandoned downloads: $e',
        name: 'CatalogManager',
        level: 900,
      );
    }
    return reclaimed;
  }

  /// Eagerly parse the installed DSO + star catalogs into their in-memory
  /// loader caches so subsequent [search] calls hit warm data.
  ///
  /// Safe to call repeatedly — the loaders memoise their parsed payload, so a
  /// second call is a no-op. Errors are swallowed by design (this is a latency
  /// optimisation, not a correctness path).
  Future<void> prewarmSearchCaches() async {
    if (!isInitialized) return;
    try {
      final dsoStatus = await getDsoCatalogStatus();
      if (dsoStatus.isInstalled && dsoStatus.installedPath != null) {
        await _getDsoLoader(dsoStatus.installedPath!).loadAll();
      }
    } catch (e) {
      developer.log(
        '[Catalog] DSO search pre-warm failed: $e',
        name: 'CatalogManager',
        level: 800,
      );
    }
    try {
      final starStatus = await getStarCatalogStatus();
      if (starStatus.isInstalled && starStatus.installedPath != null) {
        await _getStarLoader(starStatus.installedPath!).loadAll();
      }
    } catch (e) {
      developer.log(
        '[Catalog] star search pre-warm failed: $e',
        name: 'CatalogManager',
        level: 800,
      );
    }
  }

  /// Get the catalog directory path
  String get catalogDirectory {
    if (_catalogDirectory == null) {
      throw StateError(
        'CatalogManager not initialized. Call initialize() first.',
      );
    }
    return _catalogDirectory!;
  }

  /// Check if star catalog is installed
  Future<CatalogStatus> getStarCatalogStatus() async {
    if (!isInitialized) return CatalogStatus.notInstalled();
    return _getCatalogStatus(
      hygStarCatalog.resolveInstalledName(catalogDirectory),
      'stars',
    );
  }

  /// Check if DSO catalog is installed
  Future<CatalogStatus> getDsoCatalogStatus() async {
    if (!isInitialized) return CatalogStatus.notInstalled();
    return _getCatalogStatus(
      openNgcCatalog.resolveInstalledName(catalogDirectory),
      'dso',
    );
  }

  Future<CatalogStatus> _getCatalogStatus(String fileName, String type) async {
    final filePath = path.join(catalogDirectory, fileName);
    final file = File(filePath);

    if (!await file.exists()) {
      return CatalogStatus.notInstalled();
    }

    // A zero-byte file is the fingerprint of an interrupted or failed
    // download (a half-written catalog), not a usable install. Report it as
    // not installed so the UI offers a re-download instead of a broken
    // "Installed" badge.
    final fileSize = await file.length();
    if (fileSize == 0) {
      return CatalogStatus.notInstalled();
    }

    // Read metadata file if it exists
    final metaPath = path.join(catalogDirectory, '${type}_metadata.json');
    final metaFile = File(metaPath);

    CatalogPackage? package;
    String? version;
    int? objectCount;
    DateTime? installedDate;

    if (await metaFile.exists()) {
      try {
        final metaJson = jsonDecode(await metaFile.readAsString());
        package = CatalogPackage.values.firstWhere(
          (p) => p.name == metaJson['package'],
          orElse: () => CatalogPackage.complete,
        );
        version = metaJson['version'];
        objectCount = metaJson['objectCount'];
        installedDate = DateTime.tryParse(metaJson['installedDate'] ?? '');
      } catch (e) {
        // Metadata corrupted or malformed - report as installed with defaults
        developer.log(
          '[Catalog]: Failed to parse metadata: $e',
          name: 'CatalogManager',
          level: 900,
        );
      }
    }

    return CatalogStatus(
      isInstalled: true,
      installedPath: filePath,
      installedDate: installedDate,
      installedPackage: package,
      objectCount: objectCount,
      version: version,
      fileSizeBytes: fileSize,
    );
  }

  /// Get the file path for the star catalog
  String get starCatalogPath => path.join(
    catalogDirectory,
    hygStarCatalog.resolveInstalledName(catalogDirectory),
  );

  /// Get the file path for the DSO catalog
  String get dsoCatalogPath => path.join(
    catalogDirectory,
    openNgcCatalog.resolveInstalledName(catalogDirectory),
  );

  /// Get the file path for the annotation catalog (GLADE+)
  String get annotationCatalogPath =>
      path.join(catalogDirectory, gladePlusCatalog.fileName);

  /// Dispose resources
  void dispose() {
    _downloadController.close();
    _eventController.close();
  }

  // Unified catalog API for the headless `/api/catalog/...` surface.
  //
  // The legacy per-type methods (`downloadStarCatalog`, `downloadDsoCatalog`,
  // `downloadAnnotationCatalog`) continue to power the desktop
  // `CatalogSettingsScreen`. The methods below are a thin coordinator on top
  // that exposes a single "name → result" surface so a REST client can talk
  // about "the catalog named `stars`" without caring about the underlying
  // source/file shape.

  /// Canonical list of catalogs the headless API knows how to manage.
  /// Keyed by the catalog `name` exposed on the wire (`stars`, `dso`,
  /// `annotation`).
  ///
  /// Derived from the [CatalogSource] constants ([hygStarCatalog],
  /// [openNgcCatalog], [gladePlusCatalog]) so the two catalog subsystems share
  /// one source of truth for download URLs, asset names, hashes and file names,
  /// and the `CatalogSettingsScreen` and the headless `/api/catalog` surface
  /// cannot drift.
  static final Map<String, CatalogDescriptor> knownCatalogs = {
    'stars': _descriptorFrom(
      source: hygStarCatalog,
      wireName: 'stars',
      metadataFileName: 'stars_metadata.json',
      approximateSizeBytes: 35 * 1024 * 1024,
      // Plate solving needs a star catalog; this is the minimum.
      requiredForPlateSolve: true,
    ),
    'dso': _descriptorFrom(
      source: openNgcCatalog,
      wireName: 'dso',
      displayNameOverride: 'OpenNGC Deep Sky Objects',
      metadataFileName: 'dso_metadata.json',
      approximateSizeBytes: 5 * 1024 * 1024,
      requiredForPlateSolve: false,
    ),
    'annotation': _descriptorFrom(
      source: gladePlusCatalog,
      wireName: 'annotation',
      metadataFileName: 'annotation_metadata.json',
      // GLADE+ standard tier ≈ 50 MB; complete is ~2 GB.
      approximateSizeBytes: 50 * 1024 * 1024,
      requiredForPlateSolve: false,
    ),
  };

  /// Build a [CatalogDescriptor] from a legacy [CatalogSource] so both
  /// subsystems share one definition of each catalog's URLs / hash / files.
  static CatalogDescriptor _descriptorFrom({
    required CatalogSource source,
    required String wireName,
    required String metadataFileName,
    required int approximateSizeBytes,
    required bool requiredForPlateSolve,
    String? displayNameOverride,
  }) => CatalogDescriptor(
    name: wireName,
    displayName: displayNameOverride ?? source.name,
    description: source.description,
    fileName: source.fileName,
    legacyFileNames: source.legacyFileNames,
    metadataFileName: metadataFileName,
    version: source.version,
    approximateSizeBytes: approximateSizeBytes,
    downloadUrl: source.downloadUrl,
    githubAssetName: source.githubAssetName,
    sha256: source.sha256,
    isGzipped: source.isGzipped,
    requiredForPlateSolve: requiredForPlateSolve,
  );

  /// Config file (in the catalog directory) that persists a runtime override
  /// for the catalog release base URL, letting a self-hoster repoint downloads
  /// without a rebuild. Mirrors [DeepStarCatalogManager]'s `config.json`.
  String get _catalogSourceConfigPath =>
      path.join(catalogDirectory, 'catalog_source_config.json');

  /// The resolved base URL for GitHub release catalog assets: a persisted
  /// override when set, otherwise the compile-time [kCatalogReleaseBaseUrl].
  Future<String> getCatalogBaseUrl() async {
    try {
      final file = File(_catalogSourceConfigPath);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final url = decoded['baseUrl'];
          if (url is String && url.trim().isNotEmpty) {
            return url.trim();
          }
        }
      }
    } catch (e) {
      developer.log(
        '[Catalog] catalog base URL config read failed: $e',
        name: 'CatalogManager',
        level: 900,
      );
    }
    return kCatalogReleaseBaseUrl;
  }

  /// Persist a runtime override for the catalog release base URL. An empty
  /// string clears the override (falls back to [kCatalogReleaseBaseUrl]).
  Future<void> setCatalogBaseUrl(String url) async {
    final dir = Directory(catalogDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await File(
      _catalogSourceConfigPath,
    ).writeAsString(jsonEncode({'baseUrl': url.trim()}));
  }

  HygCatalogLoader _getStarLoader(String path) {
    if (_starLoader == null || _starLoaderPath != path) {
      _starLoader = HygCatalogLoader(path);
      _starLoaderPath = path;
    }
    return _starLoader!;
  }

  OpenNgcCatalogLoader _getDsoLoader(String path) {
    if (_dsoLoader == null || _dsoLoaderPath != path) {
      _dsoLoader = OpenNgcCatalogLoader(path);
      _dsoLoaderPath = path;
    }
    return _dsoLoader!;
  }

  void _invalidateLocalCatalogLoaders({bool stars = true, bool dsos = true}) {
    if (stars) {
      _starLoader?.clearCache();
      _starLoader = null;
      _starLoaderPath = null;
    }
    if (dsos) {
      _dsoLoader?.clearCache();
      _dsoLoader = null;
      _dsoLoaderPath = null;
    }
  }

  /// Search both star and DSO catalogs.
  Future<List<CatalogSearchResult>> search(String query) =>
      _searchCatalogs(query);

  /// Search for DSOs near a given RA/Dec position.
  Future<List<OpenNgcData>> searchDsoNearby({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
  }) => _searchDsoCatalogNearby(
    ra: ra,
    dec: dec,
    radiusDegrees: radiusDegrees,
    maxMagnitude: maxMagnitude,
  );

  /// Search for stars near a given RA/Dec position.
  Future<List<HygStarData>> searchStarsNearby({
    required double ra,
    required double dec,
    required double radiusDegrees,
    double? maxMagnitude,
  }) => _searchStarCatalogNearby(
    ra: ra,
    dec: dec,
    radiusDegrees: radiusDegrees,
    maxMagnitude: maxMagnitude,
  );

  /// Download and install the star catalog.
  Future<bool> downloadStarCatalog({
    CatalogPackage package = CatalogPackage.standard,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) => _downloadStarCatalog(
    package: package,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  /// Download and install the DSO catalog.
  Future<bool> downloadDsoCatalog({
    CatalogPackage package = CatalogPackage.standard,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) => _downloadDsoCatalog(
    package: package,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  /// Import a star or DSO catalog from a custom location.
  Future<bool> importCatalog({
    required String sourcePath,
    required String type,
  }) => _importCatalog(sourcePath: sourcePath, type: type);

  /// Delete installed star and DSO catalogs.
  Future<void> deleteCatalogs() => _deleteCatalogs();

  /// Check if the annotation catalog is installed.
  Future<CatalogStatus> getAnnotationCatalogStatus() =>
      _getAnnotationCatalogStatus();

  /// Download and install the annotation catalog.
  Future<bool> downloadAnnotationCatalog({
    AnnotationPackage package = AnnotationPackage.standard,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? isCancelled,
  }) => _downloadAnnotationCatalogEntry(
    package: package,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  /// Import the annotation catalog from a local file.
  Future<bool> importAnnotationCatalog({
    required String sourcePath,
    AnnotationPackage package = AnnotationPackage.standard,
  }) => _importAnnotationCatalog(sourcePath: sourcePath, package: package);

  /// Delete the annotation catalog.
  Future<void> deleteAnnotationCatalog() => _deleteAnnotationCatalog();

  /// Get installed annotation package info.
  Future<AnnotationPackage?> getInstalledAnnotationPackage() =>
      _getInstalledAnnotationPackage();

  /// Returns the on-disk state for every known catalog.
  Future<List<InstalledCatalogStatus>> getInstalledStatuses() =>
      _getInstalledCatalogStatuses();

  /// Lists the catalogs available for download.
  Future<List<AvailableCatalog>> listAvailable() => _listAvailableCatalogs();

  /// Download and install a catalog by name.
  Future<CatalogInstallResult> downloadAndInstall(
    String name, {
    String? jobId,
    void Function(int downloaded, int total)? onProgress,
    Future<bool> Function()? isCancelled,
  }) => _downloadAndInstallCatalog(
    name,
    jobId: jobId,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  /// Install a catalog from a pre-staged file on disk.
  Future<CatalogInstallResult> installFromFile({
    required String name,
    required File source,
    String? expectedSha256,
  }) => _installCatalogFromFile(
    name: name,
    source: source,
    expectedSha256: expectedSha256,
  );

  /// Uninstall a catalog by name.
  Future<bool> uninstall(String name) => _uninstallCatalog(name);

  /// Re-load any cached catalog loaders.
  Future<void> reload() => _reloadCatalogs();

  /// Verify installed catalogs against their metadata hashes.
  Future<Map<String, CatalogVerifyResult>> verify({String? name}) =>
      _verifyCatalogs(name: name);
}
