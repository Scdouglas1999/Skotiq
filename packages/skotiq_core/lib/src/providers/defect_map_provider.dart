import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../models/backend/host_mutation_event.dart';
import '../models/defect_map.dart';
import '../models/equipment/equipment_models.dart';
import '../services/calibration/defect_map_service.dart';
import '../services/logging_service.dart';
import 'backend_provider.dart';
import 'capability_provider.dart';
import 'database_provider.dart';
import 'equipment_provider.dart';

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
      if (backend is NetworkBackend) {
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
        errorMessage: 'Failed to build defect map: $e',
      );
    }
  }

  /// Enable or disable defect-map application during capture.
  ///
  /// Persists the user preference AND, when the caller supplies the
  /// camera dimensions + temperature, pushes the live state into the
  /// running sequencer so per-frame correction starts (or stops) at
  /// the next exposure. Callers that don't have the dimensions yet
  /// (e.g. a settings-screen-level toggle with no camera connected)
  /// can omit those parameters; the sequencer is then updated on the
  /// next camera connect via [pushCurrentSettingsToSequencer].
  Future<void> setApplyDuringCapture({
    required String cameraId,
    required bool apply,
    int? width,
    int? height,
    double? sensorTemperatureCelsius,
  }) async {
    final generation = ++_applyGeneration;
    final authorityGeneration = _authorityGeneration;
    final authority = ref.read(backendProvider);
    try {
      final canPush =
          width != null && height != null && sensorTemperatureCelsius != null;
      final settings = ref.read(defectMapSettingsProvider);
      if (apply && canPush) {
        final status = await _service.getStatus(
          cameraId: cameraId,
          width: width,
          height: height,
          sensorTemperatureCelsius: sensorTemperatureCelsius,
        );
        if (status?.storedOnDisk != true) {
          throw StateError(
            'No defect map exists for the current camera, sensor size, and '
            'temperature bucket.',
          );
        }

        // Enabling is two-phase: validate first, persist the preference, then
        // load the exact map into the runtime. If the live load fails, roll the
        // preference back so a later map build cannot unexpectedly activate a
        // toggle the operator saw fail.
        await _service.apply(cameraId: cameraId, applyDuringCapture: true);
        try {
          await _service.applyToSequencer(
            cameraId: cameraId,
            width: width,
            height: height,
            sensorTemperatureCelsius: sensorTemperatureCelsius,
            enabled: true,
            method: settings.method,
            kernel: settings.kernel,
            saveOriginal: settings.saveOriginal,
          );
        } catch (error, stackTrace) {
          try {
            await _service.apply(cameraId: cameraId, applyDuringCapture: false);
          } catch (rollbackError, rollbackStack) {
            developer.log(
              'Could not roll back defect-map preference: $rollbackError',
              name: 'DefectMap',
              level: 1000,
              error: rollbackError,
              stackTrace: rollbackStack,
            );
          }
          try {
            await _service.applyToSequencer(
              cameraId: cameraId,
              width: width,
              height: height,
              sensorTemperatureCelsius: sensorTemperatureCelsius,
              enabled: false,
              method: settings.method,
              kernel: settings.kernel,
              saveOriginal: settings.saveOriginal,
            );
          } catch (_) {
            // The original runtime-load error remains the actionable failure.
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      } else if (!apply && canPush) {
        // Disable the live runtime first. If persistence subsequently fails,
        // correction is still safely off for the current run and the visible
        // preference remains on so the operator can retry.
        await _service.applyToSequencer(
          cameraId: cameraId,
          width: width,
          height: height,
          sensorTemperatureCelsius: sensorTemperatureCelsius,
          enabled: false,
          method: settings.method,
          kernel: settings.kernel,
          saveOriginal: settings.saveOriginal,
        );
        await _service.apply(cameraId: cameraId, applyDuringCapture: false);
      } else {
        await _service.apply(cameraId: cameraId, applyDuringCapture: apply);
      }
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
        errorMessage: 'Failed to update defect-map toggle: $e',
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
        errorMessage: 'Failed to push defect-map settings to sequencer: $e',
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
        errorMessage: 'Failed to clear defect map: $e',
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
        identical(ref.read(backendProvider), authority);
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

/// Settings keys used by the defect-map subsystem. Centralised here so
/// the test suite + the bridge can match against the same strings.
class DefectMapSettingsKeys {
  static const String autoApply = 'defectMap.autoApply';
  static const String method = 'defectMap.method';
  static const String kernel = 'defectMap.kernelDiameter';
  static const String saveOriginal = 'defectMap.saveOriginal';

  DefectMapSettingsKeys._();
}

/// StateNotifier managing [DefectMapSettings]. Loads from the
/// `app_settings` table on construction; persists each setter.
class DefectMapSettingsNotifier extends StateNotifier<DefectMapSettings> {
  final Ref _ref;
  final NetworkBackend? _remote;
  ProviderSubscription? _settingsSub;
  StreamSubscription? _remoteEventSub;
  Future<void>? _remoteLoad;
  final Completer<void> _loadedCompleter = Completer<void>();

  DefectMapSettingsNotifier(this._ref, {NetworkBackend? remote})
    : _remote = remote,
      super(const DefectMapSettings(isLoading: true)) {
    if (remote != null) {
      _remoteEventSub = remote.eventStream.listen(
        (event) {
          if (event.eventType != hostStateChangedEventType ||
              event.data['entityType'] != HostMutationEntity.settings ||
              event.data['namespace'] != 'defect-map') {
            return;
          }
          _remoteLoad = _loadRemote(showLoading: false);
        },
        onError: (Object error, StackTrace stackTrace) {
          developer.log(
            'Defect-map settings event stream failed: $error',
            name: 'DefectMapSettings',
            level: 1000,
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
    state = DefectMapSettings(
      autoApply: kv[DefectMapSettingsKeys.autoApply] == 'true',
      method: DefectMapMethod.fromWire(kv[DefectMapSettingsKeys.method]),
      kernel: DefectMapKernelSize.fromDiameter(
        int.tryParse(kv[DefectMapSettingsKeys.kernel] ?? '') ?? 3,
      ),
      saveOriginal: kv[DefectMapSettingsKeys.saveOriginal] == 'true',
      isLoading: false,
      loadError: null,
    );
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
      developer.log(
        'Could not load defect-map settings from imaging host: $error',
        name: 'DefectMapSettings',
        level: 1000,
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
    await _saveLocal(DefectMapSettingsKeys.autoApply, value.toString());
    state = state.copyWith(autoApply: value, loadError: null);
  }

  Future<void> setMethod(DefectMapMethod value) async {
    if (_remote != null) {
      await _saveRemote({
        'method': value.wireValue,
      }, (current) => current.copyWith(method: value));
      return;
    }
    await _saveLocal(DefectMapSettingsKeys.method, value.wireValue);
    state = state.copyWith(method: value, loadError: null);
  }

  Future<void> setKernel(DefectMapKernelSize value) async {
    if (_remote != null) {
      await _saveRemote({
        'kernelDiameter': value.diameter,
      }, (current) => current.copyWith(kernel: value));
      return;
    }
    await _saveLocal(DefectMapSettingsKeys.kernel, value.diameter.toString());
    state = state.copyWith(kernel: value, loadError: null);
  }

  Future<void> setSaveOriginal(bool value) async {
    if (_remote != null) {
      await _saveRemote({
        'saveOriginal': value,
      }, (current) => current.copyWith(saveOriginal: value));
      return;
    }
    await _saveLocal(DefectMapSettingsKeys.saveOriginal, value.toString());
    state = state.copyWith(saveOriginal: value, loadError: null);
  }

  Future<void> _saveLocal(String key, String value) {
    return _ref.read(settingsDaoProvider).setSetting(key, value);
  }

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

/// Provider for the defect-map settings notifier.
final defectMapSettingsProvider =
    StateNotifierProvider<DefectMapSettingsNotifier, DefectMapSettings>((ref) {
      final backend = ref.watch(backendProvider);
      return DefectMapSettingsNotifier(
        ref,
        remote: backend is NetworkBackend ? backend : null,
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
