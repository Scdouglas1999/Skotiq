import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../job_manager.dart';
import '../response_helpers.dart';
import '../validation.dart';

part 'session_handlers/thumbnail_handlers.dart';

/// Handlers for polar alignment and session/image endpoints
class SessionHandlers {
  final ProviderContainer container;

  /// Optional job manager used by the thumbnail-backfill endpoint in the
  /// companion part file. Polar-alignment Start is deliberately not queued:
  /// it is a short admission command whose errors must reach the caller before
  /// the UI claims the run started; ongoing progress already streams via WS.
  final JobManager? jobManager;

  SessionHandlers(this.container, {this.jobManager});

  /// Upper bound for the `/api/images?producingNodeId=` thumbnail `limit`. One
  /// sequence node produces at most a few hundred to low-thousand frames per
  /// session; 5000 is a generous ceiling that still blocks a negative (SQLite
  /// `LIMIT -1` = unbounded) or an absurdly large scan.
  static const int _maxProducingNodeLimit = 5000;

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'SessionHandlers');

  /// Parse an integer ID from a URL path segment, raising BadRequestError on
  /// malformed input. Without this, `int.parse` throws FormatException and the
  /// middleware would surface a 500 — but the caller's mistake is a 400.
  int _parsePathId(String value, String field) {
    final id = int.tryParse(value);
    if (id == null) {
      throw BadRequestError(
        field: field,
        expected: 'integer',
        message: 'Path segment is not a valid integer',
      );
    }
    return id;
  }

  // Polar alignment

  Future<Response> handleStartPolarAlignment(Request request) async {
    _logInfo('[API] POST /api/polar-alignment/start');
    final payload = await readJsonObject(request);
    // Bound every physical parameter before it reaches PolarAlignmentConfig /
    // the native alignment routine. Without bounds a negative exposure,
    // binning:0, or a negative timeout is admitted and produces invalid
    // hardware work or a downstream 500 instead of a clean 400.
    final exposureTime = requireDouble(
      payload,
      'exposure_time',
      min: 0.001,
      max: 3600,
    );
    final stepSize = requireDouble(payload, 'step_size', min: 0.001, max: 360);
    final binning = requireInt(payload, 'binning', min: 1, max: 16);
    final isNorth = requireBool(payload, 'is_north');
    final manualRotation = requireBool(payload, 'manual_rotation');
    final rotateEast = requireBool(payload, 'rotate_east');
    final gain = optionalInt(payload, 'gain', min: 0);
    final offset = optionalInt(payload, 'offset', min: 0);
    final solveTimeout = optionalDouble(
      payload,
      'solve_timeout',
      min: 1,
      max: 3600,
    );
    final startFromCurrent = optionalBool(payload, 'start_from_current');
    final autoCompleteThreshold = optionalDouble(
      payload,
      'auto_complete_threshold',
      min: 0.001,
      max: 3600,
    );

    final config = PolarAlignmentConfig(
      exposureTime: exposureTime,
      stepSize: stepSize,
      binning: binning,
      isNorth: isNorth,
      manualRotation: manualRotation,
      rotateEast: rotateEast,
      gain: gain,
      offset: offset,
      // The omitted-parameter default is the model's, so a headless run and
      // the desktop dialog cannot drift apart.
      solveTimeout: solveTimeout ?? const PolarAlignmentConfig().solveTimeout,
      startFromCurrent: startFromCurrent ?? true,
      autoCompleteThreshold: autoCompleteThreshold ?? 30,
    );
    await container
        .read(polarAlignmentStateProvider.notifier)
        .startAlignment(config);
    return jsonOk({"status": "started"});
  }

  Future<Response> handleStopPolarAlignment(Request request) async {
    _logInfo('[API] POST /api/polar-alignment/stop');
    // Force the backend stop when this process did not initiate the run (for
    // example, a native sequencer node). Runs admitted through this handler
    // still use the notifier's single-flight stop + history persistence.
    await container
        .read(polarAlignmentStateProvider.notifier)
        .stopAlignment(forceBackend: true);
    return jsonOk({"status": "stopped"});
  }

  Future<Response> handleStartAllSkyPolarAlignment(Request request) async {
    _logInfo('[API] POST /api/polar-alignment/all-sky/start');
    final payload = await readJsonObject(request);
    // Bound physical parameters (see handleStartPolarAlignment).
    final exposureTime = requireDouble(
      payload,
      'exposure_time',
      min: 0.001,
      max: 3600,
    );
    final solveTimeout = requireDouble(
      payload,
      'solve_timeout',
      min: 1,
      max: 3600,
    );
    final binning = requireInt(payload, 'binning', min: 1, max: 16);
    final isNorth = requireBool(payload, 'is_north');
    final acceptanceThresholdArcsec = requireDouble(
      payload,
      'acceptance_threshold_arcsec',
      min: 0.001,
      max: 3600,
    );
    final iterationCadenceSecs = requireDouble(
      payload,
      'iteration_cadence_secs',
      min: 0.1,
      max: 3600,
    );
    final gain = optionalInt(payload, 'gain', min: 0);
    final offset = optionalInt(payload, 'offset', min: 0);

    final config = PolarAlignmentConfig(
      exposureTime: exposureTime,
      solveTimeout: solveTimeout,
      binning: binning,
      isNorth: isNorth,
      iterationCadenceSecs: iterationCadenceSecs,
      autoCompleteThreshold: acceptanceThresholdArcsec,
      gain: gain,
      offset: offset,
    );
    await container
        .read(polarAlignmentStateProvider.notifier)
        .startAllSkyAlignment(config);
    return jsonOk({"status": "started"});
  }

  // Session images

  Future<Response> handleGetSessionImages(
    Request request,
    String sessionId,
  ) async {
    _logInfo('[API] GET /api/sessions/$sessionId/images');
    final sid = _parsePathId(sessionId, 'sessionId');
    final database = container.read(databaseProvider);
    final images = await database.imagesDao.getImagesForSession(sid);
    final imagesJson = images.map((image) => image.toJson()).toList();

    return jsonOk({"images": imagesJson});
  }

  Future<Response> handleGetAllImages(Request request) async {
    _logInfo('[API] GET /api/images');
    final query = request.url.queryParameters;
    final producingNodeIdParam = query['producingNodeId'];
    final producingRunIdParam = query['producingRunId'];
    final targetIdParam = query['targetId'];

    if (producingNodeIdParam != null) {
      final producingNodeId = producingNodeIdParam.trim();
      if (producingNodeId.isEmpty) {
        throw BadRequestError(
          field: 'producingNodeId',
          expected: 'non-blank string',
          message: 'producingNodeId must not be blank',
        );
      }
      // Absent → 100. A supplied limit must be a positive, bounded whole number:
      // a negative maps to SQLite `LIMIT -1` (unbounded scan) and a huge value
      // is unbounded work. Validate before even resolving the database provider.
      final limit =
          optionalQueryInt(
            query,
            'limit',
            min: 1,
            max: _maxProducingNodeLimit,
          ) ??
          100;
      final producingRunId = producingRunIdParam?.trim();
      if (producingRunIdParam != null && producingRunId!.isEmpty) {
        throw BadRequestError(
          field: 'producingRunId',
          expected: 'non-blank string',
          message: 'producingRunId must not be blank when supplied',
        );
      }
      final database = container.read(databaseProvider);
      final thumbs = await database.imagesDao.getImagesByProducingNode(
        producingNodeId: producingNodeId,
        producingRunId: producingRunId,
        limit: limit,
      );
      return jsonOk({'images': thumbs.map(_producingThumbnailToJson).toList()});
    }

    if (targetIdParam != null) {
      final targetId = int.tryParse(targetIdParam);
      if (targetId == null) {
        throw BadRequestError(
          field: 'targetId',
          expected: 'integer',
          message: 'targetId query parameter must be a valid integer',
        );
      }
      final database = container.read(databaseProvider);
      final images = await database.imagesDao.getImagesForTarget(targetId);
      return jsonOk({'images': images.map((image) => image.toJson()).toList()});
    }

    final database = container.read(databaseProvider);
    final images = await database.imagesDao.getAllImages();
    return jsonOk({'images': images.map((image) => image.toJson()).toList()});
  }

  Future<Response> handleGetImageById(Request request, String imageId) async {
    _logInfo('[API] GET /api/images/$imageId');
    final iid = _parsePathId(imageId, 'imageId');
    final database = container.read(databaseProvider);
    final image = await database.imagesDao.getImageById(iid);
    if (image == null) {
      return jsonNotFound({'error': 'Image not found: $iid'});
    }
    return jsonOk({'image': image.toJson()});
  }

  Future<Response> handleCreateImage(Request request) async {
    _logInfo('[API] POST /api/images');
    final payload = await readJsonObject(request);
    final database = container.read(databaseProvider);

    final capturedAtMs = payload['capturedAt'];
    final capturedAt = capturedAtMs is int
        ? DateTime.fromMillisecondsSinceEpoch(capturedAtMs, isUtc: true)
        : (DateTime.tryParse(capturedAtMs?.toString() ?? '') ?? DateTime.now())
              .toUtc();

    // #2 — honour fileSize from the payload if supplied; otherwise
    // try to stat the on-disk file. The latter only succeeds when the
    // POSTed filePath happens to be local to the server (e.g. a sidecar
    // helper that wrote the FITS via NFS and then registered the row);
    // when it doesn't exist we leave NULL and the row still goes in.
    int? fileSize = optionalInt(payload, 'fileSize');
    final postedPath = requireString(payload, 'filePath');
    if (fileSize == null && postedPath.isNotEmpty) {
      try {
        final f = File(postedPath);
        if (await f.exists()) {
          fileSize = await f.length();
        }
      } catch (e) {
        // The file exists check passed but length() still failed —
        // unusual enough to log so the operator knows the row went in
        // without a size.
        _logger.warning(
          'handleCreateImage: failed to stat $postedPath: $e — row will '
          'be inserted with NULL file_size',
          source: 'SessionHandlers',
        );
      }
    }

    final id = await database.imagesDao.createImage(
      CapturedImagesCompanion.insert(
        filePath: postedPath,
        fileName: requireString(payload, 'fileName'),
        fileFormat: Value(optionalString(payload, 'fileFormat') ?? 'fits'),
        fileSize: Value(fileSize),
        sessionId: Value(optionalInt(payload, 'sessionId')),
        targetId: Value(optionalInt(payload, 'targetId')),
        frameType: Value(requireString(payload, 'frameType')),
        // Every numeric below is PERSISTED into captured_images and then read by
        // analytics, image grading, the dark/flat matcher and plate-solve
        // history. Unbounded, this endpoint accepted (and would have stored)
        // mountRa 9999, mountAltitude -4000, coolerPower 5000, binX 0,
        // exposureDuration -60 and gain -500 — execution ran past all of them
        // and only tripped on an unrelated FK. Bounds mirror the ones already
        // applied to the same quantities elsewhere in this file (gain/offset
        // min: 0) and in db_read_handlers (ra 0..24, dec -90..90).
        exposureDuration: requireDouble(payload, 'exposureDuration', min: 0),
        gain: Value(optionalInt(payload, 'gain', min: 0)),
        offset: Value(optionalInt(payload, 'offset', min: 0)),
        binX: Value(optionalInt(payload, 'binX', min: 1, max: 16) ?? 1),
        binY: Value(optionalInt(payload, 'binY', min: 1, max: 16) ?? 1),
        filter: Value(optionalString(payload, 'filter')),
        sensorTemp: Value(
          optionalDouble(payload, 'sensorTemp', min: -100, max: 100),
        ),
        coolerPower: Value(
          optionalDouble(payload, 'coolerPower', min: 0, max: 100),
        ),
        hfr: Value(optionalDouble(payload, 'hfr', min: 0, max: 1000)),
        starCount: Value(optionalInt(payload, 'starCount', min: 0)),
        background: Value(optionalDouble(payload, 'background', min: 0)),
        noise: Value(optionalDouble(payload, 'noise', min: 0)),
        qualityScore: Value(
          optionalDouble(payload, 'qualityScore', min: 0, max: 100),
        ),
        guidingRmsRa: Value(optionalDouble(payload, 'guidingRmsRa', min: 0)),
        guidingRmsDec: Value(optionalDouble(payload, 'guidingRmsDec', min: 0)),
        guidingRmsTotal: Value(
          optionalDouble(payload, 'guidingRmsTotal', min: 0),
        ),
        mountRa: Value(optionalDouble(payload, 'mountRa', min: 0, max: 24)),
        mountDec: Value(optionalDouble(payload, 'mountDec', min: -90, max: 90)),
        mountAltitude: Value(
          optionalDouble(payload, 'mountAltitude', min: -90, max: 90),
        ),
        mountAzimuth: Value(
          optionalDouble(payload, 'mountAzimuth', min: 0, max: 360),
        ),
        focuserPosition: Value(optionalInt(payload, 'focuserPosition', min: 0)),
        focuserTemp: Value(
          optionalDouble(payload, 'focuserTemp', min: -100, max: 100),
        ),
        rotatorAngle: Value(
          optionalDouble(payload, 'rotatorAngle', min: -360, max: 360),
        ),
        isPlateSolved: Value(optionalBool(payload, 'isPlateSolved') ?? false),
        solvedRa: Value(optionalDouble(payload, 'solvedRa', min: 0, max: 24)),
        solvedDec: Value(
          optionalDouble(payload, 'solvedDec', min: -90, max: 90),
        ),
        solvedRotation: Value(
          optionalDouble(payload, 'solvedRotation', min: -360, max: 360),
        ),
        solvedPixelScale: Value(
          optionalDouble(payload, 'solvedPixelScale', min: 0),
        ),
        capturedAt: capturedAt,
        isAccepted: Value(optionalBool(payload, 'isAccepted') ?? true),
        rejectionReason: Value(optionalString(payload, 'rejectionReason')),
      ),
    );

    final producingNodeId = optionalString(payload, 'producingNodeId');
    if (producingNodeId != null && producingNodeId.isNotEmpty) {
      await database.imagesDao.stampProducingNode(
        imageId: id,
        producingNodeId: producingNodeId,
        producingRunId: optionalString(payload, 'producingRunId'),
        runtimeGrade: optionalString(payload, 'runtimeGrade'),
        eccentricity: optionalDouble(payload, 'eccentricity'),
      );
    }

    // schedule fire-and-forget sidecar generation for the new row.
    // Skips when filePath is empty (no FITS to encode) or the file isn't
    // on disk — the service logs both cases at warning severity. The
    // capture is fully recorded by this point so a sidecar failure does
    // not impact the response.
    if (postedPath.isNotEmpty) {
      try {
        final sidecarService = container.read(thumbnailSidecarServiceProvider);
        sidecarService.scheduleSidecarWrite(
          imageId: id,
          fitsPath: postedPath,
          imagesDao: database.imagesDao,
        );
      } catch (e) {
        _logger.warning(
          'handleCreateImage: failed to schedule sidecar for image $id '
          '($postedPath): $e',
          source: 'SessionHandlers',
        );
      }
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.capturedImage,
      action: HostMutationAction.created,
      entityId: id.toString(),
    );
    return jsonOk({'status': 'created', 'id': id});
  }

  Future<Response> handleUpdateImage(Request request, String imageId) async {
    _logInfo('[API] PUT /api/images/$imageId');
    final iid = _parsePathId(imageId, 'imageId');
    final payload = await readJsonObject(request);
    final database = container.read(databaseProvider);
    final imagesDao = database.imagesDao;

    final existing = await imagesDao.getImageById(iid);
    if (existing == null) {
      return jsonNotFound({'error': 'Image not found: $iid'});
    }

    if (payload.containsKey('filePath')) {
      await imagesDao.updateImageFilePath(
        iid,
        requireString(payload, 'filePath'),
      );
    }

    if (payload.containsKey('isAccepted')) {
      if (payload['isAccepted'] == false) {
        await imagesDao.rejectImage(
          iid,
          optionalString(payload, 'rejectionReason') ?? 'rejected',
        );
      } else if (payload['isAccepted'] == true) {
        await imagesDao.acceptImage(iid);
      }
    }

    if (payload.containsKey('isPlateSolved') &&
        payload['isPlateSolved'] == true) {
      // Route through the repository (NOT the DAO directly) so the solve-persist
      // event fires onSolvedFrameFold — the appliance is the authoritative atlas
      // host, so a solve arriving via the headless API must fold into Your Sky
      // and run the First Light difference scan, exactly like the desktop path.
      // Accept + persist the full CD matrix + SIP so the fold and difference scan
      // use the real distortion rather than CD-from-scale geometry.
      final cd11 = optionalDouble(payload, 'solvedCd1_1');
      final cd12 = optionalDouble(payload, 'solvedCd1_2');
      final cd21 = optionalDouble(payload, 'solvedCd2_1');
      final cd22 = optionalDouble(payload, 'solvedCd2_2');
      await container
          .read(imagingRecordsRepositoryProvider)
          .updatePlateSolveResult(
            iid,
            solvedRa: requireDouble(payload, 'solvedRa'),
            solvedDec: requireDouble(payload, 'solvedDec'),
            solvedRotation: requireDouble(payload, 'solvedRotation'),
            solvedPixelScale: requireDouble(payload, 'solvedPixelScale'),
            solvedCd1_1: cd11,
            solvedCd1_2: cd12,
            solvedCd2_1: cd21,
            solvedCd2_2: cd22,
            solvedSip: optionalString(payload, 'solvedSip'),
          );
    }

    if (payload.containsKey('producingNodeId') ||
        payload.containsKey('producingRunId') ||
        payload.containsKey('runtimeGrade') ||
        payload.containsKey('eccentricity')) {
      await imagesDao.stampProducingNode(
        imageId: iid,
        producingNodeId: optionalString(payload, 'producingNodeId'),
        producingRunId: optionalString(payload, 'producingRunId'),
        runtimeGrade: optionalString(payload, 'runtimeGrade'),
        eccentricity: optionalDouble(payload, 'eccentricity'),
      );
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.capturedImage,
      action: HostMutationAction.updated,
      entityId: iid.toString(),
    );
    return jsonOk({'status': 'updated'});
  }

  /// Legacy `/api/images/recent?limit=<n>` for mobile clients that pre-date
  /// the unified `/api/images` route. Why kept: existing pinned mobile builds
  /// hit this URL and we cannot push an update to all installed clients
  /// before the v2.5 release. Returns the same shape the GUI web_server used
  /// (`images` + `count`) so the mobile UI tile counters keep working.
  Future<Response> handleGetRecentImages(Request request) async {
    _logInfo('[API] GET /api/images/recent');
    final limitParam = request.url.queryParameters['limit'];
    final limit = limitParam == null
        ? null
        : requireQueryInt(
            request.url.queryParameters,
            'limit',
            min: 1,
            max: 1000,
          );
    final database = container.read(databaseProvider);
    if (limit != null) {
      final images = await database.imagesDao.getAllImagesPaginated(
        limit: limit,
        offset: 0,
      );
      final imagesJson = images.map((image) => image.toJson()).toList();
      return jsonOk({'images': imagesJson, 'count': imagesJson.length});
    }
    final images = await database.imagesDao.getAllImages();
    final imagesJson = images.map((image) => image.toJson()).toList();
    return jsonOk({'images': imagesJson, 'count': imagesJson.length});
  }

  Future<Response> handleGetStandaloneImages(Request request) async {
    _logInfo('[API] GET /api/images/standalone');
    final database = container.read(databaseProvider);
    final images = await database.imagesDao.getAllImages();
    final standalone = images
        .where((image) => image.sessionId == null)
        .toList(growable: false);
    return jsonOk({
      'images': standalone.map((image) => image.toJson()).toList(),
    });
  }

  Future<Response> handleExportSessionJson(
    Request request,
    String sessionId,
  ) async {
    return _exportSessionFile(
      request,
      sessionId,
      fileType: 'json',
      exportAction: (service, sid) => service.exportToJson(sid),
      contentType: jsonContentType,
    );
  }

  Future<Response> handleExportSessionCsv(
    Request request,
    String sessionId,
  ) async {
    return _exportSessionFile(
      request,
      sessionId,
      fileType: 'csv',
      exportAction: (service, sid) => service.exportToCsv(sid),
      contentType: 'text/csv; charset=utf-8',
    );
  }

  Future<Response> handleExportSessionHtml(
    Request request,
    String sessionId,
  ) async {
    return _exportSessionFile(
      request,
      sessionId,
      fileType: 'html',
      exportAction: (service, sid) => service.exportToHtml(sid),
      contentType: 'text/html; charset=utf-8',
    );
  }

  Future<Response> handleExportSession(
    Request request,
    String sessionId,
    String format,
  ) async {
    switch (format.toLowerCase()) {
      case 'json':
        return handleExportSessionJson(request, sessionId);
      case 'csv':
        return handleExportSessionCsv(request, sessionId);
      case 'html':
        return handleExportSessionHtml(request, sessionId);
      default:
        return jsonBadRequest({
          'error': 'Unsupported export format',
          'supportedFormats': ['json', 'csv', 'html'],
        });
    }
  }

  /// Sidecar-backed thumbnail with ETag caching.
  ///
  /// The capture pipeline writes a `{filePath}.thumb.jpg` next to every
  /// FITS at insert time (best-effort, fire-and-forget). This handler
  /// serves that sidecar with strong-validator ETag headers so repeat
  /// gallery loads from a mobile client hit a `304 Not Modified` instead
  /// of redoing the FITS → JPEG encode.
  ///
  /// Cold-read fallback: when the sidecar is missing (legacy row, or the
  /// fire-and-forget write hasn't landed yet), we synthesise the JPEG via
  /// the FFI path AND persist the result as a sidecar so the next call
  /// is fast. This is the self-healing branch.
  ///
  /// Limitation (documented for ops): if the operator replaces a FITS
  /// out-of-band (e.g. a re-stretched copy), the sidecar's mtime is no
  /// longer a true validator. The `POST /api/images/{id}/regenerate-
  /// thumbnail` endpoint is the escape hatch — it forces a re-encode and
  /// rewrites the sidecar so the ETag changes.
  Future<Response> _exportSessionFile(
    Request request,
    String sessionId, {
    required String fileType,
    required Future<String> Function(
      SessionExportService service,
      int sessionId,
    )
    exportAction,
    required String contentType,
  }) async {
    _logInfo('[API] GET /api/sessions/$sessionId/export/$fileType');
    final sid = _parsePathId(sessionId, 'sessionId');
    final database = container.read(databaseProvider);
    final service = SessionExportService(
      sessionsDao: database.sessionsDao,
      imagesDao: database.imagesDao,
    );
    final filePath = await exportAction(service, sid);
    final file = File(filePath);

    if (!await file.exists()) {
      return jsonNotFound({'error': 'Export not found for session $sessionId'});
    }

    final fileLength = await file.length();
    return attachmentResponse(
      file.openRead(),
      fileName: file.uri.pathSegments.last,
      contentType: contentType,
      contentLength: fileLength,
    );
  }

  Map<String, dynamic> _producingThumbnailToJson(ProducingNodeThumbnail thumb) {
    return {
      'id': thumb.id,
      'filePath': thumb.filePath,
      'fileName': thumb.fileName,
      'fileFormat': 'fits',
      'fileSize': null,
      'sessionId': null,
      'targetId': null,
      'frameType': thumb.frameType,
      'exposureDuration': thumb.exposureDuration,
      'gain': null,
      'offset': null,
      'binX': 1,
      'binY': 1,
      'filter': thumb.filter,
      'sensorTemp': null,
      'coolerPower': null,
      'hfr': thumb.hfr,
      'starCount': thumb.starCount,
      'background': null,
      'noise': null,
      'qualityScore': null,
      'guidingRmsRa': null,
      'guidingRmsDec': null,
      'guidingRmsTotal': null,
      'mountRa': null,
      'mountDec': null,
      'mountAltitude': null,
      'mountAzimuth': null,
      'pierSide': null,
      'focuserPosition': null,
      'focuserTemp': null,
      'rotatorAngle': null,
      'isPlateSolved': false,
      'solvedRa': null,
      'solvedDec': null,
      'solvedRotation': null,
      'solvedPixelScale': null,
      'capturedAt': thumb.capturedAt.millisecondsSinceEpoch,
      'createdAt': thumb.capturedAt.millisecondsSinceEpoch,
      'isAccepted': thumb.isAccepted,
      'rejectionReason': thumb.rejectionReason,
      'producingNodeId': thumb.producingNodeId,
      'producingRunId': thumb.producingRunId,
      'runtimeGrade': thumb.runtimeGrade,
      'eccentricity': thumb.eccentricity,
    };
  }
}
