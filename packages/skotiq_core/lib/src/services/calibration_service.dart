import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:path/path.dart' as path;

import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../models/backend/host_mutation_event.dart';
import '../providers/backend_provider.dart';
import '../providers/dark_library_provider.dart';
import '../services/dark_library_service.dart';
import '../services/logging_service.dart';
import '../providers/database_provider.dart';

/// Sentinel object used by [CalibrationSettings.copyWith] to distinguish
/// "parameter not passed" from an explicit `null`.
const Object _sentinel = Object();

/// Settings for how calibration is applied.
class CalibrationSettings {
  /// Whether to auto-calibrate captured light frames.
  final bool autoCalibrate;

  /// Path to a master flat file (null = skip flat correction).
  final String? masterFlatPath;

  /// Path to a master bias file (null = skip bias correction).
  final String? masterBiasPath;

  /// Whether to auto-find darks from the dark library.
  final bool autoDarkFromLibrary;

  /// Manual dark path override (used if [autoDarkFromLibrary] is false).
  final String? manualDarkPath;

  /// True while a remote controller is loading the imaging host's snapshot.
  /// Local/host settings are fed by the Drift stream and never use this flag.
  final bool isLoading;

  /// The last remote snapshot error. Keeping it in the state prevents a
  /// disconnected phone from presenting default values as the host's truth.
  final Object? loadError;

  const CalibrationSettings({
    this.autoCalibrate = false,
    this.masterFlatPath,
    this.masterBiasPath,
    this.autoDarkFromLibrary = true,
    this.manualDarkPath,
    this.isLoading = false,
    this.loadError,
  });

  /// Returns a copy with the given fields replaced.
  ///
  /// For nullable String fields, pass an empty string to explicitly clear them.
  CalibrationSettings copyWith({
    bool? autoCalibrate,
    Object? masterFlatPath = _sentinel,
    Object? masterBiasPath = _sentinel,
    bool? autoDarkFromLibrary,
    Object? manualDarkPath = _sentinel,
    bool? isLoading,
    Object? loadError = _sentinel,
  }) {
    return CalibrationSettings(
      autoCalibrate: autoCalibrate ?? this.autoCalibrate,
      masterFlatPath: masterFlatPath == _sentinel
          ? this.masterFlatPath
          : masterFlatPath as String?,
      masterBiasPath: masterBiasPath == _sentinel
          ? this.masterBiasPath
          : masterBiasPath as String?,
      autoDarkFromLibrary: autoDarkFromLibrary ?? this.autoDarkFromLibrary,
      manualDarkPath: manualDarkPath == _sentinel
          ? this.manualDarkPath
          : manualDarkPath as String?,
      isLoading: isLoading ?? this.isLoading,
      loadError: loadError == _sentinel ? this.loadError : loadError,
    );
  }

  /// Strictly decode the complete host snapshot returned by
  /// `GET /api/calibration/settings`.
  factory CalibrationSettings.fromRemoteJson(Map<String, dynamic> json) {
    final autoCalibrate = json['autoCalibrate'];
    final autoDarkFromLibrary = json['autoDarkFromLibrary'];
    if (autoCalibrate is! bool || autoDarkFromLibrary is! bool) {
      throw const FormatException(
        'Malformed calibration settings from imaging host',
      );
    }

    String? nullablePath(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('Malformed calibration path "$key"');
      }
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return CalibrationSettings(
      autoCalibrate: autoCalibrate,
      masterFlatPath: nullablePath('masterFlatPath'),
      masterBiasPath: nullablePath('masterBiasPath'),
      autoDarkFromLibrary: autoDarkFromLibrary,
      manualDarkPath: nullablePath('manualDarkPath'),
    );
  }
}

/// Result of a calibration operation.
class CalibrationResult {
  /// Path to the calibrated output file.
  final String outputPath;

  /// Whether a dark frame was applied.
  final bool darkApplied;

