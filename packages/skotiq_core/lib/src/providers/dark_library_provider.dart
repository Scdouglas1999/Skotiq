import '../errors/error_text.dart';
import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/dark_library_dao.dart';
import '../database/daos/settings_dao.dart';
import '../database/database.dart';
import '../models/calibration/dark_library_match_tolerances.dart';
import 'package:skotiq_remote_protocol/wire_models.dart';
import '../services/calibration_master_builder.dart';
import '../services/calibration_service.dart';
import '../services/dark_library_service.dart';
import '../settings/store_settings.dart';
import '../utils/resilient_poll_stream.dart';
import '../backend/remote_host.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

final darkLibraryDaoProvider = Provider<DarkLibraryDao>((ref) {
  return DarkLibraryDao(ref.watch(databaseProvider));
});

final darkLibraryServiceProvider = Provider<DarkLibraryService>((ref) {
  return DarkLibraryService(
    ref.watch(darkLibraryDaoProvider),
    buildMaster: ref.watch(calibrationMasterBuildProvider),
  );
});

/// Reactive stream of all dark library entries (newest first).
///
/// On a linked client the slave's local `dark_library`
/// table is never populated — the user's darks/biases live on the master —
/// so the DAO stream would render empty. That branch polls the host's
/// `GET /api/calibration/darks` (`listDarks()`) and maps each
/// [RemoteDarkLibraryEntry] onto the local [DarkLibraryEntry] shape the
/// settings panel + coverage stats read.
final darkLibraryEntriesProvider = StreamProvider<List<DarkLibraryEntry>>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  final remote = backend.remoteHost?.calibrationFrames;
  if (remote != null) {
    return _pollRemoteDarkEntries(remote);
  }
  return ref.watch(darkLibraryDaoProvider).watchAllEntries();
});

/// Library statistics (refreshes when entries change).
///
/// On a remote client the local DAO `getStats()` reads the empty slave DB, so
/// derive the stats from the (remote-aware) entries stream instead.
final darkLibraryStatsProvider = FutureProvider<DarkLibraryStats>((ref) async {
  final backend = ref.watch(backendProvider);
  final remote = backend.remoteHost?.calibrationFrames;
  if (remote != null) {
    final entries = await ref.watch(darkLibraryEntriesProvider.future);
    return _statsFromEntries(entries);
  }
  // Depend on the entries stream so stats refresh on any change
  ref.watch(darkLibraryEntriesProvider);
  return ref.read(darkLibraryDaoProvider).getStats();
});

