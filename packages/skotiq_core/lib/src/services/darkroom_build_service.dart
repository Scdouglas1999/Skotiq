import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../database/database.dart';
import '../database/daos/flat_library_dao.dart';
import '../database/daos/integrated_masters_dao.dart';
import '../models/imaging/integrated_master.dart';
import '../models/calibration/calibration_library_models.dart';
import '../providers/dark_library_provider.dart';
import 'calibration/fits_header_reader.dart';
import 'calibration_library_service.dart';
import 'calibration_master_builder.dart';
import 'dark_library_service.dart';
import 'disk_space_service.dart';
import 'darkroom_build_plan.dart';
import 'darkroom_registration_preview.dart';
export 'darkroom_build_plan.dart';
export 'darkroom_registration_preview.dart';

/// Native operations share the existing JSON request boundary.
typedef DarkroomBuildOperation =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

/// Reads a light's primary FITS header.
typedef DarkroomHeaderReader =
    Future<Map<String, String>> Function(String path);

/// Free bytes on the volume holding a directory.
typedef DarkroomFreeSpace = Future<int> Function(String directory);

/// Memory the native build may hold registered subs in before it writes
/// them to a working folder beside the master, in MiB.
const int darkroomSpoolMemoryBudgetMb = 1024;

/// Space kept free beyond the working folder, for the masters and the rest
/// of the system.
const int darkroomSpoolHeadroomBytes = 512 << 20;

/// Sensor temperatures closer than this, within one night and setup, are one
/// group: cooler drift during a night must not split its calibration.
const double darkroomTemperatureGapC = 3;

/// Weighting the build asks the native side for. Star signal over noise,
/// squared, is the closest native measure to PixInsight's default PSF Signal
/// Weight.
const String darkroomWeightFormula = 'starSignal';

/// A filter's build error in words. The native side reports a filter with
/// no integrable light as JSON naming each light's reason.
String describeFilterFailure(Object error) {
  final text = error is String ? error : '$error';
  final start = text.indexOf('{');
  if (start >= 0) {
    try {
      final value = jsonDecode(text.substring(start));
      if (value is Map && value['kind'] == 'noSubsIntegrated') {
        final skipped = (value['skipped'] as List? ?? const []).cast<Map>();
        final reasons = skipped
            .take(3)
            .map((s) => '${p.basename('${s['path']}')}: ${s['reason']}')
            .join('; ');
        return 'None of its ${value['offered']} lights could be integrated'
            '${reasons.isEmpty ? '.' : ' ($reasons).'}';
      }
    } on FormatException {
      // Not the structured report; the text is shown as it is.
    }
  }
  return text;
}

/// The color role a filter name plays in an RGB or LRGB composite (`L`, `R`,
/// `G`, `B`), or null for a filter that is none of them, such as Ha. The names
/// are the ones the native composite classifies the same way.
String? darkroomColorRole(String filter) {
  final f = filter.toLowerCase().replaceAll(RegExp(r'[\s\-_/\[\]().]'), '');
  if (const {
    'l',
    'lum',
    'luma',
    'luminance',
    'clear',
    'c',
    'cl',
    'uvircut',
    'uvir',
    'ircut',
    'uvirblock',
    'uvircutoff',
    'lrgbl',
  }.contains(f)) {
    return 'L';
  }
  if (const {'r', 'red'}.contains(f)) return 'R';
  if (const {'g', 'green'}.contains(f)) return 'G';
  if (const {'b', 'blue'}.contains(f)) return 'B';
  return null;
}

/// Integration time for display: minutes under an hour, else hours.
String describeIntegration(num seconds) => seconds < 3600
    ? '${(seconds / 60).round()} min'
    : '${(seconds / 3600).toStringAsFixed(1)} h';

/// The evening date of the observing night [time] belongs to. A night runs
/// from local noon to local noon, so frames after midnight stay with the
/// evening they started.
String observingNight(DateTime time) {
  final local = time.toLocal();
  final evening = local.hour < 12
      ? DateTime(local.year, local.month, local.day - 1)
      : DateTime(local.year, local.month, local.day);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${evening.year}-${two(evening.month)}-${two(evening.day)}';
}

class DarkroomBuildGroup {
  DarkroomBuildGroup({
    required this.label,
    required this.filter,
    required this.frames,
    required this.calibration,
    required this.warnings,
    this.night,
    this.equipment,
  });
  final String label;
  final String filter;
  final List<CapturedImage> frames;
  final Map<String, dynamic> calibration;
  final List<String> warnings;

  /// Evening date of the group's observing night.
  final String? night;

  /// Camera and optics, for display.
  final String? equipment;

  bool get hasFlat => calibration['flat'] != null;

  Map<String, dynamic> toJson() => {
    'label': label,
    'filter': filter,
    'calibration': calibration,
    'warnings': warnings,
    'lights': [
      for (final f in frames)
        {
          'id': f.id,
          'path': f.filePath,
          'exposureSec': f.exposureDuration,
          if (f.pierSide != null) 'side': f.pierSide,
        },
    ],
  };
}

/// Which filters have a flat in every group, and which have none.
class DarkroomFlatCoverage {
  const DarkroomFlatCoverage({
    required this.withFlats,
    required this.withoutFlats,
    required this.partial,
  });
  final List<String> withFlats;
  final List<String> withoutFlats;

  /// Filters where some groups have a flat and others do not.
  final List<String> partial;

  bool get complete => withoutFlats.isEmpty && partial.isEmpty;