  /// Whether a flat frame was applied.
  final bool flatApplied;

  /// Whether a bias frame was applied.
  final bool biasApplied;

  /// Path of the dark used, if any.
  final String? darkUsed;

  /// Path of the flat used, if any.
  final String? flatUsed;

  /// Path of the bias used, if any.
  final String? biasUsed;

  const CalibrationResult({
    required this.outputPath,
    required this.darkApplied,
    required this.flatApplied,
    required this.biasApplied,
    this.darkUsed,
    this.flatUsed,
    this.biasUsed,
  });
}

/// Service for calibrating captured astrophotography images.
///
/// Integrates with the dark frame library for auto-matching and wraps
/// the native Rust calibration pipeline (dark subtraction, flat division,
/// bias correction) via the FFI bridge.
class CalibrationService {
  final Ref _ref;
  final SkotiqBackend _backend;
  final BackendNotifier _backendNotifier;
  final LoggingService _logger;
  bool _retired = false;

  CalibrationService(Ref ref, {SkotiqBackend? backend})
    : _ref = ref,
      _backend = backend ?? ref.read(backendProvider),
      _backendNotifier = ref.read(backendProvider.notifier),
      _logger = ref.read(loggingServiceProvider);

  DarkLibraryService get _darkLibrary => _ref.read(darkLibraryServiceProvider);

  bool get _hasAuthority =>
      !_retired && _backendNotifier.isCurrentBackend(_backend);

  void retire() => _retired = true;

  void _ensureAuthority() {
    if (_hasAuthority) return;
    throw StateError(
      'The imaging host changed while calibration was in progress. The '
      'outgoing result was discarded; calibrate the frame again on the '
      'current host.',
    );
  }