/// Polls the host's dark library and emits only on change, mirroring the
/// `_pollRemote` change-guard used by the canonical remote list providers in
/// `database_provider.dart`.
Stream<List<DarkLibraryEntry>> _pollRemoteDarkEntries(
  HostCalibrationFrames remote, {
  Duration interval = const Duration(seconds: 10),
}) => resilientDistinctPoll(
  fetch: () => _fetchRemoteDarkEntries(remote),
  unchanged: listEquals,
  interval: interval,
  onRetainedError: (error, stackTrace) {
    developer.log(
      'Remote dark-library poll failed; retaining last value',
      name: 'DarkLibraryProvider',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  },
);

Future<List<DarkLibraryEntry>> _fetchRemoteDarkEntries(
  HostCalibrationFrames remote,
) async {
  // listDarks() with no filter returns both darks and biases (frameType
  // carried on each row). Order newest-first to match `watchAllEntries()`.
  final rows = await remote.listDarks();
  final mapped = rows.map(_darkEntryFromRemote).toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return mapped;
}

DarkLibraryEntry _darkEntryFromRemote(RemoteDarkLibraryEntry row) {
  return DarkLibraryEntry(
    id: row.id,
    filePath: row.filePath,
    exposureTime: row.exposureDuration,
    temperature: row.sensorTempC,
    gain: row.gain,
    offset: row.offset,
    binX: row.binX,
    binY: row.binY,
    frameType: row.frameType,
    width: row.width,
    height: row.height,
    masterDarkPath: row.masterPath,
    masterFrameCount: row.frameCount,
    createdAt: row.createdAt,
  );
}

/// Reconstructs [DarkLibraryStats] from a flat entry list so the remote
/// (host-polled) path produces the same counts the local DAO would.
DarkLibraryStats _statsFromEntries(List<DarkLibraryEntry> entries) {
  var darkCount = 0;
  var biasCount = 0;
  var masterCount = 0;
  for (final e in entries) {
    if (e.frameType == 'bias') {
      biasCount++;
    } else {
      darkCount++;
    }
    if (e.masterDarkPath != null) masterCount++;
  }
  return DarkLibraryStats(
    totalEntries: entries.length,
    darkCount: darkCount,
    biasCount: biasCount,
    masterCount: masterCount,
  );
}

/// Unified tolerances for dark-frame matching.
///
/// This is the SINGLE source of truth that both the coverage UI
/// (`DarkLibraryCoverageService.evaluate`) and the runtime calibration
/// matcher (`DarkLibraryDao.findBestMatch` via `DarkLibraryService`) must
/// consult so the green "all darks present" badge can never contradict
/// `findMatchingDark` returning null.
///
/// A stored tolerance that is not a number, or is negative, throws rather
/// than being clamped or read as the default: a tolerance other than the one
/// the operator stored silently changes which darks match.
final darkLibraryMatchTolerancesProvider = Provider<DarkLibraryMatchTolerances>(
  (ref) {
    final settings = ref.watch(allSettingsProvider);
    return settings.when(
      data: (rows) => DarkLibraryMatchTolerances.validated(
        exposureSecs: StoreSettings.darkExposureTolerance.decodeStrict(
          rows[StoreSettings.darkExposureTolerance.key],
        ),
        temperatureC: StoreSettings.darkTemperatureTolerance.decodeStrict(
          rows[StoreSettings.darkTemperatureTolerance.key],
        ),
      ),
      loading: () => DarkLibraryMatchTolerances.defaults,
      error: (_, __) => DarkLibraryMatchTolerances.defaults,
    );
  },
);

class DarkLibrarySettingsSnapshot {
  final bool autoCalibrate;
  final double temperatureTolerance;

  const DarkLibrarySettingsSnapshot({
    required this.autoCalibrate,
    required this.temperatureTolerance,
  });

  factory DarkLibrarySettingsSnapshot.fromJson(Map<String, dynamic> json) {
    final autoCalibrate = json['autoCalibrate'];
    final temperature = (json['temperatureTolerance'] as num?)?.toDouble();
    if (autoCalibrate is! bool ||
        temperature == null ||
        !temperature.isFinite ||
        temperature < 0 ||
        temperature > 20) {
      throw const FormatException(
        'Malformed dark-library settings from imaging host',
      );
    }
    return DarkLibrarySettingsSnapshot(
      autoCalibrate: autoCalibrate,
      temperatureTolerance: temperature,
    );
  }

  /// What the stored [rows] hold.
  factory DarkLibrarySettingsSnapshot.fromRows(Map<String, String> rows) =>
      DarkLibrarySettingsSnapshot(
        autoCalibrate: StoreSettings.calibrationAutoCalibrate.valueIn(rows),
        temperatureTolerance: StoreSettings.darkTemperatureTolerance.valueIn(
          rows,
        ),
      );

  Map<String, dynamic> toJson() => {
    'autoCalibrate': autoCalibrate,
    'temperatureTolerance': temperatureTolerance,
  };
}

final darkLibrarySettingsProvider =
    FutureProvider.autoDispose<DarkLibrarySettingsSnapshot>((ref) async {
      final backend = ref.watch(backendProvider);
      final remote = backend.remoteHost?.calibrationFrames;
      if (remote != null) {
        return DarkLibrarySettingsSnapshot.fromJson(
          await remote.getDarkLibrarySettings(),
        );
      }
      return DarkLibrarySettingsSnapshot.fromRows(
        await ref.watch(allSettingsProvider.future),
      );
    });

final darkLibrarySettingsActionsProvider = Provider((ref) {
  final backend = ref.watch(backendProvider);
  final remote = backend.remoteHost?.calibrationFrames;
  return DarkLibrarySettingsActions(
    ref,
    remote: remote,
    localCalibration: remote != null
        ? null
        : ref.read(calibrationSettingsProvider.notifier),
    localSettings: remote != null ? null : ref.read(settingsDaoProvider),
  );
});

class DarkLibrarySettingsActions {
  final Ref _ref;
  final HostCalibrationFrames? _remote;
  final CalibrationSettingsNotifier? _localCalibration;
  final SettingsDao? _localSettings;

  DarkLibrarySettingsActions(
    this._ref, {
    required HostCalibrationFrames? remote,
    required CalibrationSettingsNotifier? localCalibration,
    required SettingsDao? localSettings,
  }) : _remote = remote,
       _localCalibration = localCalibration,
       _localSettings = localSettings;

  Future<void> setAutoCalibrate(bool enabled) async {
    if (_remote != null) {
      await _remote.updateDarkLibrarySettings(autoCalibrate: enabled);
    } else {
      await _localCalibration!.setAutoCalibrate(enabled);
    }
    _ref.invalidate(darkLibrarySettingsProvider);
  }

  Future<void> setTemperatureTolerance(double value) async {
    if (!value.isFinite || value < 0 || value > 20) {
      throw ArgumentError.value(value, 'value', 'Must be between 0 and 20°C');
    }
    if (_remote != null) {
      await _remote.updateDarkLibrarySettings(temperatureTolerance: value);
    } else {
      await _localSettings!.write(
        StoreSettings.darkTemperatureTolerance,
        value,
      );
    }
    _ref.invalidate(darkLibrarySettingsProvider);
  }
}

/// StateNotifier for managing the dark library UI state.
final darkLibraryNotifierProvider =
    StateNotifierProvider<DarkLibraryNotifier, DarkLibraryUiState>((ref) {
      final backend = ref.watch(backendProvider);
      final remote = backend.remoteHost?.calibrationFrames;
      return DarkLibraryNotifier(
        ref,
        remote: remote,
        local: remote != null ? null : ref.read(darkLibraryServiceProvider),
      );
    });

/// UI state for the dark library management screen.
enum DarkLibraryMutation {
  createMaster,
  cleanOrphans,
  clearLibrary,
  deleteEntry,
  deleteGroup,
}

const _darkLibraryUnset = Object();

class DarkLibraryUiState {
  final bool isCreatingMaster;
  final DarkLibraryMutation? activeMutation;
  final String? statusMessage;
  final String? errorMessage;
  final int? selectedGroupIndex;

  const DarkLibraryUiState({
    this.isCreatingMaster = false,
    this.activeMutation,
    this.statusMessage,
    this.errorMessage,
    this.selectedGroupIndex,
  });

  bool get isBusy => activeMutation != null;

  DarkLibraryUiState copyWith({
    bool? isCreatingMaster,
    Object? activeMutation = _darkLibraryUnset,
    Object? statusMessage = _darkLibraryUnset,
    Object? errorMessage = _darkLibraryUnset,
    Object? selectedGroupIndex = _darkLibraryUnset,
  }) {
    return DarkLibraryUiState(
      isCreatingMaster: isCreatingMaster ?? this.isCreatingMaster,
      activeMutation: identical(activeMutation, _darkLibraryUnset)
          ? this.activeMutation
          : activeMutation as DarkLibraryMutation?,
      statusMessage: identical(statusMessage, _darkLibraryUnset)
          ? this.statusMessage
          : statusMessage as String?,
      errorMessage: identical(errorMessage, _darkLibraryUnset)
          ? this.errorMessage
          : errorMessage as String?,
      selectedGroupIndex: identical(selectedGroupIndex, _darkLibraryUnset)
          ? this.selectedGroupIndex
          : selectedGroupIndex as int?,
    );
  }
}

class DarkLibraryNotifier extends StateNotifier<DarkLibraryUiState> {
  final Ref ref;
  final HostCalibrationFrames? _remote;
  final DarkLibraryService? _local;

  DarkLibraryNotifier(
    this.ref, {
    required HostCalibrationFrames? remote,
    required DarkLibraryService? local,
  }) : _remote = remote,
       _local = local,
       super(const DarkLibraryUiState());

  void _refreshLibrary() {
    if (!mounted) return;
    // Entries are the canonical stream. Stats and groups watch it and rebuild
    // transitively, so invalidating all five providers would launch redundant
    // host polls after every mutation.
    ref.invalidate(darkLibraryEntriesProvider);
  }

  bool _startMutation(DarkLibraryMutation mutation, String status) {
    if (!mounted || state.isBusy) return false;
    state = state.copyWith(
      activeMutation: mutation,
      isCreatingMaster: mutation == DarkLibraryMutation.createMaster,
      statusMessage: status,
      errorMessage: null,
    );
    return true;
  }

  void _finishMutation({String? status, String? error}) {
    if (!mounted) return;
    state = state.copyWith(
      activeMutation: null,
      isCreatingMaster: false,
      statusMessage: status,
      errorMessage: error,
    );
  }

  /// Create a master dark from all raw frames matching the given parameters.
  Future<void> createMasterDark({
    required double exposureTime,
    required int gain,
    required int offset,
    required int binX,
    required int binY,
    required String outputPath,
    String frameType = 'dark',
  }) async {
    if (!_startMutation(
      DarkLibraryMutation.createMaster,
      'Finding matching frames...',
    )) {
      return;
    }

    try {
      // Null when the imaging host completed the stack but did not report how
      // many frames went into it. The count is only ever a reported number, so
      // it stays absent rather than becoming a fabricated "0 frames".
      late final int? frameCount;
      if (_remote != null) {
        final result = await _remote.createDarkLibraryMaster(
          exposureTime: exposureTime,
          gain: gain,
          offset: offset,
          binX: binX,
          binY: binY,
          outputPath: outputPath,
          frameType: frameType,
        );
        frameCount = (result['frameCount'] as num?)?.toInt();
      } else {
        final frames = await _local!.getMatchingFrames(
          exposureTime: exposureTime,
          gain: gain,
          offset: offset,
          binX: binX,
          binY: binY,
          frameType: frameType,
        );
        if (!mounted) return;

        if (frames.length < 2) {
          _finishMutation(
            error:
                'Need at least 2 matching frames to create a master dark. '
                'Found ${frames.length}.',
          );
          return;
        }

        state = state.copyWith(
          statusMessage: 'Median-combining ${frames.length} frames...',
        );

        await _local.createMasterDark(frames: frames, outputPath: outputPath);
        frameCount = frames.length;
      }

      if (!mounted) return;
      _refreshLibrary();
      _finishMutation(
        status: frameCount != null
            ? 'Master dark created from $frameCount frames.'
            : 'Master dark created.',
      );
    } catch (e) {
      _finishMutation(
        error: 'Failed to create master dark: ${userFacingError(e)}',
      );
    }
  }

  /// Clean up orphaned entries where files have been deleted from disk.
  Future<void> cleanOrphans() async {
    if (!_startMutation(
      DarkLibraryMutation.cleanOrphans,
      'Scanning for orphaned entries...',
    )) {
      return;
    }

    try {
      final removed = _remote != null
          ? await _remote.cleanDarkLibraryOrphans()
          : await _local!.cleanOrphanedEntries();
      if (!mounted) return;
      _refreshLibrary();
      _finishMutation(
        status: removed > 0
            ? 'Removed $removed orphaned entries.'
            : 'No orphaned entries found.',
      );
    } catch (e) {
      _finishMutation(error: 'Failed to clean orphans: ${userFacingError(e)}');
    }
  }

  Future<void> deleteEntry(int id, {bool deleteFile = false}) async {
    if (!_startMutation(
      DarkLibraryMutation.deleteEntry,
      'Deleting library entry...',
    )) {
      return;
    }
    try {
      if (_remote != null) {
        await _remote.deleteDark(id, deleteFile: deleteFile);
      } else {
        await _local!.deleteEntry(id, deleteFile: deleteFile);
      }
      if (!mounted) return;
      _refreshLibrary();
      _finishMutation(status: 'Entry deleted.');
    } catch (e) {
      _finishMutation(error: 'Failed to delete entry: ${userFacingError(e)}');
    }
  }

  Future<void> clearLibrary({bool deleteFiles = false}) async {
    if (!_startMutation(
      DarkLibraryMutation.clearLibrary,
      'Clearing library...',
    )) {
      return;
    }

    try {
      final removed = _remote != null
          ? await _remote.clearDarkLibrary(deleteFiles: deleteFiles)
          : await _clearLocalLibrary(deleteFiles: deleteFiles);
      if (!mounted) return;
      _refreshLibrary();
      _finishMutation(status: 'Library cleared ($removed entries removed).');
    } catch (e) {
      _finishMutation(error: 'Failed to clear library: ${userFacingError(e)}');
    }
  }

  Future<int> _clearLocalLibrary({required bool deleteFiles}) async {
    final removed = (await _local!.getAllEntries()).length;
    await _local.clearLibrary(deleteFiles: deleteFiles);
    return removed;
  }

  Future<int> deleteGroup(
    DarkGroupKey group, {
    bool deleteFiles = false,
  }) async {
    if (!_startMutation(
      DarkLibraryMutation.deleteGroup,
      'Deleting dark-library group...',
    )) {
      throw StateError('Another dark-library operation is already running');
    }
    try {
      final int removed;
      if (_remote != null) {
        removed = await _remote.deleteDarkLibraryGroup(
          exposureTime: group.exposureTime,
          gain: group.gain,
          offset: group.offset,
          binX: group.binX,
          binY: group.binY,
          frameType: group.frameType,
          deleteFiles: deleteFiles,
        );
      } else {
        final entries = await _local!.getEntriesForGroup(group);
        if (!mounted) return 0;
        await _local.deleteEntries(
          entries.map((entry) => entry.id).toList(growable: false),
          deleteFile: deleteFiles,
        );
        removed = entries.length;
      }
      if (!mounted) return removed;
      _refreshLibrary();
      _finishMutation(status: 'Deleted $removed entries.');
      return removed;
    } catch (error) {
      if (!mounted) rethrow;
      _finishMutation(
        error: 'Failed to delete group: ${userFacingError(error)}',
      );
      rethrow;
    }
  }

  void selectGroup(int? index) {
    state = state.copyWith(selectedGroupIndex: index);
  }

  void clearError() {
    state = state.copyWith(errorMessage: null);
  }

  void clearStatus() {
    state = state.copyWith(statusMessage: null);
  }
}
