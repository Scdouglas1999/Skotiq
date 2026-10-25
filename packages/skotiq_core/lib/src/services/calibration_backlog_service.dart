import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../backend/network_backend.dart';
import '../database/daos/settings_dao.dart';
import '../database/database.dart';
import '../models/calibration/calibration_library_models.dart';
import '../providers/backend_provider.dart';
import '../providers/dark_library_provider.dart';
import '../providers/database_provider.dart';
import 'calibration_library_service.dart';
import 'calibration_master_builder.dart';
import 'dark_library_service.dart';
import 'darkroom_build_service.dart'
    show darkroomTemperatureGapC, observingNight;
import 'flat_library_service.dart';

/// The kinds of raw calibration frame the backlog builds masters from.
enum CalibrationFrameKind {
  dark,
  bias,
  flat;

  CalibrationMasterType get masterType => switch (this) {
    CalibrationFrameKind.dark => CalibrationMasterType.dark,
    CalibrationFrameKind.bias => CalibrationMasterType.bias,
    CalibrationFrameKind.flat => CalibrationMasterType.flat,
  };

  static CalibrationFrameKind? parse(String frameType) =>
      switch (frameType.trim().toLowerCase()) {
        'dark' => CalibrationFrameKind.dark,
        'bias' => CalibrationFrameKind.bias,
        'flat' => CalibrationFrameKind.flat,
        _ => null,
      };
}

/// Sensor temperatures further apart than this split raw darks and bias into
/// separate masters; the same bar the Darkroom uses for lights.
const double calibrationBacklogTemperatureGapC = darkroomTemperatureGapC;

/// The fewest frames a master is built from.
const int calibrationBacklogMinFrames = 2;

/// Raw calibration frames of one kind and one capture setting, taken the same
/// night, that no master in the library covers yet.
class CalibrationBacklogGroup {
  CalibrationBacklogGroup({
    required this.kind,
    required this.night,
    required this.frames,
    required this.exposureSeconds,
    required this.gain,
    required this.offset,
    required this.binX,
    required this.binY,
    required this.filter,
    required this.temperature,
    this.missingFiles = 0,
  });

  final CalibrationFrameKind kind;

  /// Evening date of the observing night, `yyyy-mm-dd`.
  final String night;
  final List<CapturedImage> frames;
  final double exposureSeconds;
  final int? gain;
  final int? offset;
  final int binX;
  final int binY;

  /// Filter of a flat group; null for darks and bias.
  final String? filter;

  /// Median sensor temperature, when the frames recorded one.
  final double? temperature;

  /// Frames whose file is not on this computer.
  final int missingFiles;

  DateTime get firstCapturedAt => frames.first.capturedAt;
  DateTime get lastCapturedAt => frames.last.capturedAt;

  /// Stable identity, used to dismiss a group and to track its build.
  String get key => [
    kind.name,
    night,
    if (kind == CalibrationFrameKind.dark) _trim(exposureSeconds),
    if (kind == CalibrationFrameKind.flat) filter ?? '',
    gain ?? '',
    offset ?? '',
    '${binX}x$binY',
    if (temperature != null) temperature!.round(),
  ].join('|');

  /// What the master is, in a few words: "Dark 90 s", "Bias", "Flat Ha".
  String get title => switch (kind) {
    CalibrationFrameKind.dark => 'Dark ${_trim(exposureSeconds)} s',
    CalibrationFrameKind.bias => 'Bias',
    CalibrationFrameKind.flat => 'Flat ${filter ?? 'no filter'}',
  };

  /// The capture settings the master is matched on.
  String get settings => [
    if (gain != null) 'gain $gain',
    if (offset != null) 'offset $offset',
    'bin ${binX}x$binY',
    if (temperature != null) '${temperature!.round()} °C',
    if (kind == CalibrationFrameKind.flat) '${_trim(exposureSeconds)} s',
  ].join(' · ');

  bool get buildable =>
      missingFiles == 0 && frames.length >= calibrationBacklogMinFrames;

