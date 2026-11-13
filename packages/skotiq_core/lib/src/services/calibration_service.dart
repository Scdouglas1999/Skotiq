import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:path/path.dart' as path;

import '../backend/skotiq_backend.dart';
import '../models/backend/host_mutation_event.dart';
import '../models/imaging/frame_files.dart';
import '../providers/async_scope.dart';
import '../providers/dark_library_provider.dart';
import '../services/calibration/dark_selection.dart';
import '../services/dark_library_service.dart';
import '../services/logging_service.dart';
import '../settings/setting.dart';
import '../settings/store_settings.dart';
import '../utils/host_paths.dart';
import '../providers/database_provider.dart';
import '../backend/roles/host_data/host_calibration_tools.dart';
import '../database/daos/settings_dao.dart';
import '../providers/logging_service_provider.dart';

/// Sentinel object used by [CalibrationSettings.copyWith] to distinguish
/// "parameter not passed" from an explicit `null`.
const Object _sentinel = Object();

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

  /// What the stored [rows] hold.
  factory CalibrationSettings.fromRows(Map<String, String> rows) =>
      CalibrationSettings(
        autoCalibrate: StoreSettings.calibrationAutoCalibrate.valueIn(rows),
        masterFlatPath: StoreSettings.calibrationMasterFlatPath.valueIn(rows),
        masterBiasPath: StoreSettings.calibrationMasterBiasPath.valueIn(rows),
        autoDarkFromLibrary: StoreSettings.calibrationAutoDarkFromLibrary
            .valueIn(rows),
        manualDarkPath: StoreSettings.calibrationManualDarkPath.valueIn(rows),
      );

  /// The snapshot `GET /api/calibration/settings` returns.
  Map<String, dynamic> toRemoteJson() => {
    'autoCalibrate': autoCalibrate,
    'masterFlatPath': masterFlatPath,
    'masterBiasPath': masterBiasPath,
    'autoDarkFromLibrary': autoDarkFromLibrary,
    'manualDarkPath': manualDarkPath,
  };

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

class CalibrationResult {
  final String outputPath;

  final bool darkApplied;

  final bool flatApplied;

  final bool biasApplied;

  final String? darkUsed;

  final String? flatUsed;

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
  final AsyncScope<SkotiqBackend> _host;
  final LoggingService _logger;

  /// The linked host's calibration, or null where the imaging host is this
  /// process and the frames are calibrated here.
  final HostCalibrationTools? _hostTools;

  CalibrationService(Ref ref, {HostCalibrationTools? hostTools})
    : _ref = ref,
      _host = ref.providerBackendScope(),
      _logger = ref.read(loggingServiceProvider),
      _hostTools = hostTools;

  DarkLibraryService get _darkLibrary => _ref.read(darkLibraryServiceProvider);

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
    _host.ensureCurrent('calibration was in progress');
    _logger.info('Calibrating: $lightPath', source: 'CalibrationService');

    final backend = _host.value;
    final host = _hostTools;
    final isRemote = host != null;

