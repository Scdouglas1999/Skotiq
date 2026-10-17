import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../catalogs/catalog_manager.dart';
import '../catalogs/star_catalog.dart';
import '../celestial_object.dart';

/// State for catalog installation status
class CatalogState {
  final CatalogStatus starCatalogStatus;
  final CatalogStatus dsoCatalogStatus;
  final bool isInitialized;
  final bool isDownloading;
  final double downloadProgress;
  final String? downloadError;

  const CatalogState({
    this.starCatalogStatus = const CatalogStatus(isInstalled: false),
    this.dsoCatalogStatus = const CatalogStatus(isInstalled: false),
    this.isInitialized = false,
    this.isDownloading = false,
    this.downloadProgress = 0,
    this.downloadError,
  });

  bool get catalogsInstalled =>
      starCatalogStatus.isInstalled && dsoCatalogStatus.isInstalled;

  bool get anyCatalogInstalled =>
      starCatalogStatus.isInstalled || dsoCatalogStatus.isInstalled;

  int get totalStarCount => starCatalogStatus.objectCount ?? 0;
  int get totalDsoCount => dsoCatalogStatus.objectCount ?? 0;

  CatalogState copyWith({
    CatalogStatus? starCatalogStatus,
    CatalogStatus? dsoCatalogStatus,
    bool? isInitialized,
    bool? isDownloading,
    double? downloadProgress,
    String? downloadError,
  }) {
    return CatalogState(
      starCatalogStatus: starCatalogStatus ?? this.starCatalogStatus,
      dsoCatalogStatus: dsoCatalogStatus ?? this.dsoCatalogStatus,
      isInitialized: isInitialized ?? this.isInitialized,
      isDownloading: isDownloading ?? this.isDownloading,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      downloadError: downloadError,
    );
  }
}

/// Notifier for managing catalog state
class CatalogStateNotifier extends StateNotifier<CatalogState> {
  CatalogStateNotifier() : super(const CatalogState()) {
    // The catalog directory is wired up during app bootstrap (before this
    // notifier is first read), so seed from disk right away instead of waiting
    // for someone to call initialize(). Without this the provider stays at its
    // "nothing installed" default forever and screens that key off it (e.g. the
    // planner empty-state) misreport installed catalogs as missing.
    if (CatalogManager.instance.isInitialized) {
      unawaited(refreshStatus());
    }
    // Keep in sync with downloads finishing anywhere in the app (settings,
    // onboarding dialog, headless API) via the shared progress stream.
    _downloadSub = CatalogManager.instance.downloadProgress.listen((progress) {
      if (progress.isComplete) {
        unawaited(refreshStatus());
      }
    });
  }

  StreamSubscription<DownloadProgress>? _downloadSub;

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  /// Initialize the catalog manager and check status
  Future<void> initialize(String catalogDirectory) async {
    try {
      await CatalogManager.instance.initialize(catalogDirectory);
      await refreshStatus();
      state = state.copyWith(isInitialized: true);
    } catch (e) {
      state = state.copyWith(
        isInitialized: true,
        downloadError: 'Failed to initialize: $e',
      );
    }
  }

  /// Refresh catalog status
  Future<void> refreshStatus() async {
    if (!CatalogManager.instance.isInitialized) return;
    try {
      final starStatus = await CatalogManager.instance.getStarCatalogStatus();
      final dsoStatus = await CatalogManager.instance.getDsoCatalogStatus();

      state = state.copyWith(
        starCatalogStatus: starStatus,
        dsoCatalogStatus: dsoStatus,
        isInitialized: true,
        downloadError: null,
      );
    } catch (e) {
      state = state.copyWith(downloadError: 'Failed to check status: $e');
    }
  }

  /// Download catalogs with the specified package
  Future<bool> downloadCatalogs(CatalogPackage package) async {
    state = state.copyWith(
      isDownloading: true,
      downloadProgress: 0,
      downloadError: null,
    );

    try {
      // Download star catalog
      final starSuccess = await CatalogManager.instance.downloadStarCatalog(
        package: package,
        onProgress: (progress) {
          state = state.copyWith(downloadProgress: progress.progress * 0.5);
        },
      );

      if (!starSuccess) {
        throw Exception('Star catalog download failed');
      }

      // Download DSO catalog
      final dsoSuccess = await CatalogManager.instance.downloadDsoCatalog(
        package: package,
        onProgress: (progress) {
          state = state.copyWith(
            downloadProgress: 0.5 + (progress.progress * 0.5),
          );
        },
      );

      if (!dsoSuccess) {
        throw Exception('DSO catalog download failed');
      }

      await refreshStatus();
      state = state.copyWith(isDownloading: false, downloadProgress: 1.0);

      return true;
    } catch (e) {
      state = state.copyWith(isDownloading: false, downloadError: e.toString());
      return false;
    }
  }

  /// Delete all catalogs
  Future<void> deleteCatalogs() async {
    await CatalogManager.instance.deleteCatalogs();
    await refreshStatus();
  }
}

/// Provider for catalog state
final catalogStateProvider =
    StateNotifierProvider<CatalogStateNotifier, CatalogState>(
      (ref) => CatalogStateNotifier(),
    );

/// The one HYG star catalog in the process.
///
/// Every consumer shares this instance, so the ~120k-row CSV is parsed once and
/// the fallback banner describes the catalog that is on screen. Magnitude 12 is
/// the depth the renderer needs; the per-frame magnitude limit filters below
/// that.
final starCatalogProvider = Provider<HygStarCatalog>((ref) {
  return HygStarCatalog(magnitudeLimit: 12.0);
});

/// Provider for loading stars
final starsProvider = FutureProvider<List<Star>>((ref) async {
  final catalog = ref.watch(starCatalogProvider);
  return catalog.loadObjects();
});

/// True once the star load has resolved onto the built-in fallback list —
/// either because no HYG catalog is installed or because the installed one
/// could not be parsed.
///
/// The fallback is a few dozen naked-eye stars — the sky it draws is not a
/// usable one, so surfaces that render it must say so rather than let it pass
/// for the real catalog. Read [starCatalogLoadOutcomeProvider] to tell the two
/// causes apart.
final starCatalogFallbackProvider = Provider<bool>((ref) {
  final stars = ref.watch(starsProvider);
  if (!stars.hasValue) return false;
  return ref.watch(starCatalogProvider).isUsingFallback;
});

/// How the star-catalog load resolved: installed and parsed, not installed, or
/// present but unreadable.
final starCatalogLoadOutcomeProvider = Provider<StarCatalogLoadOutcome>((ref) {
  final stars = ref.watch(starsProvider);
  if (!stars.hasValue) return StarCatalogLoadOutcome.notLoaded;
  return ref.watch(starCatalogProvider).loadOutcome;
});

/// Number of stars in the built-in fallback list.
final fallbackStarCountProvider = Provider<int>(
  (ref) => HygStarCatalog.fallbackStarCount,
);