  static String _trim(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    if (v < 0.01) return v.toStringAsFixed(3);
    return v
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
}

/// A master the backlog built and registered.
class CalibrationBacklogBuild {
  const CalibrationBacklogBuild({
    required this.kind,
    required this.libraryId,
    required this.outputPath,
    required this.framesCaptured,
    required this.framesCombined,
    this.leftOut = const [],
    this.pedestalPath,
  });

  final CalibrationFrameKind kind;
  final int libraryId;
  final String outputPath;
  final int framesCaptured;
  final int framesCombined;

  /// Frames the builder left out (light leaks in darks, banded flats).
  final List<String> leftOut;

  /// The master bias or dark-flat subtracted from a flat.
  final String? pedestalPath;
}

/// Why a build cannot run; the message is written for the operator.
class CalibrationBacklogException implements Exception {
  const CalibrationBacklogException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Finds the raw calibration frames Skotiq captured (flat wizard flats,
/// end-of-night darks and bias, calibration frames a sequence took) that no
/// library master covers, and builds and registers their masters.
///
/// A group is covered when the library holds a master of the same kind and
/// capture setting created after the group's last frame: for darks the same
/// exposure, for flats the same filter, for darks and bias a temperature
/// within [calibrationBacklogTemperatureGapC]. Masters are built with the
/// native builders (winsorized sigma-clipped mean for darks and bias, the
/// unit-mean flat builder for flats) and registered in `dark_library` and
/// `flat_library`, which is where the calibration matcher, the Darkroom build
/// and live calibration look for them.
class CalibrationBacklogService {
  CalibrationBacklogService({
    required SkotiqDatabase db,
    required CalibrationLibraryService library,
    required DarkLibraryService darkLibrary,
    required FlatLibraryService flatLibrary,
    required CalibrationMasterBuild buildMaster,
    SettingsDao? settings,
    Future<bool> Function(String path)? fileExists,
    DateTime Function()? now,
  }) : _db = db,
       _library = library,
       _darkLibrary = darkLibrary,
       _flatLibrary = flatLibrary,
       _buildMaster = buildMaster,
       _settings = settings,
       _fileExists = fileExists ?? ((path) => File(path).exists()),
       _now = now ?? DateTime.now;

  final SkotiqDatabase _db;
  final CalibrationLibraryService _library;
  final DarkLibraryService _darkLibrary;
  final FlatLibraryService _flatLibrary;
  final CalibrationMasterBuild _buildMaster;
  final SettingsDao? _settings;
  final Future<bool> Function(String path) _fileExists;
  final DateTime Function() _now;

  static const String dismissedKey = 'calibration.backlog.dismissed';

  /// Raw calibration frames waiting for a master, newest night first.
  Future<List<CalibrationBacklogGroup>> pending() async {
    final rows =
        await (_db.select(_db.capturedImages)..where(
              (t) => t.frameType.lower().isIn(const ['dark', 'bias', 'flat']),
            ))
            .get();
    if (rows.isEmpty) return const [];
    final groups = await groupFrames(rows);
    final masters = await _library.listMasters();
    final dismissed = await dismissedKeys();
    final waiting = [
      for (final g in groups)
        if (!dismissed.contains(g.key) && !isCovered(g, masters)) g,
    ];
    waiting.sort((a, b) => b.lastCapturedAt.compareTo(a.lastCapturedAt));
    return waiting;
  }

  /// Group raw frames by kind, observing night and capture setting; darks
  /// and bias are further split where sensor temperatures jump.
  Future<List<CalibrationBacklogGroup>> groupFrames(
    List<CapturedImage> frames,
  ) async {
    final buckets = <String, List<CapturedImage>>{};
    for (final f in frames) {
      final kind = CalibrationFrameKind.parse(f.frameType);
      if (kind == null) continue;
      final key = [
        kind.name,
        observingNight(f.capturedAt),
        if (kind == CalibrationFrameKind.dark) f.exposureDuration,
        if (kind == CalibrationFrameKind.flat) _filterOf(f) ?? '',
        f.gain,
        f.offset,
        f.binX,
        f.binY,
      ].join('|');
      buckets.putIfAbsent(key, () => []).add(f);
    }
    final result = <CalibrationBacklogGroup>[];
    for (final bucket in buckets.values) {
      final kind = CalibrationFrameKind.parse(bucket.first.frameType)!;
      final clusters = kind == CalibrationFrameKind.flat
          ? [bucket]
          : _temperatureClusters(bucket);
      for (final cluster in clusters) {
        cluster.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
        var missing = 0;
        for (final f in cluster) {
          if (!await _fileExists(f.filePath)) missing++;
        }
        final first = cluster.first;
        final temps = [
          for (final f in cluster)
            if (f.sensorTemp != null) f.sensorTemp!,
        ]..sort();
        final exposures = [for (final f in cluster) f.exposureDuration]..sort();
        result.add(
          CalibrationBacklogGroup(
            kind: kind,
            night: observingNight(first.capturedAt),
            frames: cluster,
            exposureSeconds: exposures[exposures.length ~/ 2],
            gain: first.gain,
            offset: first.offset,
            binX: first.binX,
            binY: first.binY,
            filter: kind == CalibrationFrameKind.flat ? _filterOf(first) : null,
            temperature: temps.isEmpty ? null : temps[temps.length ~/ 2],
            missingFiles: missing,
          ),
        );
      }
    }
    return result;
  }

  /// Whether a library master already stands for [group].
  static bool isCovered(
    CalibrationBacklogGroup group,
    List<CalibrationMasterRecord> masters,
  ) {
    for (final m in masters) {
      if (m.type != group.kind.masterType || !m.isMaster) continue;
      if (m.createdAt.isBefore(group.lastCapturedAt)) continue;
      if (group.gain != null && m.gain != group.gain) continue;
      if (group.offset != null && m.offset != group.offset) continue;
      if (m.binX != group.binX || m.binY != group.binY) continue;
      switch (group.kind) {
        case CalibrationFrameKind.dark:
          final exposure = m.exposureSeconds;
          if (exposure == null ||
              (exposure - group.exposureSeconds).abs() > 0.01) {
            continue;
          }
        case CalibrationFrameKind.bias:
          break;
        case CalibrationFrameKind.flat:
          if (m.filter?.trim().toLowerCase() !=
              group.filter?.trim().toLowerCase()) {
            continue;
          }
      }
      if (group.kind != CalibrationFrameKind.flat &&
          group.temperature != null &&
          m.temperature != null &&
          (m.temperature! - group.temperature!).abs() >
              calibrationBacklogTemperatureGapC) {
        continue;
      }
      return true;
    }
    return false;
  }

  /// Build [group]'s master and register it in the library.
  Future<CalibrationBacklogBuild> build(CalibrationBacklogGroup group) async {
    if (group.missingFiles > 0) {
      throw CalibrationBacklogException(
        '${group.missingFiles} of ${group.frames.length} frames are not on '
        'this computer.',
      );
    }
    if (group.frames.length < calibrationBacklogMinFrames) {
      throw const CalibrationBacklogException(
        'A master needs at least $calibrationBacklogMinFrames frames.',
      );
    }
    final paths = [for (final f in group.frames) f.filePath];
    if (group.kind == CalibrationFrameKind.flat) {
      return buildFlat(
        paths: paths,
        filter: group.filter,
        exposureSeconds: group.exposureSeconds,
        gain: group.gain,
        offset: group.offset,
        binX: group.binX,
        binY: group.binY,
        temperature: group.temperature,
      );
    }
    final output = p.join(
      p.dirname(paths.first),
      'Masters',
      masterFileName(
        kind: group.kind,
        exposureSeconds: group.exposureSeconds,
        gain: group.gain,
        offset: group.offset,
        binX: group.binX,
        temperature: group.temperature,
        filter: null,
      ),
    );
    await Directory(p.dirname(output)).create(recursive: true);
    final built = await _buildMaster(
      CalibrationMasterBuildRequest(
        kind: group.kind.name,
        framePaths: paths,
        outputPath: output,
      ),
    );
    final id = await _darkLibrary.registerMaster(
      built,
      frameType: group.kind.name,
    );
    return CalibrationBacklogBuild(
      kind: group.kind,
      libraryId: id,
      outputPath: built.outputPath,
      framesCaptured: paths.length,
      framesCombined: built.frameCount,
      leftOut: built.leakingFrames,
    );
  }

  /// Build a master flat from [paths] and register it. The bias or dark-flat
  /// subtracted first is the library master with the flats' gain, offset and
  /// binning: a dark of the flats' exposure when there is one, else a bias.
  Future<CalibrationBacklogBuild> buildFlat({
    required List<String> paths,
    required String? filter,
    required double exposureSeconds,
    required int? gain,
    required int? offset,
    required int binX,
    required int binY,
    double? temperature,
  }) async {
    if (paths.length < calibrationBacklogMinFrames) {
      throw const CalibrationBacklogException(
        'A master flat needs at least $calibrationBacklogMinFrames frames.',
      );
    }
    final pedestal = await flatPedestal(
      exposureSeconds: exposureSeconds,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      temperature: temperature,
    );
    if (pedestal == null) {
      throw CalibrationBacklogException(
        'No master bias at ${[if (gain != null) 'gain $gain', if (offset != null) 'offset $offset', 'bin ${binX}x$binY'].join(', ')}. '
        'Build or take bias frames at these settings first; flats are '
        'bias-subtracted before they are normalized.',
      );
    }
    final output = p.join(
      p.dirname(paths.first),
      'Masters',
      masterFileName(
        kind: CalibrationFrameKind.flat,
        exposureSeconds: exposureSeconds,
        gain: gain,
        offset: offset,
        binX: binX,
        temperature: temperature,
        filter: filter,
      ),
    );
    await Directory(p.dirname(output)).create(recursive: true);
    final built = await _flatLibrary.buildMasterFlat(
      flatPaths: paths,
      outputPath: output,
      biasOrDarkFlatPath: pedestal.filePath,
      filter: filter,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      temperature: temperature,
    );
    return CalibrationBacklogBuild(
      kind: CalibrationFrameKind.flat,
      libraryId: built.libraryId,
      outputPath: built.result.outputPath,
      framesCaptured: paths.length,
      framesCombined: built.result.frameCount,
      leftOut: built.result.excluded,
      pedestalPath: pedestal.filePath,
    );
  }

  /// The master subtracted from flats of these settings, or null.
  Future<CalibrationMasterRecord?> flatPedestal({
    required double exposureSeconds,
    required int? gain,
    required int? offset,
    required int binX,
    required int binY,
    double? temperature,
  }) async {
    final matches = await _library.match(
      LightFrameContext(
        gain: gain,
        offset: offset,
        exposureSeconds: exposureSeconds,
        temperature: temperature,
        binX: binX,
        binY: binY,
      ),
      includeRemote: false,
    );
    final dark = matches.dark?.record;
    if (dark != null &&
        dark.isMaster &&
        dark.exposureSeconds != null &&
        (dark.exposureSeconds! - exposureSeconds).abs() <= 0.01) {
      return dark;
    }
    final bias = matches.bias?.record;
    if (bias != null && bias.isMaster) return bias;
    return null;
  }

  /// File name of a built master, in the end-of-night calibration's style.
  String masterFileName({
    required CalibrationFrameKind kind,
    required double exposureSeconds,
    required int? gain,
    required int? offset,
    required int binX,
    required double? temperature,
    required String? filter,
  }) {
    String trim(double v) => v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v
              .toStringAsFixed(3)
              .replaceFirst(RegExp(r'0+$'), '')
              .replaceAll('.', 'p');
    final temp = temperature == null
        ? 'notemp'
        : (temperature.round() < 0
              ? 'm${-temperature.round()}C'
              : 'p${temperature.round()}C');
    final t = _now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}'
        '${two(t.second)}';
    final head = switch (kind) {
      CalibrationFrameKind.dark => 'MasterDark_${trim(exposureSeconds)}s',
      CalibrationFrameKind.bias => 'MasterBias',
      CalibrationFrameKind.flat =>
        'MasterFlat_${(filter ?? 'NoFilter').replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}',
    };
    return '${head}_g${gain ?? 'x'}_o${offset ?? 'x'}_${temp}_bin$binX'
        '_$stamp.fits';
  }

  /// Keys of groups the operator chose not to build.
  Future<Set<String>> dismissedKeys() async {
    final raw = await _settings?.getSetting(dismissedKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      return {for (final k in jsonDecode(raw) as List) '$k'};
    } on Object {
      return <String>{};
    }
  }

  Future<void> dismiss(String key) async {
    final settings = _settings;
    if (settings == null) return;
    final keys = await dismissedKeys()
      ..add(key);
    await settings.setSetting(dismissedKey, jsonEncode(keys.toList()));
  }

  /// Record a flat the flat wizard saved, so it waits for a master like any
  /// other calibration frame Skotiq captured. Returns the new row id.
  Future<int> recordCapturedFlat({
    required String filePath,
    required double exposureSeconds,
    required DateTime capturedAt,
    String? filter,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    double? sensorTemp,
  }) {
    return _db
        .into(_db.capturedImages)
        .insert(
          CapturedImagesCompanion.insert(
            filePath: filePath,
            fileName: p.basename(filePath),
            frameType: const Value('flat'),
            exposureDuration: exposureSeconds,
            capturedAt: capturedAt,
            filter: Value(filter),
            gain: Value(gain),
            offset: Value(offset),
            binX: Value(binX),
            binY: Value(binY),
            sensorTemp: Value(sensorTemp),
          ),
        );
  }

  static String? _filterOf(CapturedImage f) {
    final name = f.filter?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  static List<List<CapturedImage>> _temperatureClusters(
    List<CapturedImage> frames,
  ) {
    final known = frames.where((f) => f.sensorTemp != null).toList()
      ..sort((a, b) => a.sensorTemp!.compareTo(b.sensorTemp!));
    final unknown = frames.where((f) => f.sensorTemp == null).toList();
    if (known.isEmpty) return [frames];
    final clusters = <List<CapturedImage>>[
      [known.first],
    ];
    for (final f in known.skip(1)) {
      if (f.sensorTemp! - clusters.last.last.sensorTemp! >
          calibrationBacklogTemperatureGapC) {
        clusters.add([f]);
      } else {
        clusters.last.add(f);
      }
    }
    clusters.sort((a, b) => b.length.compareTo(a.length));
    clusters.first.addAll(unknown);
    return clusters;
  }
}

final calibrationBacklogServiceProvider = Provider<CalibrationBacklogService>((
  ref,
) {
  return CalibrationBacklogService(
    db: ref.watch(databaseProvider),
    library: ref.watch(calibrationLibraryServiceProvider),
    darkLibrary: ref.watch(darkLibraryServiceProvider),
    flatLibrary: ref.watch(flatLibraryServiceProvider),
    buildMaster: ref.watch(calibrationMasterBuildProvider),
    settings: ref.watch(settingsDaoProvider),
  );
});

/// Bumped whenever a master is added to or removed from the calibration
/// library from this app. Panels that list or match masters watch it to
/// reload.
final calibrationLibraryRevisionProvider = StateProvider<int>((ref) => 0);

/// Progress of one backlog group's build.
enum CalibrationBuildPhase { queued, building, built, failed }

class CalibrationBuildStatus {
  const CalibrationBuildStatus(this.phase, {this.build, this.error});

  final CalibrationBuildPhase phase;
  final CalibrationBacklogBuild? build;
  final String? error;
}

/// What the Calibration tab shows about the backlog.
class CalibrationBacklogState {
  const CalibrationBacklogState({
    this.groups = const AsyncValue.loading(),
    this.builds = const {},
    this.remote = false,
  });

  final AsyncValue<List<CalibrationBacklogGroup>> groups;

  /// Build progress by [CalibrationBacklogGroup.key]. Finished builds stay
  /// here so the result reads in place after the group leaves the list.
  final Map<String, CalibrationBuildStatus> builds;

  /// This app drives a remote imaging computer, whose frames it cannot build.
  final bool remote;

  CalibrationBacklogState copyWith({
    AsyncValue<List<CalibrationBacklogGroup>>? groups,
    Map<String, CalibrationBuildStatus>? builds,
  }) => CalibrationBacklogState(
    groups: groups ?? this.groups,
    builds: builds ?? this.builds,
    remote: remote,
  );
}

/// Runs backlog builds one at a time (each holds full frames in native
/// memory) and keeps their progress across tab switches.
class CalibrationBacklogNotifier
    extends StateNotifier<CalibrationBacklogState> {
  CalibrationBacklogNotifier(this._ref, {required bool remote})
    : super(CalibrationBacklogState(remote: remote)) {
    if (remote) {
      state = state.copyWith(groups: const AsyncValue.data([]));
    } else {
      refresh();
    }
  }

  final Ref _ref;
  final List<CalibrationBacklogGroup> _queue = [];
  bool _draining = false;

  CalibrationBacklogService get _service =>
      _ref.read(calibrationBacklogServiceProvider);

  Future<void> refresh() async {
    if (state.remote) return;
    if (!state.groups.hasValue) {
      state = state.copyWith(groups: const AsyncValue.loading());
    }
    try {
      final groups = await _service.pending();
      if (!mounted) return;
      state = state.copyWith(groups: AsyncValue.data(groups));
    } catch (e, st) {
      if (!mounted) return;
      state = state.copyWith(groups: AsyncValue.error(e, st));
    }
  }

  /// Queue [group]'s build. A group already queued or building is ignored.
  void build(CalibrationBacklogGroup group) {
    final current = state.builds[group.key]?.phase;
    if (current == CalibrationBuildPhase.queued ||
        current == CalibrationBuildPhase.building) {
      return;
    }
    _queue.add(group);
    _set(group.key, const CalibrationBuildStatus(CalibrationBuildPhase.queued));
    _drain();
  }

  /// Queue every buildable group, oldest first so bias lands before the
  /// flats that need it.
  void buildAll() {
    final groups = state.groups.valueOrNull ?? const [];
    final order = [...groups.where((g) => g.buildable)]
      ..sort((a, b) {
        final rank = _kindRank(a.kind).compareTo(_kindRank(b.kind));
        return rank != 0 ? rank : a.lastCapturedAt.compareTo(b.lastCapturedAt);
      });
    for (final g in order) {
      build(g);
    }
  }

  static int _kindRank(CalibrationFrameKind kind) => switch (kind) {
    CalibrationFrameKind.bias => 0,
    CalibrationFrameKind.dark => 1,
    CalibrationFrameKind.flat => 2,
  };

  Future<void> dismiss(CalibrationBacklogGroup group) async {
    await _service.dismiss(group.key);
    await refresh();
  }

  void clearResult(String key) {
    final next = {...state.builds}..remove(key);
    state = state.copyWith(builds: next);
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && mounted) {
        final group = _queue.removeAt(0);
        _set(
          group.key,
          const CalibrationBuildStatus(CalibrationBuildPhase.building),
        );
        try {
          final built = await _service.build(group);
          if (!mounted) return;
          _set(
            group.key,
            CalibrationBuildStatus(CalibrationBuildPhase.built, build: built),
          );
          _ref.read(calibrationLibraryRevisionProvider.notifier).state++;
        } catch (e) {
          if (!mounted) return;
          _set(
            group.key,
            CalibrationBuildStatus(
              CalibrationBuildPhase.failed,
              error: e is CalibrationBacklogException ? e.message : '$e',
            ),
          );
        }
        await refresh();
      }
    } finally {
      _draining = false;
    }
  }

  void _set(String key, CalibrationBuildStatus status) {
    state = state.copyWith(builds: {...state.builds, key: status});
  }
}

final calibrationBacklogProvider =
    StateNotifierProvider<CalibrationBacklogNotifier, CalibrationBacklogState>((
      ref,
    ) {
      final remote = ref.watch(backendProvider) is NetworkBackend;
      return CalibrationBacklogNotifier(ref, remote: remote);
    });
