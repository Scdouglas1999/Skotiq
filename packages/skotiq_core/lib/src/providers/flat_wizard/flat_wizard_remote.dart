// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of '../flat_wizard_provider.dart';

extension FlatWizardRemoteOps on FlatWizardNotifier {
  /// Admit one remote draft, then run it here. The handler has already
  /// checked the camera, the folder, and the draft's ranges. Returns false
  /// when a run already holds the latch; the caller answers 409 and does
  /// not start another capture.
  bool startHostRun(FlatWizardState draft) {
    if (_running) return false;
    _settingsRevision++;
    _filterRevision++;
    state = state.copyWith(
      mode: draft.mode,
      twilightMode: draft.twilightMode,
      globalSettings: draft.globalSettings,
      filterSettings: draft.filterSettings,
      currentFilterIndex: draft.currentFilterIndex,
    );
    // runCapture takes the latch synchronously, before its first await.
    unawaited(runCapture());
    return true;
  }

  /// Copy a host run onto this client without moving its tabs or panels.
  void applyHostSnapshot(Map<String, dynamic> snapshot) {
    if (!mounted) return;
    final raw = snapshot['state'];
    if (raw is! Map) {
      throw const FormatException('Flat wizard snapshot has no state');
    }
    final FlatWizardState incoming;
    try {
      incoming = FlatWizardState.fromJson(Map<String, dynamic>.from(raw));
    } on Object catch (error) {
      throw FormatException('Flat wizard snapshot state is not usable: $error');
    }
    _remoteBusy = snapshot['busy'] == true || incoming.isCapturing;
    _settingsRevision++;
    _filterRevision++;
    final key = snapshot['previewKey'] is String
        ? snapshot['previewKey'] as String
        : null;
    final keepPreview = key != null && key == _remotePreviewKey;
    // The mode, twilight phase and which panels are open belong to this
    // screen. The host snapshot must not move them.
    state = incoming.copyWith(
      mode: state.mode,
      twilightMode: state.twilightMode,
      showAduGraph: state.showAduGraph,
      showExposureTimeline: state.showExposureTimeline,
      showSkyBrightness: state.showSkyBrightness,
      showFilterCards: state.showFilterCards,
      showHistogramOverlay: state.showHistogramOverlay,
      lastImageData: keepPreview ? state.lastImageData : null,
    );
    ref.read(flatRunOutputProvider.notifier).state = FlatRunOutput(
      remote: true,
      filters: _flatRunOutputFromSnapshot(snapshot['output']),
    );
    if (key == _remotePreviewKey) return;
    _remotePreviewKey = key;
    final generation = ++_previewGeneration;
    final backend = ref.read(backendProvider);
    if (key == null || backend is! NetworkBackend) return;
    unawaited(_loadHostPreview(backend, key, generation));
  }

  Map<String, dynamic> _linkedHostDraft() {
    final chosen = state.globalSettings.savePath?.trim();
    if (chosen != null && chosen.isNotEmpty) {
      return flatWizardStateWire(state);
    }
    final capture =
        (ref.read(appSettingsProvider).valueOrNull?.imageOutputPath ?? '')
            .trim();
    final folder = defaultFlatFolder(capture, onHost: true);
    if (folder == null) return flatWizardStateWire(state);
    return flatWizardStateWire(
      state.copyWith(
        globalSettings: state.globalSettings.copyWith(savePath: folder),
      ),
    );
  }

  Future<void> _loadHostPreview(
    NetworkBackend backend,
    String key,
    int generation,
  ) async {
    try {
      final image = await backend.getFlatWizardPreview(key);
      if (!mounted || generation != _previewGeneration) return;
      state = state.copyWith(lastImageData: image);
    } catch (error, stack) {
      if (!mounted || generation != _previewGeneration) return;
      _remotePreviewKey = null;
      Log.warning(
        'Flat preview download failed: $error',
        source: 'FlatWizardNotifier',
        error: error,
        stackTrace: stack,
      );
    }
  }
}

Map<String, FlatRunFilterOutput> _flatRunOutputFromSnapshot(Object? raw) {
  if (raw == null) return const {};
  if (raw is! Map) {
    throw const FormatException('Flat run output is not an object');
  }
  final filters = <String, FlatRunFilterOutput>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || value is! Map) {
      throw const FormatException('Flat run output entry is not an object');
    }
    final map = Map<String, dynamic>.from(value);
    final filter = map['filter'];
    final exposure = map['exposureSeconds'];
    final paths = map['paths'];
    if (filter is! String || exposure is! num || paths is! List) {
      throw FormatException('Flat run output for $key is incomplete');
    }
    filters[key] = FlatRunFilterOutput(
      filter: filter,
      exposureSeconds: exposure.toDouble(),
      paths: [for (final path in paths) '$path'],
      gain: map['gain'] as int?,
      offset: map['offset'] as int?,
      binX: (map['binX'] as num?)?.toInt() ?? 1,
      binY: (map['binY'] as num?)?.toInt() ?? 1,
    );
  }
  return filters;
}
