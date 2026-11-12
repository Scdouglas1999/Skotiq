part of '../science_provider.dart';

class ScienceVisualizationPrefsNotifier
    extends AsyncNotifier<ScienceVisualizationPrefs> {
  Future<void> _writeTail = Future<void>.value();

  @override
  Future<ScienceVisualizationPrefs> build() async {
    final rows = await _loadScienceSettingsMap(ref);
    T read<T>(Setting<T> setting) => setting.decodeStrict(rows[setting.key]);

    return ScienceVisualizationPrefs(
      overlayOpacity: read(StoreSettings.scienceOverlayOpacity),
      liveGridRows: read(StoreSettings.scienceLiveGridRows),
      liveGridCols: read(StoreSettings.scienceLiveGridCols),
      analysisGridRows: read(StoreSettings.scienceAnalysisGridRows),
      analysisGridCols: read(StoreSettings.scienceAnalysisGridCols),
    );
  }

  Future<void> savePrefs(ScienceVisualizationPrefs prefs) {
    final result = _writeTail.then((_) async {
      if (state.valueOrNull == null) {
        throw StateError(
          'Science visualization preferences are not loaded; refusing to '
          'overwrite them with defaults.',
        );
      }
      await _writeScienceSettings(ref, {
        ...StoreSettings.scienceOverlayOpacity.toRows(prefs.overlayOpacity),
        ...StoreSettings.scienceLiveGridRows.toRows(prefs.liveGridRows),
        ...StoreSettings.scienceLiveGridCols.toRows(prefs.liveGridCols),
        ...StoreSettings.scienceAnalysisGridRows.toRows(prefs.analysisGridRows),
        ...StoreSettings.scienceAnalysisGridCols.toRows(prefs.analysisGridCols),
      });
      state = AsyncData(prefs);
    });
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}

final scienceVisualizationPrefsProvider =
    AsyncNotifierProvider<
      ScienceVisualizationPrefsNotifier,
      ScienceVisualizationPrefs
    >(ScienceVisualizationPrefsNotifier.new);
