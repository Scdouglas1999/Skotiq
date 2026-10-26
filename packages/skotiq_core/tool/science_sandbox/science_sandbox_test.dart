// Science sandbox: runs Skotiq's own per-frame science pipeline over real FITS
// frames outside the rig, against a scratch database.
//
// Driven by tool/science_sandbox/run-science.sh, which writes a JSON config and
// points SKOTIQ_SANDBOX_CONFIG at it. Without that variable the test skips, so
// a plain `flutter test` never runs it.
//
// What runs is production code: the drift database, ImagesDao.insertSequenceFrame,
// SessionStateNotifier.startSession, ScienceProcessingService.processCapturedFrame
// (including its blind plate solve and the updatePlateSolveResult hook that
// drives the Your Sky fold, the First Light scan and the narrator), all through
// a real ProviderContainer and the release native bridge. The harness only adds
// observation: it waits for the fire-and-forget atlas fold to finish, pins the
// narrator clock to the frame's capture time, and dumps what was stored.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/database/daos/sky_atlas_dao.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/models/science/science_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/narrator_provider.dart';
import 'package:skotiq_core/src/providers/science_status_provider.dart';
import 'package:skotiq_core/src/providers/session_provider.dart';
import 'package:skotiq_core/src/providers/sky_atlas_provider.dart';
import 'package:skotiq_core/src/services/logging_service.dart';
import 'package:skotiq_core/src/services/science/narrator/narrator_service.dart';
import 'package:skotiq_core/src/services/science/science_processing_service.dart';
import 'package:skotiq_core/src/services/science/science_status.dart';
import 'package:skotiq_core/src/services/sky_atlas/sky_atlas_models.dart';
import 'package:skotiq_core/src/services/sky_atlas/sky_atlas_seam.dart';
import 'package:skotiq_core/src/services/sky_atlas/sky_atlas_service.dart';

import 'fits_header.dart';
import 'sandbox_config.dart';

/// Tables whose rows are keyed by `captured_image_id`, dumped per frame.
const _perFrameTables = <String>[
  'photometry_measurements',
  'frame_photometric_calibration',
  'transparency_samples',
  'psf_field_tiles',
  'science_frame_quality_metrics',
  'science_tile_metrics',
  'astrometry_residual_vectors',
  'moving_object_candidates',
  'transient_detections',
  'narrator_events',
];

/// app_settings keys never copied from the rig database: Windows paths and
/// anything that would make the sandbox talk to the outside world.
bool _skipRigSetting(String key) {
  const exact = {
    'astap_path',
    'astrometry_path',
    'default_image_directory',
    'image_output_path',
    'sequences_path',
    'database_path',
    'logs_path',
    'web_server_enabled',
    'discord_webhook',
    'pushover_key',
    'pushover_user',
    'notifications_enabled',
    'auto_connect_equipment',
    'auto_discover_on_launch',
  };
  if (exact.contains(key)) return true;
  if (key.startsWith('notification')) return true;
  if (key.startsWith('hub') || key.contains('secret')) return true;
  return false;
}

/// Atlas service that signals when an auto-fold finishes, so the harness can
/// wait for the fire-and-forget solve hook before dumping the frame. Behavior
/// is the production [SkyAtlasService]; only completion is observed.
class _ObservedSkyAtlasService extends SkyAtlasService {
  _ObservedSkyAtlasService({
    required super.dao,
    required super.seam,
    required super.logger,
    required super.atlasRootResolver,
    super.targetResolver,
  });

  final _done =
      StreamController<
        ({int imageId, AtlasFoldSummary? summary, Object? error})
      >.broadcast();
  Stream<({int imageId, AtlasFoldSummary? summary, Object? error})> get folds =>
      _done.stream;