  /// Calibrate a light frame file using the provided settings.
  ///
  /// If [settings.autoDarkFromLibrary] is true, the best-matching dark
  /// will be found from the dark library based on the light frame's
  /// exposure parameters.
  ///
  /// The calibrated image is saved to [outputPath]. If [outputPath] is null,
  /// a sibling `*_cal` file is generated and the original light frame is
  /// preserved (with a `.uncal` backup created once for recovery).
  Future<CalibrationResult> calibrateFile({
    required String lightPath,
    required CalibrationSettings settings,
    String? outputPath,
    double? exposureTime,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    double? sensorTemperature,
  }) async {
    _ensureAuthority();
    _logger.info('Calibrating: $lightPath', source: 'CalibrationService');

    final backend = _backend;
    final isRemote = backend is NetworkBackend;

    // Determine dark frame path. A manual override always wins; the library
    // auto-match only runs when no manual dark was supplied.
    String? darkPath = settings.manualDarkPath;
    if (settings.autoDarkFromLibrary &&
        darkPath == null &&
        exposureTime != null &&
        gain != null) {
      if (backend is NetworkBackend) {
        // Remote: the dark library lives on the host, so the client can't
        // run the matcher itself. Ask the host to match and hand back the
        // dark's on-host path. The path is fed to `calibrateImageFile`,
        // which reads it host-side. The host applies the same unified
        // tolerances the local path and coverage UI consult.
        final matchedHostPath = await backend.matchDarkFromLibrary(
          exposureTime: exposureTime,
          gain: gain,
          offset: offset ?? 0,
          binX: binX,
          binY: binY,
          temperature: sensorTemperature,
        );
        _ensureAuthority();
        if (matchedHostPath != null) {
          darkPath = matchedHostPath;
          _logger.info(
            'Auto-matched dark on host: $matchedHostPath',
            source: 'CalibrationService',
          );
        } else {
          _logger.info(
            'No matching dark found in host library',
            source: 'CalibrationService',
          );
        }
      } else {
        // Local: match directly against the on-disk dark library. Route
        // through the unified tolerances provider so the runtime matcher
        // and the coverage UI agree on what counts as a matching dark.
        final tolerances = _ref.read(darkLibraryMatchTolerancesProvider);
        final matchingDark = await _darkLibrary.findMatchingDark(
          exposureTime: exposureTime,
          gain: gain,
          offset: offset ?? 0,
          binX: binX,
          binY: binY,
          temperature: sensorTemperature,
          tolerances: tolerances,
        );
        _ensureAuthority();
        if (matchingDark != null) {
          darkPath = matchingDark.filePath;
          _logger.info(
            'Auto-matched dark: ${matchingDark.filePath} '
            '(exposure=${matchingDark.exposureTime}s, '
            'temp=${matchingDark.temperature}C)',
            source: 'CalibrationService',
          );
        } else {
          _logger.info(
            'No matching dark found in library',
            source: 'CalibrationService',
          );
        }
      }
    }

    // Determine flat and bias paths
    final flatPath = settings.masterFlatPath;
    final biasPath = settings.masterBiasPath;

    // Validate that at least one calibration frame is provided
    if (darkPath == null && flatPath == null && biasPath == null) {
      throw StateError(
        'No calibration frames available. '
        'Provide a dark, flat, or bias frame.',
      );
    }

    // Validate files exist (local filesystem only — remote paths are
    // validated on the headless host inside POST /api/imaging/calibrate-file).
    if (!isRemote) {
      _ensureAuthority();
      if (darkPath != null && !File(darkPath).existsSync()) {
        throw FileSystemException('Dark frame file not found', darkPath);
      }
      if (flatPath != null && !File(flatPath).existsSync()) {
        throw FileSystemException('Flat frame file not found', flatPath);
      }
      if (biasPath != null && !File(biasPath).existsSync()) {
        throw FileSystemException('Bias frame file not found', biasPath);
      }
    }

    // Determine output path
    final effectiveOutputPath = outputPath ?? _generateCalOutputPath(lightPath);

    if (!isRemote) {
      // Ensure output directory exists
      final outDir = Directory(path.dirname(effectiveOutputPath));
      if (!outDir.existsSync()) {
        outDir.createSync(recursive: true);
      }

      // If overwriting in place, back up original
      if (outputPath == null) {
        final backupPath = '$lightPath.uncal';
        if (!File(backupPath).existsSync()) {
          await File(lightPath).copy(backupPath);
          _ensureAuthority();
          _logger.info(
            'Backed up original to: $backupPath',
            source: 'CalibrationService',
          );
        }
      }
    }

    _ensureAuthority();
    await backend.calibrateImageFile(
      lightPath: lightPath,
      darkPath: darkPath,
      flatPath: flatPath,
      biasPath: biasPath,
      outputPath: effectiveOutputPath,
    );
    _ensureAuthority();

    _logger.info(
      'Calibration complete: $effectiveOutputPath '
      '(dark=${darkPath != null}, flat=${flatPath != null}, '
      'bias=${biasPath != null})',
      source: 'CalibrationService',
    );

    return CalibrationResult(
      outputPath: effectiveOutputPath,
      darkApplied: darkPath != null,
      flatApplied: flatPath != null,
      biasApplied: biasPath != null,
      darkUsed: darkPath,
      flatUsed: flatPath,
      biasUsed: biasPath,
    );
  }

  /// Calibrate raw pixel data in memory.
  ///
  /// Takes u16 pixel data directly and returns calibrated u16 pixel data.
  /// This is useful for live preview calibration without disk I/O.
  Uint16List calibrateData({
    required int width,
    required int height,
    required List<int> lightData,
    Uint16List? darkData,
    Uint16List? flatData,
    Uint16List? biasData,
  }) {
    if (darkData == null && flatData == null && biasData == null) {
      return Uint16List.fromList(lightData);
    }

    return bridge.apiCalibrateImageData(
      width: width,
      height: height,
      lightData: lightData,
      darkData: darkData,
      flatData: flatData,
      biasData: biasData,
    );
  }