  /// A plain warning, or null when every group has a flat.
  String? get warning {
    if (complete) return null;
    final missing = [
      ...withoutFlats,
      ...partial.map((f) => '$f (some nights)'),
    ];
    const effect =
        'Masters built without flats keep dust shadows and vignetting.';
    if (withFlats.isEmpty) {
      return 'No filter has flats (${missing.join(', ')}). $effect';
    }
    return 'Flats are available for ${withFlats.join(', ')}, but not for '
        '${missing.join(', ')}. $effect';
  }
}

/// One step of a running build, for progress displays.
class DarkroomBuildStep {
  const DarkroomBuildStep({
    required this.stage,
    required this.message,
    this.filter,
    this.filterIndex = 0,
    this.filterCount = 0,
    this.filterLights = 0,
    this.filterResults = const [],
  });

  /// `building`, `exporting` or `done`.
  final String stage;
  final String message;
  final String? filter;
  final int filterIndex;
  final int filterCount;

  /// Lights offered to the filter being built.
  final int filterLights;

  /// Finished filters so far: native results, or `{filter, error}`.
  final List<Map<String, dynamic>> filterResults;
}

/// How an unattended build ended.
class DarkroomUnattendedOutcome {
  const DarkroomUnattendedOutcome({
    required this.directory,
    required this.preview,
    this.report,
    this.plan,
    this.warnings = const [],
  });
  final Directory directory;
  final DarkroomRegistrationPreview preview;
  final DarkroomBuildPlan? plan;

  /// Null when the crop fell below the minimum and the build waits for review.
  final Map<String, dynamic>? report;
  final List<String> warnings;

  bool get built => report != null;
}

class DarkroomBuildService {
  DarkroomBuildService({
    required this.operation,
    required this.library,
    required this.masters,
    DarkroomHeaderReader? readHeader,
    CalibrationMasterBuild? buildMaster,
    DarkroomBuildOperation? buildFlat,
    this.darkLibrary,
    this.flatLibrary,
    DarkroomFreeSpace? freeSpace,
  }) : _readHeader =
           readHeader ??
           ((path) => const FitsHeaderReader().readPrimaryHeader(path)),
       _freeSpace =
           freeSpace ??
           ((directory) async =>
               (await DiskSpaceService().query(directory)).freeBytes),
       _buildMaster = buildMaster ?? buildCalibrationMasterNative,
       _buildFlat = buildFlat ?? _nativeBuildFlat;

  final DarkroomBuildOperation operation;
  final CalibrationLibraryService library;
  final IntegratedMastersDao masters;
  final DarkLibraryService? darkLibrary;
  final FlatLibraryDao? flatLibrary;
  final DarkroomHeaderReader _readHeader;
  final DarkroomFreeSpace _freeSpace;
  final CalibrationMasterBuild _buildMaster;
  final DarkroomBuildOperation _buildFlat;
  bool _running = false;
  bool _stop = false;
  String? _runId;

  bool get isRunning => _running;

  static Future<Map<String, dynamic>> _nativeBuildFlat(
    Map<String, dynamic> request,
  ) async => Map<String, dynamic>.from(
    jsonDecode(await bridge.apiBuildMasterFlat(argsJson: jsonEncode(request)))
        as Map,
  );

  /// Group accepted lights by observing night, equipment and acquisition
  /// settings, and match calibration masters from the local library. A filter's
  /// flat is applied to every group of that filter that has no flat of its own.
  Future<List<DarkroomBuildGroup>> prepare(List<CapturedImage> frames) async {
    final lights = frames
        .where((f) => f.isAccepted && f.frameType.toLowerCase() == 'light')
        .toList();
    final headers = <int, Map<String, String>>{};
    for (final f in lights) {
      headers[f.id] = await _readHeader(f.filePath);
    }
    String camera(CapturedImage f) =>
        FitsHeaderReader.stringValue(headers[f.id]!, 'INSTRUME') ??
        'unknown camera';
    String optics(CapturedImage f) =>
        FitsHeaderReader.stringValue(headers[f.id]!, 'TELESCOP') ??
        'unknown optics';
    final cameras = lights.map(camera).toSet().length;
    final setups = <String, List<CapturedImage>>{};
    for (final f in lights) {
      final h = headers[f.id]!;
      final key = [
        observingNight(f.capturedAt),
        camera(f),
        optics(f),
        '${h['NAXIS1']}x${h['NAXIS2']}',
        _filterOf(f),
        f.exposureDuration,
        f.gain,
        f.offset,
        '${f.binX}x${f.binY}',
      ].join(' / ');
      setups.putIfAbsent(key, () => []).add(f);
    }
    final result = <DarkroomBuildGroup>[];
    final keys = setups.keys.toList()..sort();
    for (final key in keys) {
      for (final cluster in _temperatureClusters(setups[key]!)) {
        final f = cluster.first;
        final temps = [
          for (final c in cluster)
            if (c.sensorTemp != null) c.sensorTemp!,
        ]..sort();
        final temperature = temps.isEmpty ? null : temps[temps.length ~/ 2];
        final night = observingNight(f.capturedAt);
        final label = [
          'Night of $night',
          _filterOf(f),
          '${_seconds(f.exposureDuration)} s',
          if (f.gain != null) 'gain ${f.gain}',
          if (f.offset != null) 'offset ${f.offset}',
          if (f.binX != 1 || f.binY != 1) 'bin ${f.binX}x${f.binY}',
          if (temperature != null) '${temperature.round()} C',
          if (cameras > 1) camera(f),
        ].join(' · ');
        final matches = await library.match(
          LightFrameContext(
            cameraId: FitsHeaderReader.stringValue(headers[f.id]!, 'INSTRUME'),
            gain: f.gain,
            offset: f.offset,
            exposureSeconds: f.exposureDuration,
            temperature: temperature,
            filter: f.filter,
            binX: f.binX,
            binY: f.binY,
          ),
          includeRemote: false,
        );
        final dark = matches.dark?.record;
        final exactDark =
            dark != null && dark.exposureSeconds == f.exposureDuration;
        final bias = matches.bias?.record.filePath;
        // A dark of another exposure is scaled to the lights' exposure, which
        // needs the bias to separate the dark current from the offset.
        final scaledDark =
            dark != null &&
            dark.exposureSeconds != null &&
            !exactDark &&
            bias != null;
        result.add(
          DarkroomBuildGroup(
            label: label,
            filter: _filterOf(f),
            night: night,
            equipment: '${camera(f)} · ${optics(f)}',
            frames: cluster,
            calibration: {
              if (exactDark || scaledDark) 'dark': dark.filePath,
              if (scaledDark) 'scaleDark': true,
              if (matches.flat?.record.filePath != null)
                'flat': matches.flat!.record.filePath,
              if (!exactDark && bias != null) 'bias': bias,
              'cosmeticCorrection': true,
            },
            warnings: [
              ...matches.allWarnings,
              if (scaledDark)
                'The ${_seconds(dark.exposureSeconds!)} s dark is scaled to ${_seconds(f.exposureDuration)} s using the bias.',
              if (dark != null && !exactDark && !scaledDark)
                'Dark exposure differs and there is no bias to scale it with; no dark will be applied.',
            ],
          ),
        );
      }
    }
    shareFlatsWithinFilters(result);
    return result;
  }