  @override
  Future<AtlasFoldSummary?> autoFoldCapturedImage({
    required db.CapturedImage image,
    required int imageWidth,
    required int imageHeight,
    SolvedWcsDistortion distortion = const SolvedWcsDistortion(),
    AtlasInterp interp = AtlasInterp.lanczos3,
  }) async {
    try {
      final summary = await super.autoFoldCapturedImage(
        image: image,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        distortion: distortion,
        interp: interp,
      );
      _done.add((imageId: image.id, summary: summary, error: null));
      return summary;
    } catch (e) {
      _done.add((imageId: image.id, summary: null, error: e));
      rethrow;
    }
  }
}

Map<String, Object?> _rowMap(drift.QueryRow row) {
  final out = <String, Object?>{};
  row.data.forEach((k, v) {
    out[k] = v is double && !v.isFinite ? v.toString() : v;
  });
  return out;
}

String _json(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

Object? _jsonSafe(Object? v) {
  if (v is double && !v.isFinite) return v.toString();
  if (v is DateTime) return v.toUtc().toIso8601String();
  if (v is Map) return v.map((k, val) => MapEntry('$k', _jsonSafe(val)));
  if (v is Iterable) return v.map(_jsonSafe).toList();
  return v;
}

void main() {
  final configPath = Platform.environment['SKOTIQ_SANDBOX_CONFIG'];

  test(
    'science sandbox run',
    () async {
      final cfg = SandboxConfig.load(configPath!);
      await _run(cfg);
    },
    skip: configPath == null
        ? 'Set SKOTIQ_SANDBOX_CONFIG (use tool/science_sandbox/run-science.sh)'
        : false,
    timeout: Timeout.none,
  );
}

Future<void> _run(SandboxConfig cfg) async {
  final out = Directory(cfg.outDir)..createSync(recursive: true);
  final framesOut = Directory('${cfg.outDir}/frames')..createSync();
  final progress = File(
    '${cfg.outDir}/progress.log',
  ).openWrite(mode: FileMode.append);
  void say(String line) {
    final stamped = '${DateTime.now().toIso8601String()} $line';
    progress.writeln(stamped);
    // ignore: avoid_print
    print(stamped);
  }

  // Native bridge + native settings storage, the way the desktop boot does it.
  final dataDir = Directory(cfg.dataDir)..createSync(recursive: true);
  final logDir = Directory('${dataDir.path}/logs')..createSync(recursive: true);
  await bridge.NativeBridge.init(logDirectory: logDir.path);
  if (!bridge.NativeBridge.isNativeAvailable) {
    throw StateError('libskotiq_bridge.so did not load');
  }
  final profileDir = Directory('${dataDir.path}/profile')
    ..createSync(recursive: true);
  await bridge.NativeBridge.apiInitProfileStorage(storagePath: profileDir.path);
  await bridge.NativeBridge.apiInitSettingsStorage(
    storagePath: profileDir.path,
  );
  bridge.apiPlatesolveSetConfig(
    config: bridge.PlateSolverConfigPayload(
      astapPath: cfg.astapPath,
      astrometryPath: '',
      catalogPath: cfg.astapDbDir,
      solverChoice: 'astap',
    ),
  );
  final detected = bridge.apiPlatesolveDetect();
  say(
    'bridge v${bridge.apiGetVersion()} astap=${detected.astapPath} '
    'catalog=${detected.catalogName} (${detected.catalogPath})',
  );

  _ObservedSkyAtlasService? atlas;
  final container = ProviderContainer(
    overrides: [
      skyAtlasServiceProvider.overrideWith((ref) {
        final targetsDao = ref.watch(targetsDaoProvider);
        return atlas = _ObservedSkyAtlasService(
          dao: ref.watch(skyAtlasDaoProvider),
          seam: ref.watch(skyAtlasSeamProvider),
          logger: ref.watch(loggingServiceProvider),
          atlasRootResolver: defaultAtlasRoot,
          targetResolver: (targetId) async {
            final target = await targetsDao.getTargetById(targetId);
            if (target == null) return null;
            return AtlasTargetRef(
              name: target.name,
              raDeg: target.ra * 15.0,
              decDeg: target.dec,
            );
          },
        );
      }),
    ],
  );

  container.read(skyAtlasServiceProvider);
  final logs = <Map<String, Object?>>[];
  final logger = container.read(loggingServiceProvider);
  await logger.ensureInitialized();
  final logSub = logger.logEntryStream.listen((e) {
    if (e.level.index >= LogLevel.info.index) {
      logs.add({
        't': e.timestamp.toUtc().toIso8601String(),
        'level': e.level.name,
        'source': e.source,
        'message': e.message.length > 4000
            ? '${e.message.substring(0, 4000)}…'
            : e.message,
      });
    }
  });

  final database = container.read(databaseProvider);
  await database.customSelect('SELECT 1').get();

  // Seed settings from the rig database copy, then the sandbox overrides.
  if (cfg.rigDb != null) {
    final escaped = cfg.rigDb!.replaceAll("'", "''");
    await database.customStatement("ATTACH DATABASE '$escaped' AS rig");
    final rows = await database
        .customSelect('SELECT key, value FROM rig.app_settings')
        .get();
    final seed = <String, String>{};
    for (final r in rows) {
      final key = r.read<String>('key');
      if (_skipRigSetting(key)) continue;
      seed[key] = r.read<String>('value');
    }
    await database.customStatement('DETACH DATABASE rig');
    await container.read(settingsDaoProvider).setSettings(seed);
    say('seeded ${seed.length} settings from ${cfg.rigDb}');
  }
  final overrides = <String, String>{
    'astap_path': cfg.astapPath,
    ...cfg.settingOverrides,
  };
  if (cfg.differential != null) {
    final d = cfg.differential!;
    overrides['science.photometry.differential_active'] = 'true';
    overrides['science.photometry.target_anchor'] = jsonEncode(d['target']);
    overrides['science.photometry.comparison_anchors'] = jsonEncode(
      d['comparisons'] ?? const [],
    );
  }
  await container.read(settingsDaoProvider).setSettings(overrides);

  await container.read(backendProvider.notifier).useLocalBackend();

  // Frames, sorted by capture time.
  final frames = <FitsFrameInfo>[];
  for (final path in cfg.frames) {
    try {
      frames.add(FitsFrameInfo.read(path));
    } catch (e) {
      say('SKIP $path: header unreadable: $e');
    }
  }
  frames.sort((a, b) => a.captureEnd.compareTo(b.captureEnd));
  if (frames.isEmpty) throw StateError('no readable frames');

  // Target + session.
  final first = frames.first;
  final targetName = first.object ?? cfg.sessionName;
  final targetId = await _ensureTarget(database, targetName, first);
  final sessionId = await _ensureSession(
    container,
    database,
    cfg.sessionName,
    targetName,
    targetId,
    first,
  );
  say(
    'session ${cfg.sessionName} id=$sessionId target=$targetName id=$targetId',
  );

  if (cfg.movingObjects) {
    await container
        .read(scienceDaoProvider)
        .upsertSessionConfig(
          ScienceSessionConfig(
            sessionId: sessionId,
            movingObjectsEnabled: true,
          ),
        );
    say('moving objects ON for session $sessionId (sandbox only)');
  }

  // Narrator: keep the session's service alive and pin its clock to the frame
  // being processed, so cooldowns and windows see night time, not replay time.
  var simNow = first.captureEnd;
  final narratorSub = container.listen<NarratorService>(
    narratorServiceProvider,
    (_, next) => next.setClock(() => simNow),
    fireImmediately: true,
  );

  // Keep the stage-result provider alive for the narrator's listener.
  final stageSub = container.listen(
    scienceProcessingLatestStageProvider,
    (_, __) {},
  );

  final tracker = container.read(scienceProcessingStatusTrackerProvider);
  final service = container.read(scienceProcessingServiceProvider);
  final imagesDao = container.read(imagesDaoProvider);

  final rigRows = cfg.rigDb == null
      ? const <String, List<Map<String, Object?>>>{}
      : await _loadRigImageRows(database, cfg.rigDb!);

  final summary = <Map<String, Object?>>[];
  final recentCopies = <String>[];
  var index = 0;
  for (final frame in frames) {
    index++;
    final name = frame.baseName;
    final jsonPath = '${framesOut.path}/${name.replaceAll('.fits', '')}.json';
    if (cfg.skipDone && File(jsonPath).existsSync()) {
      say('[$index/${frames.length}] $name already done, skipping');
      continue;
    }
    final frameSw = Stopwatch()..start();
    logs.clear();
    final errors = <String>[];

    // Work on a copy: the pipeline writes MAGZP/TRANSPAR back into the FITS.
    final workDir = Directory('${cfg.dbDir}/frames')..createSync();
    final workPath = '${workDir.path}/$name';
    if (!File(workPath).existsSync()) {
      await File(frame.path).copy(workPath);
    }

    final rig = _matchRigRow(rigRows[name], frame);
    final maxIds = <String, int>{};
    for (final t in [
      'narrator_events',
      'transient_detections',
      'sky_atlas_folds',
    ]) {
      maxIds[t] = await _maxId(database, t);
    }

    simNow = frame.captureEnd;
    final imageId = await imagesDao.insertSequenceFrame(
      filePath: workPath,
      fileName: name,
      fileFormat: 'fits',
      exposureDuration: frame.exposure,
      capturedAt: frame.captureEnd,
      isAccepted: rig?['is_accepted'] == null
          ? true
          : (rig!['is_accepted'] as int) == 1,
      producingNodeId: 'science-sandbox',
      producingRunId: 'sandbox-${cfg.sessionName}',
      runtimeGrade: rig?['runtime_grade'] as String?,
      rejectionReason: rig?['rejection_reason'] as String?,
      sessionId: sessionId,
      targetId: targetId,
      filter: frame.filter,
      frameType: 'light',
      hfr: (rig?['hfr'] as num?)?.toDouble(),
      starCount: rig?['star_count'] as int?,
      eccentricity: (rig?['eccentricity'] as num?)?.toDouble(),
      gain: frame.gain,
      offset: frame.offset,
      binX: frame.binX,
      binY: frame.binY,
      sensorTemp: frame.ccdTemp,
      mountRa: frame.raDeg == null ? null : frame.raDeg! / 15.0,
      mountDec: frame.decDeg,
      mountAltitude: frame.altitude,
      pierSide: rig?['pier_side'] as String?,
      focuserPosition: frame.focusPos,
      focuserTemp: frame.focusTemp,
    );

    final foldWait = atlas!.folds
        .firstWhere((f) => f.imageId == imageId)
        .timeout(Duration(seconds: cfg.foldWaitSeconds));

    final procSw = Stopwatch()..start();
    final stages = <ScienceStage, ScienceStageResult>{};
    final statusSub = tracker.events.listen((e) {
      final r = e.stageResult;
      if (r.capturedImageId == imageId) stages[r.stage] = r;
    });
    try {
      await service.processCapturedFrame(
        imagePath: workPath,
        capturedImageId: imageId,
        sessionId: sessionId,
      );
    } catch (e) {
      errors.add('processCapturedFrame threw: $e');
    }
    final processingMs = procSw.elapsedMilliseconds;

    final solved = await database
        .customSelect(
          'SELECT is_plate_solved FROM captured_images WHERE id = ?',
          variables: [drift.Variable<int>(imageId)],
        )
        .getSingle();
    Map<String, Object?>? fold;
    final foldSw = Stopwatch()..start();
    if (solved.read<bool>('is_plate_solved')) {
      try {
        final f = await foldWait;
        fold = {
          'summary': f.summary == null
              ? null
              : _jsonSafe(_foldSummaryJson(f.summary!)),
          'error': f.error?.toString(),
        };
      } on TimeoutException {
        errors.add('atlas fold did not finish within ${cfg.foldWaitSeconds}s');
      }
    } else {
      unawaited(
        foldWait.catchError(
          (_) => (imageId: imageId, summary: null, error: null),
        ),
      );
    }
    final foldWaitMs = foldSw.elapsedMilliseconds;
    // Let the narrator's DB-watch streams emit and persist.
    await Future<void>.delayed(Duration(milliseconds: cfg.settleMs));
    await statusSub.cancel();

    final record = await _dumpFrame(
      database: database,
      imageId: imageId,
      sessionId: sessionId,
      frame: frame,
      maxIds: maxIds,
    );
    record['rigRow'] = rig;
    record['stages'] = stages.isEmpty
        ? null
        : {
            for (final e in stages.entries)
              e.key.name: {
                'outcome': e.value.outcome.name,
                'note': e.value.note,
                'ms': e.value.durationMs,
              },
          };
    record['atlasFold'] = fold;
    record['timing'] = {
      'processCapturedFrameMs': processingMs,
      'foldWaitMs': foldWaitMs,
      'totalMs': frameSw.elapsedMilliseconds,
    };
    record['logs'] = List.of(logs);
    record['errors'] = errors;
    File(jsonPath).writeAsStringSync(_json(_jsonSafe(record)));

    final bundleCounts = (record['bundle'] as Map).map(
      (k, v) => MapEntry(k, (v as List).length),
    );
    final line = {
      'i': index,
      'file': name,
      'imageId': imageId,
      'filter': frame.filter,
      'solved': solved.read<bool>('is_plate_solved'),
      'ms': frameSw.elapsedMilliseconds,
      'counts': bundleCounts,
      'narrator': (record['narratorEvents'] as List).length,
      'firstLight': (record['firstLight'] as List).length,
      'folds': (record['atlasFoldRows'] as List).length,
      'stages': record['stages'] == null
          ? null
          : (record['stages'] as Map).map(
              (k, v) => MapEntry(k, (v as Map)['outcome']),
            ),
      'errors': errors.length,
      'warnings': logs.where((l) => l['level'] != 'info').length,
    };
    summary.add(line);
    say('[$index/${frames.length}] ${jsonEncode(line)}');

    recentCopies.add(workPath);
    while (!cfg.keepFrames && recentCopies.length > cfg.keepRecent) {
      final old = recentCopies.removeAt(0);
      try {
        File(old).deleteSync();
      } catch (_) {}
    }
  }

  // Session bundle exactly as GET /api/science/session/<id>/bundle builds it.
  final scienceDao = database.scienceDao;
  final bundle = {
    'photometry': (await scienceDao.getPhotometryForSession(
      sessionId,
    )).map((r) => r.toJson()).toList(),
    'calibrations': (await scienceDao.getCalibrationsForSession(
      sessionId,
    )).map((r) => r.toJson()).toList(),
    'transparency': (await scienceDao.getTransparencyForSession(
      sessionId,
    )).map((r) => r.toJson()).toList(),
    'psfTiles': (await scienceDao.getPsfTilesForSession(
      sessionId,
    )).map((r) => r.toJson()).toList(),
    'frameQuality': (await scienceDao.getFrameQualityMetricsForSession(
      sessionId,
    )).map((r) => r.toJson()).toList(),
    'tileMetrics': (await scienceDao.getTileMetricsForSession(
      sessionId,
    )).map((r) => r.toJson()).toList(),
    'residuals': (await scienceDao.getResidualsForSession(
      sessionId,
    )).map((r) => r.toJson()).toList(),
    'movingObjects': (await scienceDao.getMovingObjectsForSession(
      sessionId,
    )).map((r) => r.toJson()).toList(),
    'lineRatios': (await scienceDao.getLineRatiosForSession(
      sessionId,
    )).map((r) => r.toJson()).toList(),
  };
  File(
    '${out.path}/session-bundle.json',
  ).writeAsStringSync(jsonEncode(_jsonSafe(bundle)));
  final narrator = await database
      .customSelect(
        'SELECT * FROM narrator_events WHERE session_id = ? ORDER BY id',
        variables: [drift.Variable<int>(sessionId)],
      )
      .get();
  File(
    '${out.path}/narrator-events.json',
  ).writeAsStringSync(_json(narrator.map(_rowMap).toList()));
  File('${out.path}/summary.json').writeAsStringSync(
    _json({
      'sessionId': sessionId,
      'sessionName': cfg.sessionName,
      'dbDir': cfg.dbDir,
      'frames': summary,
      'bundleCounts': bundle.map((k, v) => MapEntry(k, v.length)),
      'narratorEvents': narrator.length,
    }),
  );
  say(
    'DONE session=$sessionId bundle=${jsonEncode(bundle.map((k, v) => MapEntry(k, v.length)))} narrator=${narrator.length}',
  );

  await logSub.cancel();
  narratorSub.close();
  stageSub.close();
  await progress.flush();
  await progress.close();
  container.dispose();
}

Map<String, Object?> _foldSummaryJson(AtlasFoldSummary s) => {
  'tilesTouched': s.tilesTouched,
  'totalFramesFolded': s.totalFramesFolded,
  'framesSkippedNoCoverage': s.framesSkippedNoCoverage,
};

Future<int> _maxId(db.SkotiqDatabase database, String table) async {
  final row = await database
      .customSelect('SELECT COALESCE(MAX(id), 0) AS m FROM $table')
      .getSingle();
  return row.read<int>('m');
}

Future<Map<String, Object?>> _dumpFrame({
  required db.SkotiqDatabase database,
  required int imageId,
  required int sessionId,
  required FitsFrameInfo frame,
  required Map<String, int> maxIds,
}) async {
  final bundle = <String, Object?>{};
  for (final t in _perFrameTables) {
    if (t == 'narrator_events' || t == 'transient_detections') continue;
    final rows = await database
        .customSelect(
          'SELECT * FROM $t WHERE captured_image_id = ? ORDER BY id',
          variables: [drift.Variable<int>(imageId)],
        )
        .get();
    bundle[t] = rows.map(_rowMap).toList();
  }
  Future<List<Map<String, Object?>>> newRows(String t) async {
    final rows = await database
        .customSelect(
          'SELECT * FROM $t WHERE id > ? ORDER BY id',
          variables: [drift.Variable<int>(maxIds[t]!)],
        )
        .get();
    return rows.map(_rowMap).toList();
  }

  final image = await database
      .customSelect(
        'SELECT * FROM captured_images WHERE id = ?',
        variables: [drift.Variable<int>(imageId)],
      )
      .getSingle();
  final imageMap = _rowMap(image);
  return {
    'file': frame.path,
    'header': frame.header,
    'capturedImageId': imageId,
    'sessionId': sessionId,
    'capturedImage': imageMap,
    'wcs': {
      'isPlateSolved': imageMap['is_plate_solved'],
      'raHours': imageMap['solved_ra'],
      'decDeg': imageMap['solved_dec'],
      'rotationDeg': imageMap['solved_rotation'],
      'pixelScale': imageMap['solved_pixel_scale'],
      'cd': [
        imageMap['solved_cd1_1'],
        imageMap['solved_cd1_2'],
        imageMap['solved_cd2_1'],
        imageMap['solved_cd2_2'],
      ],
      'sip': imageMap['solved_sip'] is String
          ? _tryJson(imageMap['solved_sip'] as String)
          : null,
    },
    'bundle': bundle,
    'narratorEvents': await newRows('narrator_events'),
    'firstLight': await newRows('transient_detections'),
    'atlasFoldRows': await newRows('sky_atlas_folds'),
  };
}

Object? _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return s;
  }
}

