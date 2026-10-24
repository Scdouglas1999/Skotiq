import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../database/database.dart';
import '../database/daos/integrated_masters_dao.dart';
import '../models/imaging/integrated_master.dart';
import '../models/calibration/calibration_library_models.dart';
import 'calibration/fits_header_reader.dart';
import 'calibration_library_service.dart';
import 'calibration_master_builder.dart';
import 'darkroom_build_plan.dart';
export 'darkroom_build_plan.dart';

/// Native operations share the existing JSON request boundary.
typedef DarkroomBuildOperation =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

class DarkroomBuildGroup {
  DarkroomBuildGroup({
    required this.label,
    required this.filter,
    required this.frames,
    required this.calibration,
    required this.warnings,
  });
  final String label;
  final String filter;
  final List<CapturedImage> frames;
  final Map<String, dynamic> calibration;
  final List<String> warnings;
  Map<String, dynamic> toJson() => {
    'label': label,
    'filter': filter,
    'calibration': calibration,
    'warnings': warnings,
    'lights': [
      for (final f in frames)
        {'id': f.id, 'path': f.filePath, 'exposureSec': f.exposureDuration},
    ],
  };
}

class DarkroomBuildService {
  DarkroomBuildService({
    required this.operation,
    required this.library,
    required this.masters,
  });
  final DarkroomBuildOperation operation;
  final CalibrationLibraryService library;
  final IntegratedMastersDao masters;
  bool _running = false;
  bool _stop = false;
  String? _runId;

  Future<List<DarkroomBuildGroup>> prepare(List<CapturedImage> frames) async {
    final groups = <String, List<CapturedImage>>{};
    for (final f in frames.where(
      (f) => f.isAccepted && f.frameType.toLowerCase() == 'light',
    )) {
      final header = await const FitsHeaderReader().readPrimaryHeader(
        f.filePath,
      );
      final camera =
          FitsHeaderReader.stringValue(header, 'INSTRUME') ?? 'unknown camera';
      final telescope =
          FitsHeaderReader.stringValue(header, 'TELESCOP') ?? 'unknown optics';
      final geometry = '${header['NAXIS1']}x${header['NAXIS2']}';
      final date = f.capturedAt.toLocal().toIso8601String().substring(0, 10);
      final key =
          '$date / $camera / $telescope / $geometry / ${f.filter ?? 'No filter'} / ${f.exposureDuration}s / gain ${f.gain} offset ${f.offset} / ${f.binX}x${f.binY} / ${f.sensorTemp?.round()}C';
      groups.putIfAbsent(key, () => []).add(f);
    }
    final result = <DarkroomBuildGroup>[];
    for (final entry in groups.entries) {
      final f = entry.value.first;
      final h = await const FitsHeaderReader().readPrimaryHeader(f.filePath);
      final matches = await library.match(
        LightFrameContext(
          cameraId: FitsHeaderReader.stringValue(h, 'INSTRUME'),
          gain: f.gain,
          offset: f.offset,
          exposureSeconds: f.exposureDuration,
          temperature: f.sensorTemp,
          filter: f.filter,
          binX: f.binX,
          binY: f.binY,
        ),
        includeRemote: false,
      );
      final dark = matches.dark?.record;
      final exactDark =
          dark != null && dark.exposureSeconds == f.exposureDuration;
      result.add(
        DarkroomBuildGroup(
          label: entry.key,
          filter: f.filter?.trim().isNotEmpty == true
              ? f.filter!.trim()
              : 'NoFilter',
          frames: entry.value,
          calibration: {
            if (exactDark) 'dark': dark.filePath,
            if (matches.flat?.record.filePath != null)
              'flat': matches.flat!.record.filePath,
            if (!exactDark && matches.bias?.record.filePath != null)
              'bias': matches.bias!.record.filePath,
            'cosmeticCorrection': true,
          },
          warnings: [
            ...matches.allWarnings,
            if (dark != null && !exactDark)
              'Dark exposure differs; no scaled dark will be applied.',
          ],
        ),
      );
    }
    return result;
  }

