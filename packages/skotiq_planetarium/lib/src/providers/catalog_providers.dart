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
