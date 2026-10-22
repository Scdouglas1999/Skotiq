import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart';

import '../job_manager.dart';
import '../response_helpers.dart';
import '../validation.dart';
import 'device_handlers.dart' show requestPrefersLegacyBlocking;
import 'filesystem_handlers.dart';

/// Handlers for imaging and plate solve endpoints
class ImagingHandlers {
  final ProviderContainer container;

  /// optional job manager. When wired, plate-solve returns
  /// `{jobId, status: queued}` immediately and the actual solve runs in
  /// the background. Null in legacy callers / tests that exercise the
  /// blocking shape.
  final JobManager? jobManager;

  /// Whether a frame a remote client saves here is also shown in this
  /// process's own image view. Only a desktop host has one; a headless host
  /// would decode and analyze every frame for no viewer.
  final bool showApiCapturesInPreview;

  ImagingHandlers(
    this.container, {
    this.jobManager,
    this.showApiCapturesInPreview = false,
  });

  /// Upper bound for `/api/imaging/star-crops` `maxCrops`. Crops are the top-N
  /// stars by SNR, each carrying base64 pixels; the value is encoded to a native
  /// `u32`. 200 is generous for a "cycle through stars" UI while bounding memory
  /// and blocking a negative (which would wrap to a huge count).
  static const int _maxStarCrops = 200;

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'ImagingHandlers');

  void _logWarning(String message) =>
      _logger.warning(message, source: 'ImagingHandlers');

  /// Remote clients must not upload full-frame pixel arrays for host processing.
  static const Map<String, Object> _hostOnlyProcessingBody = {
    'error':
        'Full-frame pixel upload is not supported on the remote API. '
        'Processing runs on the host; use host-authoritative endpoints.',
    'code': 'host_only_processing',
    'hostEndpoints': <String>[
      'POST /api/imaging/save-fits-from-capture',
      'GET /api/camera/last-image/jpeg',
      'GET /api/imaging/raw-data',
    ],
  };

  Response _rejectClientPixelUpload(String operation) {
    _logInfo('[API] $operation rejected (host-only processing)');
    return jsonBadRequest({..._hostOnlyProcessingBody, 'operation': operation});
  }

  // Plate solving

  Future<Response> handlePlateSolve(Request request) async {
    _logInfo('[API] POST /api/plate-solve');
    final payload = await readJsonObject(request);
    final imagePath = requireString(payload, 'imagePath');
    final ra = optionalDouble(payload, 'ra', min: 0, max: 360);
    final dec = optionalDouble(payload, 'dec', min: -90, max: 90);
    final fovDegrees = optionalDouble(payload, 'fov', min: 0.01, max: 180);
    final timeoutSeconds = optionalInt(
      payload,
      'timeoutSeconds',
      min: 1,
      max: 3600,
    );

    Future<PlateSolveResult> runSolve() {
      return container
          .read(plateSolveServiceProvider)
          .solveWithFallback(
            imagePath: imagePath,
            // The wire/native backend contract is degrees; PlateSolveService's
            // public hint contract is hours.
            hintRaHours: ra == null ? null : ra / 15.0,
            hintDecDegrees: dec,
            searchRadiusDegrees: fovDegrees,
            timeoutSeconds: timeoutSeconds,
          );
    }

    final mgr = jobManager;
    final preferLegacy = requestPrefersLegacyBlocking(request);
    if (mgr != null && !preferLegacy) {
      final job = mgr.start(
        operation: 'plate-solve',
        deviceId: null,
        work: (sink, cancellation) async {
          sink.update(null, 'Solving $imagePath');
          final solve = await runSolve();
          // There is no solver-process cancellation hook yet. Keep the job
          // running until the solver really exits; JobManager observes the
          // cancellation flag after this callback returns and transitions it
          // to cancelled instead of falsely orphaning live host work.
          if (cancellation.isCancelled) {
            throw const JobCancelledException(
              'Plate-solve cancellation requested by client',
            );
          }
          return _plateSolveJson(solve);
        },
      );
      return jsonOk({
        'jobId': job.jobId,
        'status': job.state.wireName,
        'operation': job.operation,
      });
    }

    final result = await runSolve();

    return jsonOk(_plateSolveJson(result));
  }

  /// Serializes a [PlateSolveResult] to the wire shape, including the WCS CD
  /// matrix and SIP distortion coefficients so remote (slave) clients can
  /// reconstruct distortion-corrected pixel<->sky mapping. The SIP arrays are
  /// emitted as plain `List<double>`; when the solve carries no SIP terms the
  /// orders are 0 and the coefficient lists are empty.
  static Map<String, Object?> _plateSolveJson(PlateSolveResult solve) {
    return {
      'success': solve.success,
      'ra': solve.ra,
      'dec': solve.dec,
      'pixelScale': solve.pixelScale,
      'rotation': solve.rotation,
      'fieldWidth': solve.fieldWidth,
      'fieldHeight': solve.fieldHeight,
      'solveTimeSecs': solve.solveTimeSecs,
      'error': solve.error,
      'cd11': solve.cd11,
      'cd12': solve.cd12,
      'cd21': solve.cd21,
      'cd22': solve.cd22,
      'sipAOrder': solve.sipAOrder,
      'sipBOrder': solve.sipBOrder,
      'sipApOrder': solve.sipApOrder,
      'sipBpOrder': solve.sipBpOrder,
      'sipACoeffs': solve.sipACoeffs.toList(),
      'sipBCoeffs': solve.sipBCoeffs.toList(),
      'sipApCoeffs': solve.sipApCoeffs.toList(),
      'sipBpCoeffs': solve.sipBpCoeffs.toList(),
    };
  }

  // Plate solver setup
  //
  // These run on the HOST, which owns the solver binaries + catalog. Remote
  // (phone) clients route their settings-page detect/verify/get/set calls
  // here so they operate on the host's filesystem and persist host config —
  // not the phone's. The host implementation goes through the imaging
  // backend (FfiBackend), which calls the Rust `api_platesolve_*`.

  /// GET /api/imaging/fits-dimensions?path=&lt;hostPath&gt;
  ///
  /// Returns the exact pixel dimensions of a host FITS file. Lets a remote
  /// client (e.g. the photometric-calibration wizard) get true width/height
  /// instead of estimating them from a star bounding box — the host reads the
  /// real header. Host paths only.
  Future<Response> handleGetFitsDimensions(Request request) async {
    final filePath = request.url.queryParameters['path'] ?? '';
    if (filePath.isEmpty) {
      throw BadRequestError(
        field: 'path',
        expected: 'string',
        message: "Missing 'path' query parameter (host FITS file path)",
      );
    }
    if (!await File(filePath).exists()) {
      return jsonError(
        code: 'fits_not_found',
        message: 'No FITS file at the requested host path',
        statusCode: HttpStatus.notFound,
      );
    }
    final fits = await bridge.apiReadFitsFile(filePath: filePath);
    return jsonOk({'width': fits.width, 'height': fits.height});
  }

  Future<Response> handleDetectPlateSolvers(Request request) async {
    _logInfo('[API] GET /api/plate-solver/detect');
    final backend = container.read(imagingBackendProvider);
    final detection = await backend.detectPlateSolvers();
    return jsonOk({
      'astapPath': detection.astapPath,
      'astrometryPath': detection.astrometryPath,
      'catalogName': detection.catalogName,
      'catalogMagnitudeLimit': detection.catalogMagnitudeLimit,
      'catalogPath': detection.catalogPath,
    });
  }

  Future<Response> handleVerifyPlateSolver(Request request) async {
    _logInfo('[API] POST /api/plate-solver/verify');
    final payload = await readJsonObject(request);
    final executablePath = requireString(payload, 'executablePath');

    final backend = container.read(imagingBackendProvider);
    final info = await backend.verifyPlateSolver(executablePath);
    return jsonOk({
      'path': info.path,
      'flavour': info.flavour,
      'versionLine': info.versionLine,
    });
  }

  Future<Response> handleGetPlateSolverConfig(Request request) async {
    _logInfo('[API] GET /api/plate-solver/config');
    final backend = container.read(imagingBackendProvider);
    final pref = await backend.getPlateSolverConfig();
    return jsonOk({
      'astapPath': pref.astapPath,
      'astrometryPath': pref.astrometryPath,
      'catalogPath': pref.catalogPath,
      'solverChoice': pref.choice.serialized,
    });
  }

  Future<Response> handleSetPlateSolverConfig(Request request) async {
    _logInfo('[API] POST /api/plate-solver/config');
    final payload = await readJsonObject(request);
    // Empty is a legitimate value for all three paths — "no Astrometry.net
    // installed" is the normal state for the many rigs that only run ASTAP,
    // and "" is precisely what handleGetPlateSolverConfig hands back for an
    // unset path. Requiring non-empty made the GET document one the POST
    // refused, so a remote client could not set the ASTAP catalog directory
    // at all: the save died with 400 invalid_request on the *other*, untouched
    // field and the setting silently stayed unset. Only the solver choice is
    // genuinely mandatory.
    final pref = PlateSolverPreference(
      astapPath: requireString(payload, 'astapPath', allowEmpty: true),
      astrometryPath: requireString(
        payload,
        'astrometryPath',
        allowEmpty: true,
      ),
      catalogPath: requireString(payload, 'catalogPath', allowEmpty: true),
      choice: PlateSolverChoice.fromSerialized(
        requireString(payload, 'solverChoice'),
      ),
    );

    final backend = container.read(imagingBackendProvider);
    await backend.setPlateSolverConfig(pref);
    return jsonOk({'status': 'saved'});
  }

  // Image processing

  Future<Response> handleGetImageStats(Request request) async {
    return _rejectClientPixelUpload('POST /api/imaging/stats');
  }

  Future<Response> handleAutoStretchImage(Request request) async {
    return _rejectClientPixelUpload('POST /api/imaging/stretch');
  }

  Future<Response> handleGetStarCrops(Request request) async {
    _logInfo('[API] GET /api/imaging/star-crops');
    final query = request.url.queryParameters;
    final deviceId = query['deviceId']?.trim();
    // Absent → 5. A supplied maxCrops must be a positive, bounded whole number:
    // it is encoded to a native u32, so a negative wraps to a huge count and an
    // unbounded value means unbounded base64 crops. Validate before the backend
    // read so an invalid request does no work. It's a GET, so we validate inline
    // rather than via readJsonObject.
    final maxCrops =
        optionalQueryInt(query, 'maxCrops', min: 1, max: _maxStarCrops) ?? 5;
    if (deviceId == null || deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }

    final backend = container.read(imagingBackendProvider);
    final crops = await backend.getStarCropsFromLastImage(
      deviceId,
      maxCrops: maxCrops,
    );

    return jsonOk({
      'crops': crops
          .map(
            (crop) => {
              'pixels_base64': crop.pixelsBase64,
              'width': crop.width,
              'height': crop.height,
              'hfr': crop.hfr,
              'snr': crop.snr,
            },
          )
          .toList(),
    });
  }

  Future<Response> handleDebayerImage(Request request) async {
    return _rejectClientPixelUpload('POST /api/imaging/debayer');
  }

  Future<Response> handleGetLastRawImageData(Request request) async {
    final deviceId = request.url.queryParameters['deviceId'] ?? '';
    // getLastRawImageData lives on DeviceBackend (raw pixels come from the
    // camera driver, not the imaging pipeline).
    final backend = container.read(deviceBackendProvider);
    final data = await backend.getLastRawImageData(deviceId);

    // Why: raw image data is returned as a binary stream rather than JSON
    // to avoid base64 encoding overhead for large frames. The backend values
    // are 16-bit pixels, so serialize each sample explicitly as little-endian
    // u16. Uint8List.fromList(data) would truncate every pixel to its low byte
    // and advertise half the required payload length.
    final bytes = Uint8List(data.length * Uint16List.bytesPerElement);
    final byteData = ByteData.sublistView(bytes);
    for (var i = 0; i < data.length; i++) {
      byteData.setUint16(
        i * Uint16List.bytesPerElement,
        data[i],
        Endian.little,
      );
    }
    return contentResponse(
      bytes,
      contentType: 'application/octet-stream',
      contentLength: bytes.length,
    );
  }

  Future<Response> handleSaveFitsFile(Request request) async {
    return _rejectClientPixelUpload('POST /api/imaging/save-fits');
  }

  Future<Response> handleSaveFitsFromLastCapture(Request request) async {
    _logInfo('[API] POST /api/imaging/save-fits-from-capture');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final filePath = requireString(payload, 'filePath');
    final headerJson = requireObject(payload, 'headerData');
    // FitsWriteHeader.fromJson hard-casts exposureTime/captureTimestamp/
    // frameType, so omitting (or mis-casing) any one of them turned into a 500
    // "type 'Null' is not a subtype of type 'num'/'String' in type cast".
    // Same defensive shape as profile_handlers.
    final FitsWriteHeader headerData;
    try {
      headerData = FitsWriteHeader.fromJson(headerJson);
    } on Object {
      throw BadRequestError(
        field: 'headerData',
        expected: 'fits_header with exposureTime, captureTimestamp, frameType',
        message: 'Malformed FITS header payload',
      );
    }

    final canonicalFilePath = await FileSystemHandlers(
      container,
    ).canonicalizeAllowedPath(filePath);
    if (canonicalFilePath == null) {
      throw HandlerFailure(
        code: 'path_not_allowed',
        message:
            'The FITS output path is outside Skotiq\'s configured '
            'filesystem roots',
        statusCode: HttpStatus.forbidden,
      );
    }

    // Remote workflows (notably Flat Wizard) compose date/filter subfolders on
    // the controller, but the path belongs to this host. Create the parent here
    // at the authority boundary rather than asking the controller filesystem to
    // mirror a host path.
    await Directory(path.dirname(canonicalFilePath)).create(recursive: true);

    final backend = container.read(imagingBackendProvider);
    await backend.saveFitsFromLastCapture(
      deviceId: deviceId,
      filePath: canonicalFilePath,
      headerData: headerData,
    );
    if (showApiCapturesInPreview) {
      unawaited(
        _showSavedCaptureInPreview(deviceId, canonicalFilePath, headerData),
      );
    }
    return jsonOk({'status': 'saved'});
  }

  /// Every remote capture, keeper or scratch, ends with this save, so it is
  /// where the host's own image view learns of a frame it did not expose. The
  /// frame is published exactly as the host's own captures are; nothing is
  /// saved again.
  Future<void> _showSavedCaptureInPreview(
    String deviceId,
    String filePath,
    FitsWriteHeader header,
  ) async {
    try {
      final result = await container
          .read(backendProvider)
          .cameraGetLastImage(deviceId);
      if (result == null) return;
      final frameType = FrameType.values.firstWhere(
        (type) =>
            type.displayName.toLowerCase() == header.frameType.toLowerCase() ||
            type.name.toLowerCase() == header.frameType.toLowerCase(),
        orElse: () => FrameType.light,
      );
      final DateTime capturedAt;
      try {
        capturedAt = parseUtcTimestamp(header.captureTimestamp);
      } on FormatException {
        _logWarning(
          '[API] Saved capture has an unreadable DATE-OBS '
          '"${header.captureTimestamp}"; not shown in the image view',
        );
        return;
      }
      final imageData = capturedImageDataFromResult(
        capturedImage: result,
        settings: ExposureSettings(
          exposureTime: header.exposureTime,
          gain: header.gain ?? 0,
          offset: header.offset ?? 0,
          binningX: header.binX ?? 1,
          binningY: header.binY ?? 1,
          filter: header.filter,
          frameType: frameType,
        ),
        capturedAt: capturedAt,
        targetName: header.objectName,
        filePath: filePath,
      );
      container
          .read(capturePreviewPublisherProvider)
          .publish(container, imageData, deviceId);
    } on Object catch (e) {
      _logWarning(
        '[API] Could not show a remote capture in the image view: $e',
      );
    }
  }

  Future<Response> handleClearDeviceImage(
    Request request,
    String deviceId,
  ) async {
    _logInfo('[API] DELETE /api/imaging/device-image/$deviceId');
    // clearDeviceImage lives on DeviceBackend (operates on the camera
    // driver's last-image cache).
    final backend = container.read(deviceBackendProvider);
    await backend.clearDeviceImage(deviceId);
    return jsonOk({'status': 'cleared'});
  }

  Future<Response> handleCalibrateImageFile(Request request) async {
    _logInfo('[API] POST /api/imaging/calibrate-file');
    final payload = await readJsonObject(request);
    final lightPath = requireString(payload, 'lightPath');
    final darkPath = optionalString(payload, 'darkPath');
    final flatPath = optionalString(payload, 'flatPath');
    final biasPath = optionalString(payload, 'biasPath');
    final outputPath = requireString(payload, 'outputPath');

    if (darkPath == null && flatPath == null && biasPath == null) {
      throw BadRequestError(
        field: 'calibrationFrames',
        expected: 'at least one of darkPath, flatPath, biasPath',
        message: 'No calibration frames provided',
      );
    }

    for (final entry in [
      ('dark', darkPath),
      ('flat', flatPath),
      ('bias', biasPath),
    ]) {
      final framePath = entry.$2;
      if (framePath != null && !File(framePath).existsSync()) {
        throw BadRequestError(
          field: '${entry.$1}Path',
          expected: 'existing host file',
          message: '${entry.$1} frame file not found: $framePath',
        );
      }
    }

    if (!File(lightPath).existsSync()) {
      throw BadRequestError(
        field: 'lightPath',
        expected: 'existing host file',
        message: 'Light frame file not found: $lightPath',
      );
    }

    final outDir = Directory(path.dirname(outputPath));
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    await bridge.apiCalibrateImageFile(
      lightPath: lightPath,
      darkPath: darkPath,
      flatPath: flatPath,
      biasPath: biasPath,
      outputPath: outputPath,
    );

    return jsonOk({
      'outputPath': outputPath,
      'darkApplied': darkPath != null,
      'flatApplied': flatPath != null,
      'biasApplied': biasPath != null,
      'darkUsed': darkPath,
      'flatUsed': flatPath,
      'biasUsed': biasPath,
    });
  }
}
