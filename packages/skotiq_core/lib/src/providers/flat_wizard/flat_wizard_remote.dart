// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of '../flat_wizard_provider.dart';

extension FlatWizardRemoteOps on FlatWizardNotifier {
  /// Admit one remote draft, then run it here. The handler has already
  /// checked the camera, the folder, and the draft's ranges. Returns false
  /// when a run already holds the latch; the caller answers 409 and does
  /// not start another capture.
  bool startHostRun(FlatWizardState draft) {
    if (startBlockReason != null) return false;
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
  void applyHostSnapshot(FlatRunSnapshot snapshot) {
    if (!mounted) return;
    final incoming = snapshot.state;
    _hostSnapshotRevision++;
    _remoteBusy = snapshot.busy || incoming.isCapturing;
    if (!_remoteBusy && _pendingHostStart == null) _cancelToken = null;
    _settingsRevision++;
    _filterRevision++;
    final key = snapshot.previewKey;
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
      filters: snapshot.output,
    );
    if (key == _remotePreviewKey) return;
    _remotePreviewKey = key;
    final generation = ++_previewGeneration;
    final backend = ref.read(linkedHostFlatWizardProvider);
    if (key == null || backend == null) return;
    unawaited(_loadHostPreview(backend, key, generation));
  }

  Future<void> _startLinkedRun(HostFlatWizard host) async {
    final request = Object();
    final revision = _hostSnapshotRevision;
    _pendingHostStart = request;
    _cancelToken = null;
    try {
      final snapshot = await host.startFlatWizardRun(
        flatWizardStateWire(state),
      );
      if (!mounted || !identical(_pendingHostStart, request)) return;
      if (_hostSnapshotRevision == revision) {
        applyHostSnapshot(FlatRunSnapshot.fromJson(snapshot));
      }
      if (_remoteBusy && cancelRequested) await _cancelLinkedRun(host);
    } catch (error, stack) {
      Log.error(
        'Could not start the host flat run',
        source: 'FlatWizardNotifier',
        error: error,
        stackTrace: stack,
      );
      if (mounted && identical(_pendingHostStart, request)) {
        setErrorMessage(
          'Could not start flat capture on the imaging host: ${userFacingError(error)}',
        );
      }
    } finally {
      if (mounted && identical(_pendingHostStart, request)) {
        _pendingHostStart = null;
        if (!_remoteBusy) _cancelToken = null;
      }
    }
  }

  Future<void> _cancelLinkedRun(HostFlatWizard host) async {
    final token = _cancelToken;
    try {
      await host.cancelFlatWizardRun();
    } catch (error, stack) {
      Log.warning(
        'Could not cancel the host flat run',
        source: 'FlatWizardNotifier',
        error: error,
        stackTrace: stack,
      );
      if (!mounted ||
          !identical(_cancelToken, token) ||
          !identical(ref.read(linkedHostFlatWizardProvider), host)) {
        return;
      }
      _cancelToken = null;
      setErrorMessage(
        'Could not cancel flat capture on the imaging host: ${userFacingError(error)}',
      );
    }
  }

  Future<void> _loadHostPreview(
    HostFlatWizard backend,
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