  /// Generate a calibrated output path from a light frame path.
  ///
  /// Adds "_cal" suffix before the extension:
  ///   "image_001.fits" -> "image_001_cal.fits"
  String _generateCalOutputPath(String lightPath) {
    final dir = path.dirname(lightPath);
    final ext = path.extension(lightPath);
    final baseName = path.basenameWithoutExtension(lightPath);
    return path.join(dir, '${baseName}_cal$ext');
  }
}

/// Provider for the CalibrationService.
final calibrationServiceProvider = Provider<CalibrationService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = CalibrationService(ref, backend: backend);
  ref.onDispose(service.retire);
  return service;
});

/// Provider for calibration settings, loaded from app settings.
final calibrationSettingsProvider =
    StateNotifierProvider<CalibrationSettingsNotifier, CalibrationSettings>((
      ref,
    ) {
      final backend = ref.watch(backendProvider);
      return CalibrationSettingsNotifier(
        ref,
        remote: backend is NetworkBackend ? backend : null,
      );
    });

/// Manages calibration settings with persistence via app settings.
class CalibrationSettingsNotifier extends StateNotifier<CalibrationSettings> {
  final Ref _ref;
  final NetworkBackend? _remote;

  ProviderSubscription? _settingsSub;
  StreamSubscription? _remoteEventSub;
  Future<void>? _remoteLoad;

