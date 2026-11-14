import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

/// Which of the star and deep-sky catalogs are installed.
class CatalogState {
  final CatalogStatus starCatalogStatus;
  final CatalogStatus dsoCatalogStatus;

  /// Bumped whenever a catalog file is installed or removed, so the loaded
  /// catalogs reload instead of keeping what they read at startup.
  final int installRevision;

  const CatalogState({
    this.starCatalogStatus = const CatalogStatus.missing(SkyCatalog.stars),
    this.dsoCatalogStatus = const CatalogStatus.missing(SkyCatalog.dso),
    this.installRevision = 0,
  });
}

/// Follows the catalog manager: status at startup, then again after every
/// install or removal anywhere in the app (settings, host API).
class CatalogStateNotifier extends StateNotifier<CatalogState> {
  CatalogStateNotifier() : super(const CatalogState()) {
    // The catalog directory is wired up during app bootstrap, before this
    // notifier is first read.
    unawaited(refreshStatus());
    _changes = CatalogManager.instance.changes.listen((_) {
      state = CatalogState(
        starCatalogStatus: state.starCatalogStatus,
        dsoCatalogStatus: state.dsoCatalogStatus,
        installRevision: state.installRevision + 1,
      );
      unawaited(refreshStatus());
    });
  }

  late final StreamSubscription<SkyCatalog> _changes;

  @override
  void dispose() {
    _changes.cancel();
    super.dispose();
  }

  Future<void> refreshStatus() async {
    final manager = CatalogManager.instance;
    final stars = await manager.status(SkyCatalog.stars);
    final dsos = await manager.status(SkyCatalog.dso);
    if (!mounted) return;
    state = CatalogState(
      starCatalogStatus: stars,
      dsoCatalogStatus: dsos,
      installRevision: state.installRevision,
    );
  }
}

final catalogStateProvider =
    StateNotifierProvider<CatalogStateNotifier, CatalogState>(
      (ref) => CatalogStateNotifier(),
    );

/// The catalog manager's reader for the installed HYG file, re-read after an
/// install or removal. Overridable so a test can serve a fixture.
final starCatalogProvider = Provider<HygStarCatalog>((ref) {
  ref.watch(catalogStateProvider.select((s) => s.installRevision));
  return CatalogManager.instance.stars;
});

/// The stars the renderer and search draw from: magnitude 12 is the depth the
/// renderer needs; the per-frame magnitude limit filters below that.
final loadedStarsProvider = FutureProvider<List<Star>>((ref) async {
  final catalog = ref.watch(starCatalogProvider);
  return catalog.brighterThan(12.0);
});

/// True once the star load has resolved onto the built-in fallback list —
/// either because no HYG catalog is installed or because the installed one
/// could not be parsed.
///
/// The fallback is a few dozen naked-eye stars — the sky it draws is not a
/// usable one, so surfaces that render it must say so rather than let it pass
/// for the real catalog. [HygStarCatalog.loadOutcome] tells the two causes
/// apart.
final starCatalogFallbackProvider = Provider<bool>((ref) {
  final stars = ref.watch(loadedStarsProvider);
  if (!stars.hasValue) return false;
  return ref.watch(starCatalogProvider).isUsingFallback;
});

/// Installs one catalog, reporting progress and polling for a cancel.
typedef SkyCatalogInstaller =
    Future<Object?> Function(
      SkyCatalog catalog, {
      void Function(DownloadProgress)? onProgress,
      Future<bool> Function()? isCancelled,
    });

enum SkyCatalogInstallPhase { idle, running, failed, done }

/// Where the one-download install of the star and deep-sky catalogs stands.
class SkyCatalogInstallState {
  const SkyCatalogInstallState({
    this.phase = SkyCatalogInstallPhase.idle,
    this.progress = 0,
    this.status = '',
    this.error,
  });

  final SkyCatalogInstallPhase phase;

  /// 0..1 across both catalogs.
  final double progress;

  /// The installer's own line for the step in progress.
  final String status;

  /// Why the last attempt failed; present only in [SkyCatalogInstallPhase.failed].
  final Object? error;

  bool get isRunning => phase == SkyCatalogInstallPhase.running;
}

/// The star and deep-sky catalogs as one install, the set the planner,
/// planetarium and search need. Shared by every place that offers it
/// (first-run setup, the planner, Settings > Catalogs), so a download started
/// in one is the download the others show.
class SkyCatalogInstallNotifier extends StateNotifier<SkyCatalogInstallState> {
  SkyCatalogInstallNotifier(this._install)
    : super(const SkyCatalogInstallState());

  final SkyCatalogInstaller _install;
  bool _cancelRequested = false;

  static const List<SkyCatalog> catalogs = [SkyCatalog.stars, SkyCatalog.dso];

  /// Download and install both catalogs. Returns the final state; never
  /// throws. A second call while one is running is ignored.
  Future<SkyCatalogInstallState> start() async {
    if (state.isRunning) return state;
    _cancelRequested = false;
    state = const SkyCatalogInstallState(
      phase: SkyCatalogInstallPhase.running,
      status: 'Preparing download…',
    );
    try {
      for (var i = 0; i < catalogs.length; i++) {
        await _install(
          catalogs[i],
          isCancelled: () async => _cancelRequested,
          onProgress: (p) {
            if (!mounted || p.isTerminal) return;
            state = SkyCatalogInstallState(
              phase: SkyCatalogInstallPhase.running,
              progress: (i + p.progress) / catalogs.length,
              status: p.status,
            );
          },
        );
      }
      if (mounted) {
        state = const SkyCatalogInstallState(
          phase: SkyCatalogInstallPhase.done,
          progress: 1,
        );
      }
    } on CatalogCancelled {
      if (mounted) state = const SkyCatalogInstallState();
    } catch (error) {
      if (mounted) {
        state = SkyCatalogInstallState(
          phase: SkyCatalogInstallPhase.failed,
          error: error,
        );
      }
    }
    return state;
  }

  /// Ask the running install to stop at its next check.
  void cancel() {
    if (!state.isRunning) return;
    _cancelRequested = true;
    state = SkyCatalogInstallState(
      phase: SkyCatalogInstallPhase.running,
      progress: state.progress,
      status: 'Canceling…',
    );
  }
}

final skyCatalogInstallProvider =
    StateNotifierProvider<SkyCatalogInstallNotifier, SkyCatalogInstallState>(
      (ref) => SkyCatalogInstallNotifier(CatalogManager.instance.install),
    );