Future<int> _ensureTarget(
  db.SkotiqDatabase database,
  String name,
  FitsFrameInfo frame,
) async {
  final existing = await database
      .customSelect(
        'SELECT id FROM targets WHERE name = ? LIMIT 1',
        variables: [drift.Variable<String>(name)],
      )
      .getSingleOrNull();
  if (existing != null) return existing.read<int>('id');
  return database.targetsDao.createTarget(
    db.TargetsCompanion.insert(
      name: name,
      catalogId: drift.Value(name),
      ra: (frame.objRaDeg ?? frame.raDeg ?? 0) / 15.0,
      dec: frame.objDecDeg ?? frame.decDeg ?? 0,
    ),
  );
}

Future<int> _ensureSession(
  ProviderContainer container,
  db.SkotiqDatabase database,
  String sessionName,
  String targetName,
  int targetId,
  FitsFrameInfo frame,
) async {
  final existing = await database
      .customSelect(
        'SELECT id FROM imaging_sessions WHERE name = ? ORDER BY id DESC LIMIT 1',
        variables: [drift.Variable<String>(sessionName)],
      )
      .getSingleOrNull();
  final notifier = container.read(sessionStateProvider.notifier);
  if (existing != null) {
    final id = existing.read<int>('id');
    notifier.mirrorHostSession(
      SessionState(
        isActive: true,
        startTime: DateTime.now(),
        targetName: targetName,
        targetRa: (frame.objRaDeg ?? 0) / 15.0,
        targetDec: frame.objDecDeg,
        dbSessionId: id,
      ),
    );
    return id;
  }
  await notifier.startSession(
    targetName: sessionName,
    targetRa: (frame.objRaDeg ?? 0) / 15.0,
    targetDec: frame.objDecDeg,
    targetId: targetId,
  );
  final id = container.read(sessionStateProvider).dbSessionId!;
  // The session row is named after the sandbox run so it can be found again.
  await database.customStatement(
    'UPDATE imaging_sessions SET name = ? WHERE id = ?',
    [sessionName, id],
  );
  return id;
}