    // Determine dark frame path. A manual override always wins; the library
    // auto-match only runs when no manual dark was supplied. A null gain or
    // offset is a camera without that control, matched to darks without it.
    String? darkPath = settings.manualDarkPath;
    if (settings.autoDarkFromLibrary &&
        darkPath == null &&
        exposureTime != null) {
      if (host != null) {
        // Remote: the dark library lives on the host, so the client can't
        // run the matcher itself. Ask the host to match and hand back the
        // dark's on-host path. The path is fed to `calibrateImageFile`,
        // which reads it host-side. The host applies the same unified
        // tolerances the local path and coverage UI consult.
        final matchedHostPath = await host.matchDarkFromLibrary(
          exposureTime: exposureTime,
          gain: gain,
          offset: offset,
          binX: binX,
          binY: binY,
          temperature: sensorTemperature,
        );
        _host.ensureCurrent('calibration was in progress');
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
        final tolerances = _ref.read(darkLibraryMatchTolerancesProvider);
        final matchingDark = await _darkLibrary.findMatchingDark(
          exposureTime: exposureTime,
          gain: gain,
          offset: offset,
          binX: binX,
          binY: binY,
          temperature: sensorTemperature,
          tolerances: tolerances,
        );
        _host.ensureCurrent('calibration was in progress');
        if (matchingDark != null) {
          darkPath = matchingDark.calibrationPath;
          _logger.info(
            'Auto-matched dark: ${matchingDark.calibrationPath} '
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

    final flatPath = settings.masterFlatPath;
    final biasPath = settings.masterBiasPath;

    if (darkPath == null && flatPath == null && biasPath == null) {
      throw StateError(
        'No calibration frames available. '
        'Provide a dark, flat, or bias frame.',
      );
    }

    // Validate files exist (local filesystem only — remote paths are
    // validated on the headless host inside POST /api/imaging/calibrate-file).
    if (!isRemote) {
      _host.ensureCurrent('calibration was in progress');
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
    // A linked host's light path is in the host's path style; the `_cal`
    // sibling must be derived in that style too.
    final effectiveOutputPath =
        outputPath ??
        _generateCalOutputPath(
          lightPath,
          isRemote ? hostPathContext(lightPath) : path.context,
        );

    if (!isRemote) {
      final outDir = Directory(path.dirname(effectiveOutputPath));
      if (!outDir.existsSync()) {
        outDir.createSync(recursive: true);
      }

      // If overwriting in place, back up original
      if (outputPath == null) {
        final backupPath = '$lightPath.uncal';
        if (!File(backupPath).existsSync()) {
          await File(lightPath).copy(backupPath);
          _host.ensureCurrent('calibration was in progress');
          _logger.info(
            'Backed up original to: $backupPath',
            source: 'CalibrationService',
          );
        }
      }
    }

    _host.ensureCurrent('calibration was in progress');
    await backend.calibrateImageFile(
      lightPath: lightPath,
      darkPath: darkPath,
      flatPath: flatPath,
      biasPath: biasPath,
      outputPath: effectiveOutputPath,
    );
    _host.ensureCurrent('calibration was in progress');

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
  /// The calibrated copy keeps the light's format; a camera raw light, which
  /// Skotiq cannot write, gets a FITS copy.
  String _generateCalOutputPath(String lightPath, path.Context paths) {
    final dir = paths.dirname(lightPath);
    final ext = FrameFiles.isCameraRaw(lightPath)
        ? '.${FrameFiles.fits.first}'
        : paths.extension(lightPath);
    final baseName = paths.basenameWithoutExtension(lightPath);
    return paths.join(dir, '${baseName}_cal$ext');
  }
}

/// Manages calibration settings with persistence via app settings.
class CalibrationSettingsNotifier extends StateNotifier<CalibrationSettings> {
  final Ref _ref;
  final HostCalibrationTools? _remote;

  ProviderSubscription? _settingsSub;
  StreamSubscription? _remoteEventSub;
  Future<void>? _remoteLoad;

  CalibrationSettingsNotifier(this._ref, {HostCalibrationTools? remote})
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
          Log.error(
            'Calibration settings event stream failed: $error',
            source: 'CalibrationSettings',
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
    var loaded = CalibrationSettings.fromRows(settings);
    final legacyDarkLibrary = settings['dark_library.auto_subtract'];
    if (!settings.containsKey(StoreSettings.calibrationAutoCalibrate.key) &&
        legacyDarkLibrary != null) {
      loaded = loaded.copyWith(autoCalibrate: legacyDarkLibrary == 'true');
      // Persist the migrated value into the canonical store; clear the
      // legacy key so subsequent loads don't re-trigger the migration.
      unawaited(_migrateLegacyAutoSubtract(loaded.autoCalibrate));
    }
    state = loaded;
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
      Log.error(
        'Could not load calibration settings from imaging host: $error',
        source: 'CalibrationSettings',
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
    await dao.write(StoreSettings.calibrationAutoCalibrate, value);
    await dao.deleteSetting('dark_library.auto_subtract');
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
    await _save(StoreSettings.calibrationAutoCalibrate, enabled);
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
    await _save(StoreSettings.calibrationMasterFlatPath, path);
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
    await _save(StoreSettings.calibrationMasterBiasPath, path);
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
    await _save(StoreSettings.calibrationAutoDarkFromLibrary, enabled);
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
    await _save(StoreSettings.calibrationManualDarkPath, path);
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

  Future<void> _save<T>(Setting<T> setting, T value) =>
      _ref.read(settingsDaoProvider).write(setting, value);
}
