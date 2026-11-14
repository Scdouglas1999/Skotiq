import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend/event_types.dart';
import 'linked_host.dart';
import 'async_scope.dart';
import '../errors/error_text.dart';
import '../models/backend/host_mutation_event.dart';
import '../models/defect_map.dart';
import '../models/equipment/equipment_models.dart';
import '../services/calibration/defect_map_service.dart';
import '../settings/setting.dart';
import '../settings/store_settings.dart';
import '../backend/remote_host.dart';
import 'backend_provider.dart';
import 'capability_provider.dart';
import 'database_provider.dart';
import 'equipment_provider.dart';
import '../database/daos/settings_dao.dart';
import 'logging_service_provider.dart';
import '../services/logging_service.dart';

const Object _defectMapSettingsSentinel = Object();
const Object _defectMapUiSentinel = Object();

/// Service provider for [DefectMapService]. The service reads the active
/// backend through [ref] so build/apply can route to the host over REST when
/// running as a remote client.
final defectMapServiceProvider = Provider<DefectMapService>((ref) {
  return DefectMapService(ref);
});

/// Query parameters for looking up a stored defect map.
class DefectMapQuery {
  final String cameraId;
  final int width;
  final int height;
  final double sensorTemperatureCelsius;

  const DefectMapQuery({
    required this.cameraId,
    required this.width,
    required this.height,
    required this.sensorTemperatureCelsius,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DefectMapQuery &&
          runtimeType == other.runtimeType &&
          cameraId == other.cameraId &&
          width == other.width &&
          height == other.height &&
          sensorTemperatureCelsius == other.sensorTemperatureCelsius;

  @override
  int get hashCode =>
      Object.hash(cameraId, width, height, sensorTemperatureCelsius);
}

/// Status of the defect map for a given (camera, sensor, temperature)
/// tuple. Null means no map has been built yet for that combination.
final defectMapStatusProvider =
    FutureProvider.family<DefectMapStatus?, DefectMapQuery>((ref, query) async {
      final backend = ref.watch(backendProvider);
      final remote = ref.watch(linkedHostCalibrationFramesProvider);
      if (remote != null) {
        final subscription = backend.eventStream.listen((event) {
          if (event.eventType == hostStateChangedEventType &&
              event.data['entityType'] == HostMutationEntity.settings &&
              event.data['namespace'] == 'defect-map') {
            ref.invalidateSelf();
          }
        });
        ref.onDispose(subscription.cancel);
      }
      final service = ref.watch(defectMapServiceProvider);
      return service.getStatus(
        cameraId: query.cameraId,
        width: query.width,
        height: query.height,
        sensorTemperatureCelsius: query.sensorTemperatureCelsius,
      );
    });

/// UI state for the imaging-screen calibration section.
///
/// Tracks the in-flight operation (build/clear) so the panel can disable
/// buttons and show progress, and any error from the most recent
/// operation. Errors are surfaced as state rather than swallowed.
class DefectMapUiState {
  final bool isBuilding;
  final bool isClearing;
  final String? statusMessage;
  final String? errorMessage;

  const DefectMapUiState({
    this.isBuilding = false,
    this.isClearing = false,
    this.statusMessage,
    this.errorMessage,
  });

  DefectMapUiState copyWith({
    bool? isBuilding,
    bool? isClearing,
    Object? statusMessage = _defectMapUiSentinel,
    Object? errorMessage = _defectMapUiSentinel,
  }) {
    return DefectMapUiState(
      isBuilding: isBuilding ?? this.isBuilding,
      isClearing: isClearing ?? this.isClearing,
      statusMessage: identical(statusMessage, _defectMapUiSentinel)
          ? this.statusMessage
          : statusMessage as String?,
      errorMessage: identical(errorMessage, _defectMapUiSentinel)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}

class DefectMapNotifier extends StateNotifier<DefectMapUiState> {
  final Ref ref;
  int _authorityGeneration = 0;
  int _buildGeneration = 0;
  int _applyGeneration = 0;
  int _pushGeneration = 0;
  int _clearGeneration = 0;

  DefectMapNotifier(this.ref) : super(const DefectMapUiState()) {
    ref.listen(backendProvider, (previous, next) {
      if (previous != null && !identical(previous, next)) {
        _invalidateOperations();
      }
    });
    ref.listen<String?>(
      cameraStateProvider.select((camera) => camera.deviceId),
      (previous, next) {
        if (previous != next) _invalidateOperations();
      },
    );
  }

  DefectMapService get _service => ref.read(defectMapServiceProvider);

  /// Build a new defect map from the supplied dark-frame paths.
  ///
  /// On a remote client the operator picks a host directory rather than
  /// individual files (the host filesystem is not enumerable client-side);
  /// pass that directory as [darkFramesDirectory] with an empty
  /// [darkFramePaths] and the host enumerates its FITS/XISF darks.
  Future<void> build({
    required String cameraId,
    required List<String> darkFramePaths,
    required double sensorTemperatureCelsius,
    String? darkFramesDirectory,
  }) async {
    final generation = ++_buildGeneration;
    final authorityGeneration = _authorityGeneration;
    final authority = ref.read(backendProvider);
    state = state.copyWith(
      isBuilding: true,
      statusMessage: darkFramesDirectory != null
          ? 'Scanning host dark frames in $darkFramesDirectory for defective '
                'pixels...'
          : 'Scanning ${darkFramePaths.length} dark frames for defective '
                'pixels...',
      errorMessage: null,
    );
    try {
      final status = await _service.build(
        cameraId: cameraId,
        darkFramePaths: darkFramePaths,
        sensorTemperatureCelsius: sensorTemperatureCelsius,
        darkFramesDirectory: darkFramesDirectory,
      );
      if (!_isCurrent(authorityGeneration, authority) ||
          generation != _buildGeneration) {
        return;
      }
      state = state.copyWith(
        isBuilding: false,
        statusMessage:
            'Defect map built: ${status.defectivePixelCount} defective pixels '
            'flagged at ${status.temperatureBucket.label}.',
        errorMessage: null,
      );
      ref.invalidate(defectMapStatusProvider);
    } catch (e) {
      if (!_isCurrent(authorityGeneration, authority) ||
          generation != _buildGeneration) {
        return;
      }
      state = state.copyWith(
        isBuilding: false,
        statusMessage: null,
        errorMessage: 'Failed to build defect map: ${userFacingError(e)}',
      );
    }
  }

  /// Turn correction of [cameraId]'s lights during capture on (with the map
  /// stored for this sensor size and temperature) or off. It applies from the
  /// next exposure, including in a running sequence.
  Future<void> setApplyDuringCapture({
    required String cameraId,
    required bool apply,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  }) async {
    final generation = ++_applyGeneration;
    final authorityGeneration = _authorityGeneration;
    final authority = ref.read(backendProvider);
    try {
      final settings = ref.read(defectMapSettingsProvider);
      await _service.applyToSequencer(
        cameraId: cameraId,
        width: width,
        height: height,
        sensorTemperatureCelsius: sensorTemperatureCelsius,
        enabled: apply,
        method: settings.method,
        kernel: settings.kernel,
        saveOriginal: settings.saveOriginal,
      );
      if (!_isCurrent(authorityGeneration, authority) ||
          generation != _applyGeneration) {
        return;
      }
      state = state.copyWith(
        statusMessage: apply
            ? 'Defect map will be applied to lights at capture.'
            : 'Defect map will not be applied to lights at capture.',
        errorMessage: null,
      );
      ref.invalidate(defectMapStatusProvider);
    } catch (e) {
      if (!_isCurrent(authorityGeneration, authority) ||
          generation != _applyGeneration) {
        return;
      }
      state = state.copyWith(
        statusMessage: null,
        errorMessage:
            'Failed to update defect-map toggle: ${userFacingError(e)}',
      );
    }
  }

  /// Push the user's current defect-map settings to the running
  /// sequencer. Used by camera-connect notifiers and settings UI
  /// when the user changes kernel / method without flipping the
  /// apply switch — those changes still need to propagate down so
  /// the next captured frame uses the new replacement strategy.
  Future<void> pushCurrentSettingsToSequencer({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
    required bool enabled,
  }) async {
    final generation = ++_pushGeneration;
    final authorityGeneration = _authorityGeneration;
    final authority = ref.read(backendProvider);
    try {
      final settings = ref.read(defectMapSettingsProvider);
      await _service.applyToSequencer(
        cameraId: cameraId,
        width: width,
        height: height,
        sensorTemperatureCelsius: sensorTemperatureCelsius,
        enabled: enabled,
        method: settings.method,
        kernel: settings.kernel,
        saveOriginal: settings.saveOriginal,
      );
      if (!_isCurrent(authorityGeneration, authority) ||
          generation != _pushGeneration) {
        return;
      }
      state = state.copyWith(errorMessage: null);
    } catch (e) {
      if (!_isCurrent(authorityGeneration, authority) ||
          generation != _pushGeneration) {
        return;
      }
      state = state.copyWith(
        statusMessage: null,
        errorMessage:
            'Failed to push defect-map settings to sequencer: ${userFacingError(e)}',
      );
    }
  }

  /// Reconcile the live sequencer slot with both activation sources: the
  /// global auto-apply setting and the persisted per-camera toggle. This is
  /// called after any correction-setting edit, including turning auto-apply
  /// off, so stale native runtime state is explicitly cleared.
  Future<void> syncCurrentSettingsToSequencer({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  }) async {
    final status = await _service.getStatus(
      cameraId: cameraId,
      width: width,
      height: height,
      sensorTemperatureCelsius: sensorTemperatureCelsius,
    );
    final settings = ref.read(defectMapSettingsProvider);
    final enabled =
        status?.storedOnDisk == true &&
        (settings.autoApply || status!.applyDuringCapture);
    await pushCurrentSettingsToSequencer(
      cameraId: cameraId,
      width: width,
      height: height,
      sensorTemperatureCelsius: sensorTemperatureCelsius,
      enabled: enabled,
    );
  }

  /// Delete the stored defect map for this camera at this size and
  /// temperature bucket.
  Future<void> clear({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  }) async {
    final generation = ++_clearGeneration;
    final authorityGeneration = _authorityGeneration;
    final authority = ref.read(backendProvider);
    state = state.copyWith(
      isClearing: true,
      statusMessage: 'Clearing defect map...',
      errorMessage: null,
    );
    try {
      await _service.clear(
        cameraId: cameraId,
        width: width,
        height: height,
        sensorTemperatureCelsius: sensorTemperatureCelsius,
      );
      if (!_isCurrent(authorityGeneration, authority) ||
          generation != _clearGeneration) {
        return;
      }
      state = state.copyWith(
        isClearing: false,
        statusMessage: 'Defect map cleared.',
        errorMessage: null,
      );
      ref.invalidate(defectMapStatusProvider);
    } catch (e) {
      if (!_isCurrent(authorityGeneration, authority) ||
          generation != _clearGeneration) {
        return;
      }
      state = state.copyWith(
        isClearing: false,
        statusMessage: null,
        errorMessage: 'Failed to clear defect map: ${userFacingError(e)}',
      );
    }
  }

  void clearError() {
    state = state.copyWith(errorMessage: null);
  }

  void clearStatus() {
    state = state.copyWith(statusMessage: null);
  }

  bool _isCurrent(int authorityGeneration, Object authority) {
    return mounted &&
        authorityGeneration == _authorityGeneration &&
        ref.scopeOver<Object>(backendProvider, authority).isCurrent;
  }

  void _invalidateOperations() {
    _authorityGeneration++;
    if (mounted) state = const DefectMapUiState();
  }
}

/// StateNotifier provider for the calibration section's transient UI
/// state (in-flight build/clear, status / error messages).
final defectMapNotifierProvider =
    StateNotifierProvider<DefectMapNotifier, DefectMapUiState>((ref) {
      return DefectMapNotifier(ref);
    });

// Per-camera defect-map auto-apply settings.
//
// These are NOT part of the legacy app_settings freezed model because they
// don't need codegen — they're stored as plain key/value rows in the
// `app_settings` table via the same `settingsDaoProvider` the calibration
// section already uses. The dedicated provider centralises the keys + the
// load/save logic so the settings UI doesn't have to know about the storage
// layout.

/// User-facing settings for per-frame defect-map application during
/// capture. Independent of whether a map exists on disk — those are
/// authoritative state queried via [defectMapStatusProvider].
class DefectMapSettings {
  /// When true, the sequencer will apply the defect map to every
  /// captured light frame automatically (assuming one exists for the
  /// connected camera at the current temperature bucket). Default
  /// false — opt-in to avoid surprise corrections.
  final bool autoApply;

  /// Replacement method used to fill defective pixels.
  final DefectMapMethod method;

  /// Kernel diameter for the neighbour search.
  final DefectMapKernelSize kernel;

  /// When true, the original uncorrected frame is also saved to a
  /// `Raw/` sibling directory next to the canonical save. Default
  /// false (the corrected frame replaces the raw one).
  final bool saveOriginal;

  final bool isLoading;
  final Object? loadError;

  const DefectMapSettings({
    this.autoApply = false,
    this.method = DefectMapMethod.median,
    this.kernel = DefectMapKernelSize.k3,
    this.saveOriginal = false,
    this.isLoading = false,
    this.loadError,
  });

  DefectMapSettings copyWith({
    bool? autoApply,
    DefectMapMethod? method,
    DefectMapKernelSize? kernel,
    bool? saveOriginal,
    bool? isLoading,
    Object? loadError = _defectMapSettingsSentinel,
  }) {
    return DefectMapSettings(
      autoApply: autoApply ?? this.autoApply,
      method: method ?? this.method,
      kernel: kernel ?? this.kernel,
      saveOriginal: saveOriginal ?? this.saveOriginal,
      isLoading: isLoading ?? this.isLoading,
      loadError: loadError == _defectMapSettingsSentinel
          ? this.loadError
          : loadError,
    );
  }

  /// What the stored [rows] hold.
  factory DefectMapSettings.fromRows(Map<String, String> rows) =>
      DefectMapSettings(
        autoApply: StoreSettings.defectMapAutoApply.valueIn(rows),
        method: DefectMapMethod.fromWire(
          StoreSettings.defectMapMethod.valueIn(rows),
        ),
        kernel: DefectMapKernelSize.fromDiameter(
          StoreSettings.defectMapKernelDiameter.valueIn(rows),
        ),
        saveOriginal: StoreSettings.defectMapSaveOriginal.valueIn(rows),
      );

  /// The snapshot `GET /api/calibration/defect-maps/settings` returns.
  Map<String, dynamic> toRemoteJson() => {
    'autoApply': autoApply,
    'method': method.wireValue,
    'kernelDiameter': kernel.diameter,
    'saveOriginal': saveOriginal,
  };

  factory DefectMapSettings.fromRemoteJson(Map<String, dynamic> json) {
    final autoApply = json['autoApply'];
    final methodRaw = json['method'];
    final kernelRaw = json['kernelDiameter'];
    final saveOriginal = json['saveOriginal'];
    if (autoApply is! bool ||
        methodRaw is! String ||
        kernelRaw is! num ||
        saveOriginal is! bool) {
      throw const FormatException(
        'Malformed defect-map settings from imaging host',
      );
    }
    final methods = DefectMapMethod.values.where(
      (method) => method.wireValue == methodRaw,
    );
    final kernels = DefectMapKernelSize.values.where(
      (kernel) => kernel.diameter == kernelRaw.toInt(),
    );
    if (methods.isEmpty ||
        kernels.isEmpty ||
        kernelRaw.toDouble() != kernelRaw.toInt().toDouble()) {
      throw const FormatException(
        'Unknown defect-map method or kernel from imaging host',
      );
    }
    return DefectMapSettings(
      autoApply: autoApply,
      method: methods.first,
      kernel: kernels.first,
      saveOriginal: saveOriginal,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DefectMapSettings &&
          runtimeType == other.runtimeType &&
          autoApply == other.autoApply &&
          method == other.method &&
          kernel == other.kernel &&
          saveOriginal == other.saveOriginal &&
          isLoading == other.isLoading &&
          loadError == other.loadError;

  @override
  int get hashCode => Object.hash(
    autoApply,
    method,
    kernel,
    saveOriginal,
    isLoading,
    loadError,
  );
}

/// StateNotifier managing [DefectMapSettings]. Loads from the
/// `app_settings` table on construction; persists each setter.
class DefectMapSettingsNotifier extends StateNotifier<DefectMapSettings> {
  final Ref _ref;
  final HostCalibrationFrames? _remote;
  ProviderSubscription? _settingsSub;
  StreamSubscription? _remoteEventSub;
  Future<void>? _remoteLoad;
  final Completer<void> _loadedCompleter = Completer<void>();

  DefectMapSettingsNotifier(
    this._ref, {
    HostCalibrationFrames? remote,
    Stream<SkotiqEvent> Function()? hostEvents,
  }) : _remote = remote,
       super(const DefectMapSettings(isLoading: true)) {
    if (hostEvents != null) {
      _remoteEventSub = hostEvents().listen(
        (event) {
          if (event.eventType != hostStateChangedEventType ||
              event.data['entityType'] != HostMutationEntity.settings ||
              event.data['namespace'] != 'defect-map') {
            return;
          }
          _remoteLoad = _loadRemote(showLoading: false);
        },
        onError: (Object error, StackTrace stackTrace) {
          Log.error(
            'Defect-map settings event stream failed: $error',
            source: 'DefectMapSettings',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
      _remoteLoad = _loadRemote(showLoading: true);
      return;
    }
    _settingsSub = _ref.listen<AsyncValue<Map<String, String>>>(
      allSettingsProvider,
      (_, next) => next.when(
        data: _applyLoaded,
        loading: () {},
        error: (error, _) {
          state = state.copyWith(isLoading: false, loadError: error);
          if (!_loadedCompleter.isCompleted) {
            _loadedCompleter.complete();
          }
        },
      ),
      fireImmediately: true,
    );
  }

  Future<void> get loaded => _remoteLoad ?? _loadedCompleter.future;

  @override
  void dispose() {
    _settingsSub?.close();
    unawaited(_remoteEventSub?.cancel());
    super.dispose();
  }

  void _applyLoaded(Map<String, String> kv) {
    state = DefectMapSettings.fromRows(kv);
    if (!_loadedCompleter.isCompleted) {
      _loadedCompleter.complete();
    }
  }

  Future<void> _loadRemote({required bool showLoading}) async {
    if (showLoading) {
      state = state.copyWith(isLoading: true, loadError: null);
    }
    try {
      final loaded = DefectMapSettings.fromRemoteJson(
        await _remote!.getDefectMapSettings(),
      );
      if (!mounted) return;
      state = loaded;
    } catch (error, stackTrace) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, loadError: error);
      Log.error(
        'Could not load defect-map settings from imaging host: $error',
        source: 'DefectMapSettings',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (!_loadedCompleter.isCompleted) {
        _loadedCompleter.complete();
      }
    }
  }

  Future<void> setAutoApply(bool value) async {
    if (_remote != null) {
      await _saveRemote({
        'autoApply': value,
      }, (current) => current.copyWith(autoApply: value));
      return;
    }
    await _saveLocal(StoreSettings.defectMapAutoApply, value);
    state = state.copyWith(autoApply: value, loadError: null);
  }

  Future<void> setMethod(DefectMapMethod value) async {
    if (_remote != null) {
      await _saveRemote({
        'method': value.wireValue,
      }, (current) => current.copyWith(method: value));
      return;
    }
    await _saveLocal(StoreSettings.defectMapMethod, value.wireValue);
    state = state.copyWith(method: value, loadError: null);
  }

  Future<void> setKernel(DefectMapKernelSize value) async {
    if (_remote != null) {
      await _saveRemote({
        'kernelDiameter': value.diameter,
      }, (current) => current.copyWith(kernel: value));
      return;
    }
    await _saveLocal(StoreSettings.defectMapKernelDiameter, value.diameter);
    state = state.copyWith(kernel: value, loadError: null);
  }

  Future<void> setSaveOriginal(bool value) async {
    if (_remote != null) {
      await _saveRemote({
        'saveOriginal': value,
      }, (current) => current.copyWith(saveOriginal: value));
      return;
    }
    await _saveLocal(StoreSettings.defectMapSaveOriginal, value);
    state = state.copyWith(saveOriginal: value, loadError: null);
  }

  Future<void> _saveLocal<T>(Setting<T> setting, T value) =>
      _ref.read(settingsDaoProvider).write(setting, value);

  Future<void> _saveRemote(
    Map<String, dynamic> patch,
    DefectMapSettings Function(DefectMapSettings current) applyPatch,
  ) async {
    await loaded;
    final loadError = state.loadError;
    if (loadError != null) {
      throw StateError(
        'Defect-map settings are unavailable from the imaging host: '
        '$loadError',
      );
    }
    await _remote!.updateDefectMapSettings(patch);
    if (!mounted) return;
    state = applyPatch(state).copyWith(isLoading: false, loadError: null);
  }
}

final defectMapSettingsProvider =
    StateNotifierProvider<DefectMapSettingsNotifier, DefectMapSettings>((ref) {
      return DefectMapSettingsNotifier(
        ref,
        remote: ref.watch(linkedHostCalibrationFramesProvider),
        hostEvents: ref.watch(linkedHostEventsProvider),
      );
    });

/// Seed the live sequencer's defect-correction state from the authoritative
/// persisted settings immediately before a run starts or resumes.
///
/// Persisting `autoApply` alone is insufficient: the native executor keeps a
/// separate pre-loaded runtime slot. Without this boundary call, auto-apply
/// only works in the session where the operator happened to toggle the UI.
Future<void> seedDefectMapRuntimeForSequence(Ref ref) async {
  final settingsNotifier = ref.read(defectMapSettingsProvider.notifier);
  await settingsNotifier.loaded;
  final settings = ref.read(defectMapSettingsProvider);
  if (settings.loadError != null) {
    throw StateError(
      'Could not load defect-map settings before sequence start: '
      '${settings.loadError}',
    );
  }

  final camera = ref.read(cameraStateProvider);
  final cameraId = camera.deviceId;
  if (camera.connectionState != DeviceConnectionState.connected ||
      cameraId == null ||
      cameraId.isEmpty) {
    return;
  }
  final temperature = camera.temperature;
  if (temperature == null) {
    if (settings.autoApply) {
      ref
          .read(loggingServiceProvider)
          .warning(
            'Defect-map auto-apply could not be seeded because the camera '
            'has not reported a sensor temperature.',
            source: 'DefectMapSettings',
          );
    }
    return;
  }

  final capabilities = await ref.read(
    cameraCapabilitiesProvider(cameraId).future,
  );
  if (capabilities == null ||
      capabilities.maxWidth <= 0 ||
      capabilities.maxHeight <= 0) {
    if (settings.autoApply) {
      ref
          .read(loggingServiceProvider)
          .warning(
            'Defect-map auto-apply could not be seeded because the camera '
            'reported invalid sensor dimensions.',
            source: 'DefectMapSettings',
          );
    }
    return;
  }

  final service = ref.read(defectMapServiceProvider);
  final status = await service.getStatus(
    cameraId: cameraId,
    width: capabilities.maxWidth,
    height: capabilities.maxHeight,
    sensorTemperatureCelsius: temperature,
  );
  final mapAvailable = status?.storedOnDisk == true;
  final enabled =
      mapAvailable && (settings.autoApply || status!.applyDuringCapture);
  await service.applyToSequencer(
    cameraId: cameraId,
    width: capabilities.maxWidth,
    height: capabilities.maxHeight,
    sensorTemperatureCelsius: temperature,
    enabled: enabled,
    method: settings.method,
    kernel: settings.kernel,
    saveOriginal: settings.saveOriginal,
  );

  if (settings.autoApply && !mapAvailable) {
    ref
        .read(loggingServiceProvider)
        .warning(
          'Defect-map auto-apply is enabled, but no map exists for $cameraId '
          'at ${DefectMapTemperatureBucket.fromCelsius(temperature).label}; '
          'the sequencer runtime was explicitly disabled.',
          source: 'DefectMapSettings',
        );
  }
}