  static String _filterOf(CapturedImage f) =>
      f.filter?.trim().isNotEmpty == true ? f.filter!.trim() : 'NoFilter';

  static String _seconds(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  /// Split frames where consecutive sensor temperatures differ by more than
  /// [darkroomTemperatureGapC]. Frames without a temperature join the
  /// largest cluster.
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
          darkroomTemperatureGapC) {
        clusters.add([f]);
      } else {
        clusters.last.add(f);
      }
    }
    clusters.sort((a, b) => b.length.compareTo(a.length));
    clusters.first.addAll(unknown);
    for (final c in clusters) {
      c.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    }
    clusters.sort((a, b) => a.first.capturedAt.compareTo(b.first.capturedAt));
    return clusters;
  }

  /// Groups of a filter without a flat take the flat most of that filter's
  /// frames use.
  static void shareFlatsWithinFilters(List<DarkroomBuildGroup> groups) {
    for (final filter in groups.map((g) => g.filter).toSet()) {
      final same = groups.where((g) => g.filter == filter).toList();
      final votes = <String, int>{};
      for (final g in same.where((g) => g.hasFlat)) {
        final path = g.calibration['flat'] as String;
        votes[path] = (votes[path] ?? 0) + g.frames.length;
      }
      if (votes.isEmpty) continue;
      final flat = votes.entries
          .reduce((a, b) => b.value > a.value ? b : a)
          .key;
      for (final g in same.where((g) => !g.hasFlat)) {
        g.calibration['flat'] = flat;
        g.warnings.add(
          'Uses the $filter flat from another night (${p.basename(flat)}). '
          'Check that the camera was not rotated and dust did not move.',
        );
      }
    }
  }

  /// Apply one calibration master to every group of [filter].
  static void applyToFilter(
    List<DarkroomBuildGroup> groups,
    String filter,
    String kind,
    String? path,
  ) {
    for (final g in groups.where((g) => g.filter == filter)) {
      if (path == null) {
        g.calibration.remove(kind);
      } else {
        g.calibration[kind] = path;
        g.calibration.remove('scaleDark');
        if (kind == 'dark') g.calibration.remove('bias');
        if (kind == 'bias') g.calibration.remove('dark');
      }
    }
  }

  static DarkroomFlatCoverage flatCoverage(List<DarkroomBuildGroup> groups) {
    final withFlats = <String>[];
    final without = <String>[];
    final partial = <String>[];
    final filters = groups.map((g) => g.filter).toSet().toList()..sort();
    for (final filter in filters) {
      final same = groups.where((g) => g.filter == filter);
      if (same.every((g) => g.hasFlat)) {
        withFlats.add(filter);
      } else if (same.any((g) => g.hasFlat)) {
        partial.add(filter);
      } else {
        without.add(filter);
      }
    }
    return DarkroomFlatCoverage(
      withFlats: withFlats,
      withoutFlats: without,
      partial: partial,
    );
  }

  /// The best alignment reference: a luminance light if there is one, else
  /// the highest quality score.
  static String chooseReference(List<DarkroomBuildGroup> groups) {
    final candidates = groups.expand((g) => g.frames).toList()
      ..sort((a, b) {
        final lA = (a.filter ?? '').trim().toLowerCase() == 'l';
        final lB = (b.filter ?? '').trim().toLowerCase() == 'l';
        if (lA != lB) return lA ? -1 : 1;
        return (b.qualityScore ?? 0).compareTo(a.qualityScore ?? 0);
      });
    if (candidates.isEmpty) {
      throw StateError('No accepted light frames remain.');
    }
    return candidates.first.filePath;
  }

  /// Build a calibration master from raw frames and register it in the
  /// calibration library so later builds and captures find it.
  Future<String> buildCalibration({
    required String kind,
    required List<String> paths,
    required String output,
    String? bias,
    DarkroomBuildGroup? forGroup,
  }) async {
    if (kind == 'flat') {
      if (bias == null) {
        throw ArgumentError('Flats need a master bias or dark-flat.');
      }
      final built = await _buildFlat({
        'flatPaths': paths,
        'biasOrDarkFlat': bias,
        'outputPath': output,
        'outputBitDepth': 'f32',
        'method': 'sigmaClip',
        'sigmaKappa': 3,
        'sigmaIterations': 3,
      });
      final sample = forGroup?.frames.firstOrNull;
      await flatLibrary?.addEntry(
        filePath: output,
        filter: forGroup?.filter,
        temperature: sample?.sensorTemp,
        gain: sample?.gain ?? 0,
        offset: sample?.offset ?? 0,
        binX: sample?.binX ?? 1,
        binY: sample?.binY ?? 1,
        width: (built['width'] as num?)?.toInt(),
        height: (built['height'] as num?)?.toInt(),
        masterFrameCount:
            (built['frameCount'] as num?)?.toInt() ?? paths.length,
      );
    } else {
      final built = await _buildMaster(
        CalibrationMasterBuildRequest(
          kind: kind,
          framePaths: paths,
          outputPath: output,
        ),
      );
      await darkLibrary?.registerMaster(built, frameType: kind);
    }
    return output;
  }

  Future<void> checkCalibration(List<DarkroomBuildGroup> groups) async {
    for (final g in groups) {
      try {
        await operation({
          'op': 'checkCalibration',
          'path': g.frames.first.filePath,
          'calibration': g.calibration,
        });
      } catch (e) {
        throw StateError('${g.label}: $e');
      }
    }
  }

  DarkroomBuildPlan plan({
    required String target,
    required List<DarkroomBuildGroup> groups,
    required String referencePath,
    double minOverlap = .95,
    double maxEccentricity = .65,
    double minRetainedArea = defaultMinRetainedArea,
    List<Map<String, dynamic>> excluded = const [],
  }) {
    final all = groups.expand((g) => g.frames).toList();
    if (all.isEmpty || !all.any((f) => f.filePath == referencePath)) {
      throw ArgumentError('Choose an included reference frame.');
    }
    if (minOverlap < .5 ||
        minOverlap > 1 ||
        maxEccentricity <= 0 ||
        maxEccentricity > 1) {
      throw ArgumentError('Invalid framing or star shape limit.');
    }
    return DarkroomBuildPlan.fromJson({
      'version': 1,
      'target': target,
      'excluded': excluded,
      'groups': [for (final g in groups) g.toJson()],
      'referencePath': referencePath,
      'minOverlap': minOverlap,
      'maxEccentricity': maxEccentricity,
      'minRetainedArea': minRetainedArea,
      'noFlatFilters': flatCoverage(groups).withoutFlats,
    });
  }

  static Map<String, dynamic> _align() => {
    'model': 'affine',
    'resampler': 'lanczos3',
  };

  /// Register every light of [buildPlan] from its stars and report where each
  /// lands and the common crop. With [previous], lights it covers are not
  /// registered again, so excluding frames re-evaluates at once.
  Future<DarkroomRegistrationPreview> previewRegistration(
    DarkroomBuildPlan buildPlan, {
    DarkroomRegistrationPreview? previous,
  }) async {
    final plan = buildPlan.toJson();
    final known = {
      for (final f in previous?.frames ?? const <DarkroomFramePreview>[])
        f.path: f.raw,
    };
    final allKnown =
        plan['groups'] is List &&
        buildPlan.lights.every((l) => known.containsKey(l['path']));
    _runId = 'darkroom-framing-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final result = await operation({
        'op': 'registrationPreview',
        'runId': _runId,
        'gridReference': {'path': plan['referencePath']},
        if (allKnown && previous != null)
          'gridSize': [previous.width, previous.height],
        'groups': [
          for (final g in plan['groups'] as List)
            {
              'label': g['label'],
              'lights': [
                for (final l in g['lights'] as List)
                  {
                    'path': l['path'],
                    if (l['side'] != null) 'side': l['side'],
                    if (known[l['path']] != null) 'known': known[l['path']],
                  },
              ],
            },
        ],
        'settings': {'align': _align()},
        'minOverlap': plan['minOverlap'],
        'minRetainedArea': plan['minRetainedArea'],
      });
      return DarkroomRegistrationPreview.fromJson(result);
    } finally {
      _runId = null;
    }
  }

  Future<void> stop() async {
    _stop = true;
    if (_runId != null) {
      await bridge.apiPostSessionCancel(
        argsJson: jsonEncode({'runId': _runId, 'op': 'cancel'}),
      );
    }
  }

  static String _filterKey(String filter) {
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(filter)) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    final safe = filter.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return '$safe-${hash.toRadixString(16)}';
  }

  /// Whether [next] differs from [saved] only by leaving out lights or by a
  /// different crop minimum: everything else that a completed filter depends
  /// on is unchanged.
  static bool _onlyExclusions(Map saved, Map next) {
    const free = {'groups', 'excluded', 'minRetainedArea'};
    for (final key in {...saved.keys, ...next.keys}) {
      if (free.contains(key)) continue;
      if (jsonEncode(saved[key]) != jsonEncode(next[key])) return false;
    }
    final savedGroups = {
      for (final g in saved['groups'] as List) (g as Map)['label']: g,
    };
    for (final g in next['groups'] as List) {
      final before = savedGroups[(g as Map)['label']];
      if (before == null ||
          before['filter'] != g['filter'] ||
          jsonEncode(before['calibration']) != jsonEncode(g['calibration'])) {
        return false;
      }
      final paths = {
        for (final l in before['lights'] as List) (l as Map)['path'],
      };
      if (!(g['lights'] as List).every((l) => paths.contains(l['path']))) {
        return false;
      }
    }
    return true;
  }

  static Map<String, List<String>> _lightsByFilter(Map plan) {
    final out = <String, List<String>>{};
    for (final g in plan['groups'] as List) {
      for (final l in (g as Map)['lights'] as List) {
        out
            .putIfAbsent(g['filter'] as String, () => [])
            .add(l['path'] as String);
      }
    }
    for (final v in out.values) {
      v.sort();
    }
    return out;
  }

  /// Build every filter of [buildPlan] into [directory] and export the common
  /// crop.
  ///
  /// A fresh build needs an [accepted] pre-pass whose crop meets the plan's
  /// minimum. A folder that already holds this plan resumes: completed filters
  /// are reused and an interrupted filter starts over without adding any
  /// exposure twice. A plan that only leaves out lights (or changes the crop
  /// minimum) replaces the saved one; filters whose lights changed are built
  /// again. A filter that fails is reported and the others continue.
  Future<Map<String, dynamic>> run(
    DarkroomBuildPlan buildPlan,
    Directory directory, {
    DarkroomRegistrationPreview? accepted,
    void Function(DarkroomBuildStep)? onStep,
  }) async {
    if (_running) {
      throw StateError('A master build is already running.');
    }
    final plan = buildPlan.toJson();
    _running = true;
    _stop = false;
    try {
      await directory.create(recursive: true);
      final inputs = await _inputs(plan);
      final journal = File(p.join(directory.path, 'plan.json'));
      if (await journal.exists()) {
        final saved = jsonDecode(await journal.readAsString()) as Map;
        final savedInputs = saved['inputs'] as Map;
        final changedInputs = inputs.keys.any(
          (k) => jsonEncode(savedInputs[k]) != jsonEncode(inputs[k]),
        );
        if (changedInputs) {
          throw StateError(
            'The saved plan or its input files changed. Start a new build to avoid mixing different data.',
          );
        }
        if (jsonEncode(saved['plan']) != jsonEncode(plan)) {
          if (!_onlyExclusions(saved['plan'] as Map, plan)) {
            throw StateError(
              'The saved plan or its input files changed. Start a new build to avoid mixing different data.',
            );
          }
          if (accepted == null || !accepted.meetsMinimum) {
            throw StateError(
              'Check framing again after excluding frames before resuming.',
            );
          }
          final before = _lightsByFilter(saved['plan'] as Map);
          final after = _lightsByFilter(plan);
          for (final filter in {...before.keys, ...after.keys}) {
            if (jsonEncode(before[filter]) != jsonEncode(after[filter])) {
              await _deleteIfPresent(
                File(
                  p.join(directory.path, 'filter-${_filterKey(filter)}.json'),
                ),
              );
            }
          }
          await _deleteIfPresent(File(p.join(directory.path, 'delivery.json')));
          await _write(journal, {
            'plan': plan,
            'inputs': inputs,
            'framing': _framingRecord(accepted),
          });
        }
      } else {
        if (accepted == null) {
          throw StateError('Check framing before building.');
        }
        if (!accepted.meetsMinimum) {
          throw StateError(accepted.describeLimit());
        }
        await _write(journal, {
          'plan': plan,
          'inputs': inputs,
          'framing': _framingRecord(accepted),
        });
      }
      final groups = (plan['groups'] as List).cast<Map<String, dynamic>>();
      final filters = buildPlan.filters;
      final referencePath = plan['referencePath'] as String;
      final referenceGroup = groups.firstWhere(
        (g) => (g['lights'] as List).any((f) => f['path'] == referencePath),
      );
      await _checkWorkingSpace(
        directory,
        referencePath: referencePath,
        lightsPerFilter: {
          for (final filter in filters)
            if (!await File(
              p.join(directory.path, 'filter-${_filterKey(filter)}.json'),
            ).exists())
              filter: groups
                  .where((g) => g['filter'] == filter)
                  .fold<int>(0, (n, g) => n + (g['lights'] as List).length),
        },
      );
      final results = <Map<String, dynamic>>[];
      final failures = <Map<String, dynamic>>[];
      List<Map<String, dynamic>> finished() => [...results, ...failures];
      for (var i = 0; i < filters.length; i++) {
        if (_stop) {
          throw StateError(
            'Stopped. Resume this folder to keep completed filters.',
          );
        }
        final filter = filters[i];
        final key = _filterKey(filter);
        final selected = groups.where((g) => g['filter'] == filter).toList();
        final lights = selected.fold<int>(
          0,
          (n, g) => n + (g['lights'] as List).length,
        );
        final receipt = File(p.join(directory.path, 'filter-$key.json'));
        if (await receipt.exists()) {
          final result = Map<String, dynamic>.from(
            jsonDecode(await receipt.readAsString()) as Map,
          );
          if (!await File(result['masterPath'] as String).exists() ||
              !await File(result['coveragePath'] as String).exists()) {
            throw StateError(
              'Completed $filter files are missing. Restore them or start a new build.',
            );
          }
          if (result['filter'] != filter) {
            throw StateError('Saved filter receipt does not match this plan.');
          }
          results.add(result);
          continue;
        }
        onStep?.call(
          DarkroomBuildStep(
            stage: 'building',
            message: 'Building $filter (${i + 1} of ${filters.length})',
            filter: filter,
            filterIndex: i,
            filterCount: filters.length,
            filterLights: lights,
            filterResults: finished(),
          ),
        );
        _runId = 'darkroom-${DateTime.now().microsecondsSinceEpoch}';
        try {
          final result = await operation({
            'op': 'build',
            'runId': _runId,
            'target': plan['target'],
            'filter': filter,
            'gridReference': {
              'path': referencePath,
              'calibration': referenceGroup['calibration'],
            },
            'normalizationReference': {
              'path': (selected.first['lights'] as List).first['path'],
              'calibration': selected.first['calibration'],
            },
            'groups': selected,
            'minOverlap': plan['minOverlap'],
            'maxEccentricity': plan['maxEccentricity'],
            'validateFlats': true,
            'settings': {
              'align': _align(),
              'weighting': {'enabled': true, 'formula': darkroomWeightFormula},
              'normalization': {'enabled': true, 'mode': 'global'},
            },
            // PixInsight's default: the rejection algorithm is chosen by the
            // number of frames. Native builds that still fold online use the
            // clip thresholds instead.
            'rejection': 'auto',
            'memoryBudgetMb': darkroomSpoolMemoryBudgetMb,
            'clip': {'onlineClipLow': 4, 'onlineClipHigh': 4},
            'masterFitsPath': p.join(directory.path, 'full-$key.fits'),
            'previewPngPath': p.join(directory.path, 'full-$key.png'),
            'coverageFitsPath': p.join(directory.path, 'coverage-$key.fits'),
          });
          await _write(receipt, result);
          results.add(result);
        } catch (e) {
          if (_stop || '$e'.contains('"kind":"cancelled"')) {
            throw StateError(
              'Stopped. Resume this folder to keep completed filters.',
            );
          }
          failures.add({'filter': filter, 'error': describeFilterFailure(e)});
        } finally {
          _runId = null;
        }
      }
      if (_stop) {
        throw StateError(
          'Stopped before export. Resume to export completed filters.',
        );
      }
      if (results.isEmpty) {
        throw StateError(
          'No filter could be built. ${failures.map((f) => '${f['filter']}: ${f['error']}').join(' ')}',
        );
      }
      onStep?.call(
        DarkroomBuildStep(
          stage: 'exporting',
          message: 'Cropping all filters to full shared coverage',
          filterIndex: filters.length,
          filterCount: filters.length,
          filterResults: finished(),
        ),
      );
      final built = [for (final r in results) r['filter'] as String];
      final deliveryReceipt = File(p.join(directory.path, 'delivery.json'));
      Map<String, dynamic>? delivery;
      if (await deliveryReceipt.exists()) {
        delivery = Map<String, dynamic>.from(
          jsonDecode(await deliveryReceipt.readAsString()) as Map,
        );
        final saved = [
          for (final m in delivery['masters'] as List) (m as Map)['filter'],
        ];
        if (jsonEncode(saved) != jsonEncode(built)) delivery = null;
      }
      if (delivery == null) {
        try {
          // Each attempt has its own folder, so a partial export is never overwritten.
          delivery = await operation({
            'op': 'deliverUniform',
            'outputDir': p.join(
              directory.path,
              'masters-${DateTime.now().microsecondsSinceEpoch}',
            ),
            'minRetainedArea': plan['minRetainedArea'],
            'masters': [
              for (final r in results)
                {
                  'path': r['masterPath'],
                  'coveragePath': r['coveragePath'],
                  'filter': _filterKey(r['filter'] as String),
                },
            ],
          });
        } catch (e) {
          throw StateError(
            '$e${accepted == null ? '' : ' ${accepted.describeLimit()}'}',
          );
        }
        final files = delivery['masters'] as List;
        for (var i = 0; i < files.length; i++) {
          files[i]['filter'] = built[i];
        }
        await _write(deliveryReceipt, delivery);
      }
      await _registerMasters(plan, groups, results, delivery);
      final report = {
        'plan': plan,
        'results': results,
        'failures': failures,
        'delivery': delivery,
      };
      await _write(File(p.join(directory.path, 'report.json')), report);
      await _writeAudit(directory, plan, results);
      onStep?.call(
        DarkroomBuildStep(
          stage: 'done',
          message: 'Masters ready',
          filterIndex: filters.length,
          filterCount: filters.length,
          filterResults: finished(),
        ),
      );
      return report;
    } finally {
      _running = false;
      _runId = null;
    }
  }

  static Map<String, dynamic> _framingRecord(DarkroomRegistrationPreview p) => {
    'retainedArea': p.retainedArea,
    'crop': p.crop,
    'acceptedAt': DateTime.now().toUtc().toIso8601String(),
  };

  static Future<void> _deleteIfPresent(File file) async {
    if (await file.exists()) await file.delete();
  }

  static Future<Map<String, dynamic>> _inputs(Map<String, dynamic> plan) async {
    final inputPaths = <String>{};
    for (final group in plan['groups'] as List) {
      for (final light in group['lights'] as List) {
        inputPaths.add(light['path'] as String);
      }
      for (final kind in ['dark', 'bias', 'flat']) {
        if (group['calibration'][kind] != null) {
          inputPaths.add(group['calibration'][kind] as String);
        }
      }
    }
    final inputs = <String, dynamic>{};
    for (final path in inputPaths.toList()..sort()) {
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file) {
        throw StateError('Input file is missing: $path');
      }
      inputs[path] = {
        'bytes': stat.size,
        'modified': stat.modified.toUtc().toIso8601String(),
      };
    }
    return inputs;
  }

  Future<void> _registerMasters(
    Map<String, dynamic> plan,
    List<Map<String, dynamic>> groups,
    List<Map<String, dynamic>> results,
    Map<String, dynamic> delivery,
  ) async {
    final library = await masters.getAll();
    final inputsByPath = <String, int>{
      for (final group in groups)
        for (final light in group['lights'] as List)
          light['path'] as String: light['id'] as int,
    };
    for (var i = 0; i < results.length; i++) {
      final file = (delivery['masters'] as List)[i] as Map;
      final filter = results[i]['filter'] as String;
      if (!await File(file['path'] as String).exists()) {
        throw StateError(
          'Exported $filter master is missing. Restore it before resuming.',
        );
      }
      final existing = library
          .where((m) => m.masterFitsPath == file['path'])
          .firstOrNull;
      if (existing != null) continue;
      final masterId = await masters.insertMaster(
        name: '${plan['target']} $filter',
        masterFitsPath: file['path'] as String,
        previewPngPath: file['previewPath'] as String,
        filter: filter,
        channels: file['channels'] as int,
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.runningWeightedMean,
        width: delivery['width'] as int,
        height: delivery['height'] as int,
        frameCount: results[i]['frameCount'] as int,
        totalIntegrationSeconds: (results[i]['totalIntegrationSec'] as num)
            .toDouble(),
        settingsJson: jsonEncode(plan),
        statsJson: jsonEncode(results[i]),
      );
      for (final frame in results[i]['folded'] as List) {
        final id = inputsByPath[frame['path']];
        if (id == null) continue;
        await masters.recordFoldedFrame(
          masterId: masterId,
          imageId: id,
          weight: (frame['weight'] as num?)?.toDouble(),
          alignmentResidualPx: (frame['rmsPx'] as num?)?.toDouble(),
        );
      }
      for (final frame in results[i]['skipped'] as List) {
        final id = inputsByPath[frame['path']];
        if (id == null) continue;
        await masters.recordFoldedFrame(
          masterId: masterId,
          imageId: id,
          accepted: false,
          rejectionReason: frame['reason'] as String,
        );
      }
    }
    await _registerComposites(plan, results, delivery, library);
  }

  /// Register the RGB and LRGB composites the export wrote as color masters,
  /// so they open in the Darkroom like the per-filter masters they combine.
  ///
  /// A composite's frame count and integration are those of the masters it
  /// combines. Registered once per file, so a resumed build adds nothing.
  Future<void> _registerComposites(
    Map<String, dynamic> plan,
    List<Map<String, dynamic>> results,
    Map<String, dynamic> delivery,
    List<IntegratedMaster> library,
  ) async {
    final composites = delivery['composites'];
    if (composites is! Map) return;
    for (final (kind, pathKey, xisfKey, previewKey, roles) in const [
      ('RGB', 'rgbPath', 'rgbXisfPath', 'rgbPreviewPath', {'R', 'G', 'B'}),
      (
        'LRGB',
        'lrgbPath',
        'lrgbXisfPath',
        'lrgbPreviewPath',
        {'L', 'R', 'G', 'B'},
      ),
    ]) {
      final path = composites[pathKey];
      if (path is! String) continue;
      if (!await File(path).exists()) {
        throw StateError(
          'Exported $kind composite is missing. Restore it before resuming.',
        );
      }
      if (library.any((m) => m.masterFitsPath == path)) continue;
      final used = [
        for (final r in results)
          if (roles.contains(darkroomColorRole(r['filter'] as String))) r,
      ];
      final preview = composites[previewKey];
      await masters.insertMaster(
        name: '${plan['target']} $kind',
        masterFitsPath: path,
        previewPngPath: preview is String ? preview : null,
        filter: kind,
        channels: 3,
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.runningWeightedMean,
        width: delivery['width'] as int,
        height: delivery['height'] as int,
        frameCount: used.fold<int>(0, (n, r) => n + (r['frameCount'] as int)),
        totalIntegrationSeconds: used.fold<double>(
          0,
          (n, r) => n + (r['totalIntegrationSec'] as num).toDouble(),
        ),
        settingsJson: jsonEncode(plan),
        statsJson: jsonEncode({
          'composite': kind,
          'filters': [for (final r in used) r['filter']],
          if (composites[xisfKey] != null) 'xisfPath': composites[xisfKey],
        }),
      );
    }
  }

  static Future<void> _writeAudit(
    Directory directory,
    Map<String, dynamic> plan,
    List<Map<String, dynamic>> results,
  ) async {
    final audit = StringBuffer('Filter,Path,Included,Reason\n');
    String cell(Object? value) => '"${value.toString().replaceAll('"', '""')}"';
    for (final f in (plan['excluded'] as List? ?? const [])) {
      audit.writeln(
        '${cell(f['filter'])},${cell(f['path'])},false,${cell(f['reason'])}',
      );
    }
    for (final r in results) {
      for (final f in r['folded'] as List) {
        audit.writeln('${cell(r['filter'])},${cell(f['path'])},true,');
      }
      for (final f in r['skipped'] as List) {
        audit.writeln(
          '${cell(r['filter'])},${cell(f['path'])},false,${cell(f['reason'])}',
        );
      }
    }
    await File(
      p.join(directory.path, 'frame-audit.csv'),
    ).writeAsString(audit.toString());
  }

  /// Build every filter of [target] from all of [frames] with default choices
  /// and no questions: library calibration (a filter's flat shared across its
  /// nights, filters without flats built without), the best luminance light
  /// as reference, and the registration pre-pass. Integration starts only when
  /// the common crop keeps at least [minRetainedArea]; otherwise the outcome
  /// carries the pre-pass for review and nothing is integrated.
  Future<DarkroomUnattendedOutcome> buildUnattended({
    required String target,
    required List<CapturedImage> frames,
    required Directory directory,
    double minRetainedArea = defaultMinRetainedArea,
    void Function(DarkroomBuildStep)? onStep,
    void Function(DarkroomRegistrationPreview, DarkroomBuildPlan)? onPreview,
  }) async {
    final groups = await prepare(frames);
    if (groups.isEmpty) {
      throw StateError('$target has no accepted light frames.');
    }
    final warnings = <String>[];
    // A master that fails the calibration check is left out, one at a time,
    // so a bad flat costs flat correction rather than the night.
    for (final g in [...groups]) {
      Object? failure;
      var usable = false;
      for (final kind in [null, 'flat', 'dark', 'bias']) {
        if (kind != null) {
          if (g.calibration.remove(kind) == null) continue;
          warnings.add('${g.label}: left out the $kind master. $failure');
        }
        try {
          await checkCalibration([g]);
          usable = true;
          break;
        } catch (e) {
          failure = e;
        }
      }
      if (!usable) {
        groups.remove(g);
        warnings.add('${g.label}: not built. $failure');
      }
    }
    if (groups.isEmpty) {
      throw StateError(
        '$target: no group passed the calibration check. ${warnings.join(' ')}',
      );
    }
    final coverage = flatCoverage(groups);
    if (coverage.warning != null) warnings.add(coverage.warning!);
    final buildPlan = plan(
      target: target,
      groups: groups,
      referencePath: chooseReference(groups),
      minRetainedArea: minRetainedArea,
      excluded: [
        for (final f in frames.where((f) => !f.isAccepted))
          {
            'filter': f.filter,
            'path': f.filePath,
            'reason': f.rejectionReason ?? 'Capture quality rejection',
          },
      ],
    );
    final preview = await previewRegistration(buildPlan);
    onPreview?.call(preview, buildPlan);
    if (!preview.meetsMinimum) {
      return DarkroomUnattendedOutcome(
        directory: directory,
        preview: preview,
        plan: buildPlan,
        warnings: warnings,
      );
    }
    final report = await run(
      buildPlan,
      directory,
      accepted: preview,
      onStep: onStep,
    );
    return DarkroomUnattendedOutcome(
      directory: directory,
      preview: preview,
      plan: buildPlan,
      report: report,
      warnings: warnings,
    );
  }

  /// Fail before any filter is built when the working folder the native
  /// build writes registered subs to cannot fit on the master's volume.
  ///
  /// A filter whose subs, as `f32` on the reference grid, fit in
  /// [darkroomSpoolMemoryBudgetMb] is integrated in memory and needs no
  /// folder; a larger one writes every sub beside the master. Filters are
  /// built one at a time and each folder is removed after its filter, so the
  /// largest one is what has to fit.
  Future<void> _checkWorkingSpace(
    Directory directory, {
    required String referencePath,
    required Map<String, int> lightsPerFilter,
  }) async {
    if (lightsPerFilter.isEmpty) return;
    final header = await _readHeader(referencePath);
    final width = FitsHeaderReader.intValue(header, 'NAXIS1');
    final height = FitsHeaderReader.intValue(header, 'NAXIS2');
    if (width == null || height == null) {
      throw StateError(
        'The reference light $referencePath has no image size in its header, '
        'so the space the build needs cannot be worked out.',
      );
    }
    final channels = FitsHeaderReader.intValue(header, 'NAXIS3') ?? 1;
    final subBytes = width * height * channels * 4;
    const budget = darkroomSpoolMemoryBudgetMb << 20;
    var largest = 0;
    var largestFilter = '';
    for (final entry in lightsPerFilter.entries) {
      final bytes = entry.value * subBytes;
      if (bytes > budget && bytes > largest) {
        largest = bytes;
        largestFilter = entry.key;
      }
    }
    if (largest == 0) return;
    final needed = largest + darkroomSpoolHeadroomBytes;
    final free = await _freeSpace(directory.path);
    if (free >= needed) return;
    throw StateError(
      'Not enough free disk space to build masters in ${directory.path}: '
      '$largestFilter needs ${_gb(needed)} for its registered subs '
      '(${lightsPerFilter[largestFilter]} subs of ${_mb(subBytes)} each) and '
      '${_gb(free)} is free. Free up space on that drive or choose an '
      'output folder on a larger one.',
    );
  }

  static String _gb(int bytes) =>
      '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  static String _mb(int bytes) => '${(bytes / (1 << 20)).round()} MB';

  static Future<void> _write(File file, Map<String, dynamic> data) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

final darkroomBuildServiceProvider = Provider(
  (ref) => DarkroomBuildService(
    operation: (request) async => Map<String, dynamic>.from(
      jsonDecode(
            await bridge.apiMasterAccumulate(argsJson: jsonEncode(request)),
          )
          as Map,
    ),
    library: ref.watch(calibrationLibraryServiceProvider),
    masters: ref.watch(integratedMastersDaoProvider),
    buildMaster: ref.watch(calibrationMasterBuildProvider),
    darkLibrary: ref.watch(darkLibraryServiceProvider),
    flatLibrary: ref.watch(flatLibraryDaoProvider),
  ),
);