/// Rig captured_images rows by file name (the rig counter restarts per
/// session, so one name can map to several rows).
Future<Map<String, List<Map<String, Object?>>>> _loadRigImageRows(
  db.SkotiqDatabase database,
  String rigDb,
) async {
  final escaped = rigDb.replaceAll("'", "''");
  await database.customStatement("ATTACH DATABASE '$escaped' AS rig");
  try {
    final rows = await database
        .customSelect(
          'SELECT id, file_name, captured_at, hfr, star_count, eccentricity, '
          'is_accepted, runtime_grade, rejection_reason, pier_side, '
          'is_plate_solved, solved_ra, solved_dec, solved_rotation, '
          'solved_pixel_scale, session_id FROM rig.captured_images',
        )
        .get();
    final byName = <String, List<Map<String, Object?>>>{};
    for (final r in rows) {
      final m = _rowMap(r);
      byName.putIfAbsent(m['file_name'] as String, () => []).add(m);
    }
    return byName;
  } finally {
    await database.customStatement('DETACH DATABASE rig');
  }
}

Map<String, Object?>? _matchRigRow(
  List<Map<String, Object?>>? candidates,
  FitsFrameInfo frame,
) {
  if (candidates == null || candidates.isEmpty) return null;
  final end = frame.captureEnd.millisecondsSinceEpoch ~/ 1000;
  Map<String, Object?>? best;
  var bestDelta = 1 << 30;
  for (final c in candidates) {
    final at = c['captured_at'] as int?;
    if (at == null) continue;
    final delta = (at - end).abs();
    if (delta < bestDelta) {
      bestDelta = delta;
      best = c;
    }
  }
  // Rows more than 10 minutes away belong to another frame with the same name.
  return bestDelta <= 600 ? best : null;
}