  CalibrationSettingsNotifier(this._ref, {NetworkBackend? remote})
    : _remote = remote,
      super(
        remote == null
            ? const CalibrationSettings()
            : const CalibrationSettings(isLoading: true),
      ) {
    if (remote != null) {
      _remoteEventSub = remote.eventStream.listen(
        (event) {
          if (event.eventType != hostStateChangedEventType ||
              event.data['entityType'] != HostMutationEntity.settings ||
              event.data['namespace'] != 'calibration') {
            return;
          }
          _remoteLoad = _loadRemote(showLoading: false);
        },
        onError: (Object error, StackTrace stackTrace) {
          developer.log(
            'Calibration settings event stream failed: $error',
            name: 'CalibrationSettings',
            level: 1000,
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
      _remoteLoad = _loadRemote(showLoading: true);
      return;
    }

    // Why: `allSettingsProvider` is async; the first read on construction
    // is typically `AsyncLoading` and `whenData` short-circuits. Use
    // `_ref.listen` so we react as the settings stream resolves and on
    // any subsequent invalidation. The subscription is closed when the
    // notifier disposes.
    _settingsSub = _ref.listen<AsyncValue<Map<String, String>>>(
      allSettingsProvider,
      (_, next) => next.whenData(_applyLoadedSettings),
      fireImmediately: true,
    );
  }

  void _applyLoadedSettings(Map<String, String> settings) {
    // `calibration.auto_calibrate` is the authoritative key for both the
    // dark-library UI and the imaging pipeline. A value left in the legacy
    // `dark_library.auto_subtract` key is lifted forward when the
    // authoritative key is unset, then deleted, so the lift runs once.
    var autoCalibrate = settings['calibration.auto_calibrate'] == 'true';
    final legacyDarkLibrary = settings['dark_library.auto_subtract'];
    final hasCalibrationKey = settings.containsKey(
      'calibration.auto_calibrate',
    );
    if (!hasCalibrationKey && legacyDarkLibrary != null) {
      autoCalibrate = legacyDarkLibrary == 'true';
      // Persist the migrated value into the canonical store; clear the
      // legacy key so subsequent loads don't re-trigger the migration.
      unawaited(_migrateLegacyAutoSubtract(autoCalibrate));
    }
    state = CalibrationSettings(
      autoCalibrate: autoCalibrate,
      masterFlatPath: _nonEmpty(settings['calibration.master_flat_path']),
      masterBiasPath: _nonEmpty(settings['calibration.master_bias_path']),
      autoDarkFromLibrary:
          settings['calibration.auto_dark_from_library'] != 'false',
      manualDarkPath: _nonEmpty(settings['calibration.manual_dark_path']),
      isLoading: false,
      loadError: null,
    );
  }

  Future<void> _loadRemote({required bool showLoading}) async {
    final remote = _remote!;
    if (showLoading) {
      state = state.copyWith(isLoading: true, loadError: null);
    }
    try {
      final snapshot = CalibrationSettings.fromRemoteJson(
        await remote.getCalibrationSettings(),
      );
      if (!mounted) return;
      state = snapshot;
    } catch (error, stackTrace) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, loadError: error);
      developer.log(
        'Could not load calibration settings from imaging host: $error',
        name: 'CalibrationSettings',
        level: 1000,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void dispose() {
    _settingsSub?.close();
    unawaited(_remoteEventSub?.cancel());
    super.dispose();
  }

  Future<void> _migrateLegacyAutoSubtract(bool value) async {
    final dao = _ref.read(settingsDaoProvider);
    await dao.setSetting('calibration.auto_calibrate', value.toString());
    await dao.deleteSetting('dark_library.auto_subtract');
  }

  /// Returns the string if non-null and non-empty, otherwise null.
  static String? _nonEmpty(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> setAutoCalibrate(bool enabled) async {
    if (_remote != null) {
      await _saveRemote({
        'autoCalibrate': enabled,
      }, (current) => current.copyWith(autoCalibrate: enabled));
      return;
    }
    final next = state.copyWith(autoCalibrate: enabled);
    state = next;
    await _saveSetting('calibration.auto_calibrate', enabled.toString());
  }

  Future<void> setMasterFlatPath(String? path) async {
    if (_remote != null) {
      await _saveRemote({
        'masterFlatPath': path,
      }, (current) => current.copyWith(masterFlatPath: path));
      return;
    }
    final next = state.copyWith(masterFlatPath: path);
    state = next;
    await _saveSetting('calibration.master_flat_path', path ?? '');
  }

  Future<void> setMasterBiasPath(String? path) async {
    if (_remote != null) {
      await _saveRemote({
        'masterBiasPath': path,
      }, (current) => current.copyWith(masterBiasPath: path));
      return;
    }
    final next = state.copyWith(masterBiasPath: path);
    state = next;
    await _saveSetting('calibration.master_bias_path', path ?? '');
  }

  Future<void> setAutoDarkFromLibrary(bool enabled) async {
    if (_remote != null) {
      await _saveRemote({
        'autoDarkFromLibrary': enabled,
      }, (current) => current.copyWith(autoDarkFromLibrary: enabled));
      return;
    }
    final next = state.copyWith(autoDarkFromLibrary: enabled);
    state = next;
    await _saveSetting(
      'calibration.auto_dark_from_library',
      enabled.toString(),
    );
  }

  Future<void> setManualDarkPath(String? path) async {
    if (_remote != null) {
      await _saveRemote({
        'manualDarkPath': path,
      }, (current) => current.copyWith(manualDarkPath: path));
      return;
    }
    final next = state.copyWith(manualDarkPath: path);
    state = next;
    await _saveSetting('calibration.manual_dark_path', path ?? '');
  }

  Future<void> _saveRemote(
    Map<String, dynamic> patch,
    CalibrationSettings Function(CalibrationSettings current) applyPatch,
  ) async {
    await _remoteLoad;
    final loadError = state.loadError;
    if (loadError != null) {
      throw StateError(
        'Calibration settings are unavailable from the imaging host: '
        '$loadError',
      );
    }
    await _remote!.updateCalibrationSettings(patch);
    if (!mounted) return;
    state = applyPatch(state).copyWith(isLoading: false, loadError: null);
  }

  Future<void> _saveSetting(String key, String value) async {
    final dao = _ref.read(settingsDaoProvider);
    await dao.setSetting(key, value);
  }
}
