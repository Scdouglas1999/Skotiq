import '../database/rows/frame_type_record.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../backend/roles/host_data/calibration_library.dart';
import '../database/daos/settings_dao.dart';
import '../database/database.dart';
import '../models/calibration/calibration_library_models.dart';
import '../models/imaging/imaging_models.dart'
    show FrameType, frameFileFormatOf;
import '../models/calibration/dark_library_match_tolerances.dart';
import 'calibration/calibration_frame_groups.dart';
import 'calibration_master_builder.dart';
import 'dark_library_service.dart';
import 'flat_library_service.dart';
import 'frame_header.dart';
import '../utils/logging_service.dart';
import '../database/rows/frame_gain.dart';

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

/// The fewest frames a master is built from.
const int calibrationBacklogMinFrames = calibrationMasterMinFrames;

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
    this.setPointC,
    this.readMode,
    this.offSetPoint = const [],
    this.missingFiles = 0,
  });

  final CalibrationFrameKind kind;

  /// Evening date of the observing night, `yyyy-mm-dd`.
  final String night;
  final List<DbCapturedImage> frames;
  final double exposureSeconds;
  final int? gain;
  final int? offset;
  final int binX;
  final int binY;

  /// Filter of a flat group; null for darks and bias.
  final String? filter;

  /// The temperature the master stands for: the darks' and bias' set-point,
  /// otherwise the median sensor reading, when the frames recorded one.
  final double? temperature;

  /// The cooler set-point the darks or bias were taken at; null for flats
  /// and for a camera that was not cooling.
  final double? setPointC;
  final String? readMode;

  /// Frames of this setting whose sensor read further than the dark
  /// library's tolerance from the set-point; never built into the master.
  final List<DbCapturedImage> offSetPoint;

  /// Frames whose file is not on this computer.
  final int missingFiles;

  /// Every frame of the group, the left-out ones too, oldest first.
  List<DbCapturedImage> get _taken =>
      [...frames, ...offSetPoint]
        ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));

  DateTime get firstCapturedAt => _taken.first.capturedAt;
  DateTime get lastCapturedAt => _taken.last.capturedAt;

  /// Stable identity, used to dismiss a group and to track its build.
  String get key => [
    kind.name,
    night,
    if (kind == CalibrationFrameKind.dark) _trim(exposureSeconds),
    if (kind == CalibrationFrameKind.flat) filter ?? '',
    gain ?? '',
    offset ?? '',
    '${binX}x$binY',
    if (readMode != null) readMode!,
    if (setPointC != null)
      'sp${(setPointC! * 10).round()}'
    else if (temperature != null)
      temperature!.round(),
  ].join('|');

  /// What the master is, in a few words: "Dark 90 s", "Bias", "Flat Ha".
  String get title => switch (kind) {
    CalibrationFrameKind.dark => 'Dark ${_trim(exposureSeconds)} s',
    CalibrationFrameKind.bias => 'Bias',
    CalibrationFrameKind.flat => 'Flat ${filter ?? 'no filter'}',
  };

  /// The capture settings the master is matched on.
  String get settings => [
    if (gain != null) _taken.first.recordedGainKind.describe(gain!),
    if (offset != null) 'offset $offset',
    'bin ${binX}x$binY',
    if (readMode != null) readMode!,
    if (temperature != null) '${_trim(temperature!)} °C',
    if (kind == CalibrationFrameKind.flat) '${_trim(exposureSeconds)} s',
  ].join(' · ');

  bool get buildable =>
      missingFiles == 0 && frames.length >= calibrationBacklogMinFrames;

  /// What [offSetPoint] means for the master, for the operator; null when
  /// every frame was at the set-point.
  String? get offSetPointNote {
    if (offSetPoint.isEmpty) return null;
    final n = offSetPoint.length;
    final at = setPointC == null
        ? 'the set-point'
        : 'the ${_trim(setPointC!)} °C set-point';
    final read = '$n of ${n + frames.length} frames read too far from $at';
    return frames.length < calibrationBacklogMinFrames
        ? '$read; a master needs at least $calibrationBacklogMinFrames at it'
        : '$read and are left out of the master';
  }

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
    required CalibrationLibrary library,
    required DarkLibraryService darkLibrary,
    required FlatLibraryService flatLibrary,
    required CalibrationMasterBuild buildMaster,
    SettingsDao? settings,
    Future<bool> Function(String path)? fileExists,
    FrameHeaderReader readHeader = readFrameHeader,
    Future<double> Function()? temperatureToleranceC,
    DateTime Function()? now,
  }) : _db = db,
       _library = library,
       _darkLibrary = darkLibrary,
       _flatLibrary = flatLibrary,
       _buildMaster = buildMaster,
       _settings = settings,
       _fileExists = fileExists ?? ((path) => File(path).exists()),
       _readHeader = readHeader,
       _temperatureToleranceC =
           temperatureToleranceC ??
           (() async => DarkLibraryMatchTolerances.defaults.temperatureC),
       _now = now ?? DateTime.now;

  final SkotiqDatabase _db;
  final CalibrationLibrary _library;
  final DarkLibraryService _darkLibrary;
  final FlatLibraryService _flatLibrary;
  final CalibrationMasterBuild _buildMaster;
  final SettingsDao? _settings;
  final Future<bool> Function(String path) _fileExists;
  final FrameHeaderReader _readHeader;

  /// The dark library's temperature tolerance, the one the matcher uses.
  final Future<double> Function() _temperatureToleranceC;
  final DateTime Function() _now;

  /// Header facts by frame path; a frame file does not change once written.
  final Map<String, CalibrationFrameFacts> _facts = {};

  static const String dismissedKey = 'calibration.backlog.dismissed';
  static const scheduledFlatsKey = 'calibration.backlog.night_end_flats';

  Future<void> _selectionWrites = Future.value();

  Future<Map<String, dynamic>> _selections() async {
    final raw = await _settings?.getSetting(scheduledFlatsKey);
    return raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Approval is for these exact raw frames, not future captures with the
  /// same settings. Camera rotation and dust changes cannot be inferred.
  Future<Map<String, List<int>>> scheduledFlats() async =>
      (await _selections()).map(
        (key, value) => MapEntry(key, (value['frameIds'] as List).cast<int>()),
      );

  Future<void> _updateSelection(void Function(Map<String, dynamic>) update) {
    final result = _selectionWrites.then((_) async {
      final settings = _settings;
      if (settings == null) {
        throw StateError('Calibration settings unavailable.');
      }
      final selected = await _selections();
      update(selected);
      await settings.setSetting(scheduledFlatsKey, jsonEncode(selected));
    });
    _selectionWrites = result.catchError((Object _) {});
    return result;
  }

  Future<void> scheduleFlat(CalibrationBacklogGroup group, bool on) {
    if (group.kind != CalibrationFrameKind.flat) {
      throw const CalibrationBacklogException(
        'Only flats can be scheduled here.',
      );
    }
    return _updateSelection((selected) {
      if (on) {
        selected[group.key] = {
          'frameIds': group.frames.map((f) => f.id).toList(),
          'setup': flatSetupKey(
            group.filter,
            group.gain,
            group.offset,
            group.binX,
            group.binY,
          ),
        };
      } else {
        selected.remove(group.key);
      }
    });
  }

  Future<void> unscheduleFlat(String key) =>
      _updateSelection((selected) => selected.remove(key));

  /// Reuse only a master produced from the approved raw IDs. Matching
  /// metadata or a newer creation date do not establish that provenance.
  Future<String?> scheduledMaster(CalibrationBacklogGroup group) async {
    final entry = (await _selections())[group.key] as Map?;
    final path = entry?['masterPath'] as String?;
    if (path == null || !await _fileExists(path)) return null;
    final masters = await _library.listMasters();
    return masters.any((m) => m.filePath == path) ? path : null;
  }

  /// Resolve selected raw batches independently of metadata-based library
  /// coverage. No different batch or master can stand in for this approval.
  Future<List<CalibrationBacklogGroup>> scheduledForLights(
    List<DbCapturedImage> lights,
  ) async {
    final entries = await _selections();
    final selected = entries.map(
      (key, value) => MapEntry(key, (value['frameIds'] as List).cast<int>()),
    );
    if (selected.isEmpty) return [];
    final result = <CalibrationBacklogGroup>[];
    final rows = await (_db.select(
      _db.capturedImages,
    )..where((t) => t.frameTypeIs(FrameType.flat))).get();
    final dismissed = await dismissedKeys();
    for (final group in await groupFrames(rows)) {
      if (dismissed.contains(group.key)) continue;
      final ids =
          selected[group.key] ??
          selected.values
              .where((ids) => group.frames.any((f) => ids.contains(f.id)))
              .firstOrNull;
      if (ids == null ||
          !lights.any(
            (f) =>
                f.isAccepted &&
                f.isLight &&
                f.filter == group.filter &&
                f.gain == group.gain &&
                f.offset == group.offset &&
                f.binX == group.binX &&
                f.binY == group.binY,
          )) {
        continue;
      }
      final current = group.frames.map((f) => f.id).toSet();
      if (!selected.containsKey(group.key) ||
          ids.length != current.length ||
          !current.containsAll(ids)) {
        throw CalibrationBacklogException(
          '${group.title}: the raw batch changed. Select it again in Calibration before automatic use.',
        );
      }
      result.add(group);
    }
    for (final entry in entries.entries) {
      if (dismissed.contains(entry.key)) continue;
      if (!result.any((g) => g.key == entry.key) &&
          lights.any(
            (f) =>
                f.isAccepted &&
                f.isLight &&
                flatSetupKey(f.filter, f.gain, f.offset, f.binX, f.binY) ==
                    entry.value['setup'],
          )) {
        throw const CalibrationBacklogException(
          'A selected flat batch is no longer in the captured library. Review the Night end selections in Calibration.',
        );
      }
    }
    // Two approved optical setups with identical acquisition settings need a
    // human choice; never silently pick whichever finishes last.
    final setups = <String>{};
    for (final group in result) {
      final setup =
          '${group.filter}|${group.gain}|${group.offset}|${group.binX}x${group.binY}';
      if (!setups.add(setup)) {
        throw CalibrationBacklogException(
          '${group.title}: more than one batch is selected for the same settings. Keep only the intended batch selected in Calibration.',
        );
      }
    }
    return result;
  }

  /// Raw calibration frames waiting for a master, newest night first.
  Future<List<CalibrationBacklogGroup>> pending() async {
    final rows =
        await (_db.select(_db.capturedImages)..where(
              (t) => t.frameType.lower().isIn(const ['dark', 'bias', 'flat']),
            ))
            .get();
    if (rows.isEmpty) return const [];
    final toleranceC = await _temperatureToleranceC();
    final groups = await groupFrames(rows, toleranceC: toleranceC);
    final masters = await _library.listMasters();
    final dismissed = await dismissedKeys();
    final waiting = [
      for (final g in groups)
        if (!dismissed.contains(g.key) && !isCovered(g, masters, toleranceC)) g,
    ];
    waiting.sort((a, b) => b.lastCapturedAt.compareTo(a.lastCapturedAt));
    return waiting;
  }

  /// Group raw frames by kind, observing night and capture setting. Darks
  /// and bias follow [groupCalibrationFrames], the rule the end-of-night
  /// calibration builds its masters by; [toleranceC] defaults to the dark
  /// library's. Flats group by filter, gain, offset and binning.
  Future<List<CalibrationBacklogGroup>> groupFrames(
    List<DbCapturedImage> frames, {
    double? toleranceC,
  }) async {
    final tolerance = toleranceC ?? await _temperatureToleranceC();
    final flats = <String, List<DbCapturedImage>>{};
    final darksByNight =
        <String, List<(DbCapturedImage, CalibrationFrameFacts)>>{};
    final present = <String, bool>{};
    for (final f in frames) {
      if (CalibrationFrameKind.parse(f.frameType) == null) continue;
      present[f.filePath] = await _fileExists(f.filePath);
    }
    await _loadFacts([
      for (final f in frames)
        if (present[f.filePath] == true &&
            CalibrationFrameKind.parse(f.frameType) !=
                CalibrationFrameKind.flat)
          f.filePath,
    ]);
    for (final f in frames) {
      final kind = CalibrationFrameKind.parse(f.frameType);
      if (kind == null) continue;
      final night = observingNight(f.capturedAt);
      if (kind == CalibrationFrameKind.flat) {
        final key =
            '$night|${flatSetupKey(_filterOf(f), f.gain, f.offset, f.binX, f.binY)}';
        (flats[key] ??= []).add(f);
      } else {
        (darksByNight[night] ??= []).add((
          f,
          _facts[f.filePath] ?? const CalibrationFrameFacts(),
        ));
      }
    }
    int missingOf(List<DbCapturedImage> frames) =>
        frames.where((f) => !present[f.filePath]!).length;

    final result = <CalibrationBacklogGroup>[];
    for (final MapEntry(key: night, value: nightFrames)
        in darksByNight.entries) {
      for (final group in groupCalibrationFrames(
        nightFrames,
        toleranceC: tolerance,
      )) {
        final s = group.setting;
        final all = [...group.frames, ...group.offSetPoint];
        result.add(
          CalibrationBacklogGroup(
            kind: s.type == FrameType.bias
                ? CalibrationFrameKind.bias
                : CalibrationFrameKind.dark,
            night: night,
            frames: group.frames,
            exposureSeconds: s.exposureSecs,
            gain: s.gain,
            offset: s.offset,
            binX: s.binX,
            binY: s.binY,
            filter: null,
            temperature: group.temperatureC,
            setPointC: s.setPointC,
            readMode: s.readMode,
            offSetPoint: group.offSetPoint,
            missingFiles: missingOf(all),
          ),
        );
      }
    }
    for (final cluster in flats.values) {
      cluster.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      final first = cluster.first;
      final temps = [
        for (final f in cluster)
          if (f.sensorTemp != null) f.sensorTemp!,
      ]..sort();
      final exposures = [for (final f in cluster) f.exposureDuration]..sort();
      result.add(
        CalibrationBacklogGroup(
          kind: CalibrationFrameKind.flat,
          night: observingNight(first.capturedAt),
          frames: cluster,
          exposureSeconds: exposures[exposures.length ~/ 2],
          gain: first.gain,
          offset: first.offset,
          binX: first.binX,
          binY: first.binY,
          filter: _filterOf(first),
          temperature: temps.isEmpty ? null : temps[temps.length ~/ 2],
          missingFiles: missingOf(cluster),
        ),
      );
    }
    return result;
  }

  /// Read the set-point and read mode the headers of [paths] state into
  /// [_facts], several at a time: the first look at a long-used library reads
  /// thousands. A header that cannot be read states neither (and is logged);
  /// the native builder says why when its frame is built.
  Future<void> _loadFacts(List<String> paths) async {
    final unread = [
      for (final path in paths)
        if (!_facts.containsKey(path)) path,
    ];
    const batch = 32;
    for (var i = 0; i < unread.length; i += batch) {
      await Future.wait([
        for (final path in unread.skip(i).take(batch))
          _readHeader(path).then(
            (header) => _facts[path] = CalibrationFrameFacts.fromHeader(header),
            onError: (Object e) {
              Log.warning(
                'The header of $path could not be read, so its set-point '
                'and read mode are unknown: $e',
                source: 'CalibrationBacklog',
              );
              return _facts[path] = const CalibrationFrameFacts();
            },
          ),
      ]);
    }
  }

  /// Whether a library master already stands for [group]: same kind and
  /// capture setting, created after the group's last frame, not built off
  /// its set-point ([CalibrationMasterRecord.offSetPoint]), and for darks and
  /// bias at the group's set-point when both state one, otherwise within
  /// [toleranceC] of the group's temperature, the tolerance the matcher picks
  /// masters by.
  static bool isCovered(
    CalibrationBacklogGroup group,
    List<CalibrationMasterRecord> masters,
    double toleranceC,
  ) {
    for (final m in masters) {
      if (m.type != group.kind.masterType || !m.isMaster) continue;
      if (m.offSetPoint != null) continue;
      if (m.createdAt.isBefore(group.lastCapturedAt)) continue;
      if (group.gain != null && m.gain != group.gain) continue;
      if (group.offset != null && m.offset != group.offset) continue;
      if (m.binX != group.binX || m.binY != group.binY) continue;
      if (group.readMode != null &&
          m.readoutMode != null &&
          m.readoutMode != group.readMode) {
        continue;
      }
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
      if (group.setPointC != null && m.setPointC != null) {
        if ((group.setPointC! - m.setPointC!).abs() > 0.05) continue;
      } else if (group.kind != CalibrationFrameKind.flat &&
          group.temperature != null &&
          m.temperature != null &&
          (m.temperature! - group.temperature!).abs() > toleranceC) {
        continue;
      }
      return true;
    }
    return false;
  }

  /// Build [group]'s master and register it in the library.
  Future<CalibrationBacklogBuild> build(CalibrationBacklogGroup group) async {
    final result = await _build(group);
    if (group.kind == CalibrationFrameKind.flat && _settings != null) {
      await _updateSelection((selected) {
        final entry = selected[group.key] as Map?;
        final ids = (entry?['frameIds'] as List?)?.cast<int>();
        if (ids != null &&
            ids.length == group.frames.length &&
            group.frames.every((f) => ids.contains(f.id))) {
          entry!['masterPath'] = result.outputPath;
        }
      });
    }
    return result;
  }

  Future<CalibrationBacklogBuild> _build(CalibrationBacklogGroup group) async {
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
        'These are the settings recorded in the flats, independent of your light-frame preset. '
        'Build bias frames at these settings, or a matching ${exposureSeconds.toStringAsPrecision(4)} s dark-flat, '
        'then retry. Flats must have their pedestal removed before normalization. '
        'Selecting Night end schedules processing of these existing flats; it does not capture new flats.',
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

  /// File name of a built master.
  String masterFileName({
    required CalibrationFrameKind kind,
    required double exposureSeconds,
    required int? gain,
    required int? offset,
    required int binX,
    required double? temperature,
    required String? filter,
  }) => calibrationMasterFileName(
    kind: kind.name,
    builtAt: _now(),
    exposureSeconds: exposureSeconds,
    gain: gain,
    offset: offset,
    binX: binX,
    temperatureC: temperature,
    filter: filter,
  );

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
            fileFormat: Value(frameFileFormatOf(filePath).recordName),
            frameType: Value(FrameType.flat.record),
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

  static String? _filterOf(DbCapturedImage f) {
    final name = f.filter?.trim();
    return name == null || name.isEmpty ? null : name;
  }
}

enum CalibrationBuildPhase { queued, building, built, failed }

class CalibrationBuildStatus {
  const CalibrationBuildStatus(this.phase, {this.build, this.error});

  final CalibrationBuildPhase phase;
  final CalibrationBacklogBuild? build;
  final String? error;
}