  Future<void> buildCalibration({
    required String kind,
    required List<String> paths,
    required String output,
    String? bias,
  }) async {
    if (kind == 'flat') {
      if (bias == null) {
        throw ArgumentError('Flats need a master bias or dark-flat.');
      }
      await bridge.apiBuildMasterFlat(
        argsJson: jsonEncode({
          'flatPaths': paths,
          'biasOrDarkFlat': bias,
          'outputPath': output,
          'outputBitDepth': 'f32',
          'method': 'sigmaClip',
          'sigmaKappa': 3,
          'sigmaIterations': 3,
        }),
      );
    } else {
      await buildCalibrationMasterNative(
        CalibrationMasterBuildRequest(
          kind: kind,
          framePaths: paths,
          outputPath: output,
        ),
      );
    }
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
    });
  }

  Future<void> stop() async {
    _stop = true;
    if (_runId != null) {
      await bridge.apiPostSessionCancel(
        argsJson: jsonEncode({'runId': _runId, 'op': 'cancel'}),
      );
    }
  }

  /// Completed filters are reused after interruption. A filter interrupted
  /// mid-build restarts; it never adds the same exposure twice.
  Future<Map<String, dynamic>> run(
    DarkroomBuildPlan buildPlan,
    Directory directory, {
    void Function(String)? onProgress,
  }) async {
    if (_running) {
      throw StateError('A master build is already running.');
    }
    final plan = buildPlan.toJson();
    _running = true;
    _stop = false;
    try {
      await directory.create(recursive: true);
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
      for (final path in inputPaths) {
        final stat = await File(path).stat();
        if (stat.type != FileSystemEntityType.file) {
          throw StateError('Input file is missing: $path');
        }
        inputs[path] = {
          'bytes': stat.size,
          'modified': stat.modified.toUtc().toIso8601String(),
        };
      }
      final journal = File(p.join(directory.path, 'plan.json'));
      if (await journal.exists()) {
        final saved = jsonDecode(await journal.readAsString()) as Map;
        if (jsonEncode(saved['plan']) != jsonEncode(plan) ||
            jsonEncode(saved['inputs']) != jsonEncode(inputs)) {
          throw StateError(
            'The saved plan or its input files changed. Start a new build to avoid mixing different data.',
          );
        }
      } else {
        await _write(journal, {'plan': plan, 'inputs': inputs});
      }
      final groups = (plan['groups'] as List).cast<Map<String, dynamic>>();
      final filters = groups.map((g) => g['filter'] as String).toSet().toList()
        ..sort();
      final referencePath = plan['referencePath'] as String;
      final referenceGroup = groups.firstWhere(
        (g) => (g['lights'] as List).any((f) => f['path'] == referencePath),
      );
      final results = <Map<String, dynamic>>[];
      for (var i = 0; i < filters.length; i++) {
        if (_stop) {
          throw StateError(
            'Stopped. Resume this folder to keep completed filters.',
          );
        }
        final filter = filters[i];
        final selected = groups.where((g) => g['filter'] == filter).toList();
        final receipt = File(p.join(directory.path, 'filter-$i.json'));
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
        onProgress?.call('Building $filter (${i + 1}/${filters.length})');
        _runId = 'darkroom-${DateTime.now().microsecondsSinceEpoch}';
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
            'align': {'model': 'affine', 'resampler': 'lanczos3'},
            'weighting': {'enabled': true, 'formula': 'snrSquared'},
            'normalization': {'enabled': true, 'mode': 'global'},
          },
          'clip': {'onlineClipLow': 4, 'onlineClipHigh': 4},
          'masterFitsPath': p.join(directory.path, 'full-$i.fits'),
          'previewPngPath': p.join(directory.path, 'full-$i.png'),
          'coverageFitsPath': p.join(directory.path, 'coverage-$i.fits'),
        });
        _runId = null;
        await _write(receipt, result);
        results.add(result);
      }
      if (_stop) {
        throw StateError(
          'Stopped before export. Resume to export completed filters.',
        );
      }
      onProgress?.call('Cropping all filters to full shared coverage');
      final deliveryReceipt = File(p.join(directory.path, 'delivery.json'));
      Map<String, dynamic> delivery;
      if (await deliveryReceipt.exists()) {
        delivery = Map<String, dynamic>.from(
          jsonDecode(await deliveryReceipt.readAsString()) as Map,
        );
      } else {
        // Each attempt has its own folder, so a partial export is never overwritten.
        delivery = await operation({
          'op': 'deliverUniform',
          'outputDir': p.join(
            directory.path,
            'masters-${DateTime.now().microsecondsSinceEpoch}',
          ),
          'masters': [
            for (var i = 0; i < results.length; i++)
              {
                'path': results[i]['masterPath'],
                'coveragePath': results[i]['coveragePath'],
                'filter':
                    '${filters[i].replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}-$i',
              },
          ],
        });
        final files = delivery['masters'] as List;
        for (var i = 0; i < files.length; i++) {
          files[i]['filter'] = filters[i];
        }
        await _write(deliveryReceipt, delivery);
      }
      final library = await masters.getAll();
      for (var i = 0; i < results.length; i++) {
        final file = (delivery['masters'] as List)[i] as Map;
        if (!await File(file['path'] as String).exists()) {
          throw StateError(
            'Exported ${filters[i]} master is missing. Restore it before resuming.',
          );
        }
        final existing = library
            .where((m) => m.masterFitsPath == file['path'])
            .firstOrNull;
        final masterId =
            existing?.id ??
            await masters.insertMaster(
              name: '${plan['target']} ${filters[i]}',
              masterFitsPath: file['path'] as String,
              previewPngPath: file['previewPath'] as String,
              filter: filters[i],
              channels: file['channels'] as int,
              status: IntegratedMasterStatus.finalized,
              accumulationMode: AccumulationMode.runningWeightedMean,
              width: delivery['width'] as int,
              height: delivery['height'] as int,
              frameCount: results[i]['frameCount'] as int,
              totalIntegrationSeconds:
                  (results[i]['totalIntegrationSec'] as num).toDouble(),
              settingsJson: jsonEncode(plan),
              statsJson: jsonEncode(results[i]),
            );
        final inputsByPath = <String, int>{
          for (final group in groups)
            for (final light in group['lights'] as List)
              light['path'] as String: light['id'] as int,
        };
        for (final frame in results[i]['folded'] as List) {
          await masters.recordFoldedFrame(
            masterId: masterId,
            imageId: inputsByPath[frame['path']]!,
            weight: (frame['weight'] as num?)?.toDouble(),
            alignmentResidualPx: (frame['rmsPx'] as num?)?.toDouble(),
          );
        }
        for (final frame in results[i]['skipped'] as List) {
          await masters.recordFoldedFrame(
            masterId: masterId,
            imageId: inputsByPath[frame['path']]!,
            accepted: false,
            rejectionReason: frame['reason'] as String,
          );
        }
      }
      final report = {'plan': plan, 'results': results, 'delivery': delivery};
      await _write(File(p.join(directory.path, 'report.json')), report);
      final audit = StringBuffer('Filter,Path,Included,Reason\n');
      String cell(Object? value) =>
          '"${value.toString().replaceAll('"', '""')}"';
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
      onProgress?.call('Masters ready');
      return report;
    } finally {
      _running = false;
      _runId = null;
    }
  }

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
  ),
);
