import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../job_manager.dart';
import '../response_helpers.dart';
import '../validation.dart';

/// Headless control surface for the **post-session integration / finishing**
/// core — the "review and integrate last night's data" workflow.
///
/// Every operation here runs on the HOST (the appliance that captured the subs)
/// against HOST file paths and HOST session ids. Pixel data is never uploaded
/// from a remote client: a tablet hands the host the on-disk paths of the subs /
/// masters and the host's Rust pipeline does the compute. This mirrors the
/// host-only-processing policy of the imaging-stats and live-stacking surfaces.
///
/// These are long-running compute ops (a full integration can run for minutes),
/// so each is backed by the [JobManager]: the action POST returns
/// `{jobId, status: queued}` immediately and the client polls `/api/jobs/{id}`
/// (or watches the WS `job` event stream) for completion. The job's `result`
/// payload is the exact JSON envelope the native FFI returned — the client's
/// [PostSessionSeam] result classes decode it verbatim.
///
/// The handlers forward to the same native bridge free functions
/// (`apiIntegrateSession`, `apiAnalyzeNight`, `apiBuildMasterFlat`,
/// `apiColorCalibrate`, `apiExtractBackground`, `apiCombineChannels`,
/// `apiDrizzleIntegrate`) that [BridgePostSessionSeam] wraps, so the host result
/// is byte-for-byte identical whether the op was driven locally or remotely.
///
/// Mosaic stitching (`api_stitch_mosaic`) is intentionally NOT exposed here; it
/// is owned by the separate mosaic surface.
class PostSessionHandlers {
  static const _autoIntegrateSettingKey = 'post_session.auto_integrate';

  final ProviderContainer container;

  /// Long-running ops register as [JobManager] jobs so the action POST returns
  /// immediately. Required for this surface — every op is potentially minutes
  /// long; constructing without it is a programmer error.
  final JobManager jobManager;

  PostSessionHandlers(this.container, {required this.jobManager});

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'PostSessionHandlers');

  /// GET /api/post-session/settings
  Future<Response> handleGetSettings(Request request) async {
    final raw = await container
        .read(settingsDaoProvider)
        .getSetting(_autoIntegrateSettingKey);
    // An unset key reads as on, as NightEndAutomationSettings reads it.
    return jsonOk({'autoIntegrate': raw != 'false'});
  }

  /// POST /api/post-session/settings
  Future<Response> handleUpdateSettings(Request request) async {
    final body = await readJsonObject(request);
    final enabled = requireBool(body, 'autoIntegrate');
    await container
        .read(settingsDaoProvider)
        .setSetting(_autoIntegrateSettingKey, enabled.toString());
    return jsonOk({'autoIntegrate': enabled});
  }

  /// The scalar fields of a job result, for the log line that records it.
  static String _outcomeSummary(Map<String, Object?> result) {
    final scalars = result.entries
        .where((e) => e.value is num || e.value is String || e.value is bool)
        .take(8)
        .map((e) => '${e.key}=${e.value}');
    return scalars.join(', ');
  }

  /// Decode a native JSON envelope to a `Map<String, dynamic>`, the job-result
  /// shape clients decode. Mirrors `BridgePostSessionSeam._decodeObject`.
  Map<String, dynamic> _decodeObject(String json) {
    final decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) return decoded;
    throw FormatException(
      'post-session native call returned a non-object JSON payload',
      json,
    );
  }

  /// Encode a decoded request body for the bridge, refusing a number JSON
  /// cannot carry before the encoder gets to it.
  ///
  /// `jsonDecode` turns an overflowing literal like `1e400` into
  /// `double.infinity`, and `jsonEncode` then throws
  /// `JsonUnsupportedObjectError`. Inside the job closure that surfaced as a
  /// FAILED JOB whose whole explanation was "Converting object to an encodable
  /// object failed: Infinity" — the request itself answered `200 queued`, the
  /// sentence named neither the field nor the index, and the native guard
  /// written for exactly this input
  /// (`post_session/helpers.rs`: "exposuresSec[0] is …, which is not a number
  /// of seconds") could never run, because the payload never reached the
  /// bridge.
  ///
  /// So the encoding happens HERE, in the request path, where a refusal is a
  /// typed 400 naming the field by its own JSON path. A body that survives this
  /// holds only finite numbers, and [jsonEncode] cannot fail on it.
  String _encodeArgs(Map<String, dynamic> args) {
    _refuseNonFiniteNumbers(args, '');
    return jsonEncode(args);
  }

  /// Walk a decoded JSON body and refuse the first non-finite number, naming
  /// the path that reaches it (`exposuresSec[0]`, `settings.sigmaHigh`).
  void _refuseNonFiniteNumbers(Object? value, String path) {
    if (value is double && !value.isFinite) {
      final field = path.isEmpty ? 'body' : path;
      throw BadRequestError(
        field: field,
        expected: 'number',
        message:
            '$field is $value, which is not a finite number; every numeric '
            'field must be a finite value',
      );
    }
    if (value is Map) {
      value.forEach((key, entry) {
        _refuseNonFiniteNumbers(entry, path.isEmpty ? '$key' : '$path.$key');
      });
      return;
    }
    if (value is List) {
      for (var index = 0; index < value.length; index++) {
        _refuseNonFiniteNumbers(value[index], '$path[$index]');
      }
    }
  }

  /// Refuse an `exposuresSec` list the bridge is going to refuse anyway,
  /// while the answer can still be a 400 instead of a job id.
  ///
  /// `exposures_per_light` (`bridge/src/api/post_session/helpers.rs`) requires
  /// one exposure per light or none at all, and every entry finite and `>= 0`.
  /// It runs INSIDE the bridge call, which happens after [JobManager.start] has
  /// already minted and returned an id — so a body the server could read as
  /// malformed on arrival answered `200 {"status":"queued"}` and only turned
  /// out to be refused on a later `/api/jobs/{id}` poll. A job id is a claim
  /// that the request's inputs were shaped right; two exposures for three
  /// lights never were.
  ///
  /// The value sentences are the native ones verbatim, in the native ORDER
  /// (shape, then arity, then per-entry values), so the operator who reads this
  /// 400 and the operator who reads the job error read the same words.
  ///
  /// **The type faults are refused here too, in this surface's own words.** An
  /// `exposuresSec` that is a map, a string, `null`, or a list holding a
  /// string never reaches `exposures_per_light` at all: `serde` refuses it
  /// while decoding the args struct, which happens inside the bridge call and
  /// therefore after the id has been minted and returned. Those bodies used to
  /// answer `200 {"status":"queued"}` and turn out refused only on a later
  /// `/api/jobs/{id}` poll, with `invalid type: map, expected a sequence at
  /// line 1 column 214` for an explanation — a deserializer's note about a byte
  /// offset, naming neither the field nor the entry. There is no native
  /// sentence to copy for these, so the ones below are this handler's own, in
  /// the guard's vocabulary: the field, the index, what arrived, and what the
  /// entry has to be.
  ///
  /// Scope matches the guard's own in the two places the bridge genuinely
  /// accepts anything: an ABSENT `exposuresSec` is the documented "unknown"
  /// (`#[serde(default)]` fills an empty vector, reported as 0 s), an empty
  /// list means the same, and the arity half is skipped when [lightsField]
  /// carries no list to count against — that shape is the deserializer's own
  /// to name.
  void _refuseExposuresSec(
    Map<String, dynamic> args, {
    required String lightsField,
  }) {
    if (!args.containsKey('exposuresSec')) return;
    final exposures = args['exposuresSec'];
    if (exposures is! List) {
      throw BadRequestError(
        field: 'exposuresSec',
        expected: 'list of numbers',
        message:
            'exposuresSec is ${_jsonValueName(exposures)}, not a list of '
            'exposure seconds; supply one entry per light frame, or omit '
            'exposuresSec entirely',
      );
    }
    if (exposures.isEmpty) return;
    final lights = args[lightsField];
    if (lights is List && exposures.length != lights.length) {
      throw BadRequestError(
        field: 'exposuresSec',
        expected: 'one entry per light frame',
        message:
            'exposuresSec has ${exposures.length} entries but ${lights.length} '
            'light frames were supplied; supply one exposure per light, or '
            'omit exposuresSec entirely',
      );
    }
    for (var index = 0; index < exposures.length; index++) {
      final seconds = exposures[index];
      if (seconds is! num) {
        throw BadRequestError(
          field: 'exposuresSec[$index]',
          expected: 'number',
          message:
              'exposuresSec[$index] is ${_jsonValueName(seconds)}, which is '
              'not a number of seconds; every entry must be a finite value '
              '>= 0',
        );
      }
      // A non-finite entry is named by [_refuseNonFiniteNumbers] for what it
      // is, which is what the bridge says about it too — `-Infinity` is not a
      // negative exposure, it is not a number of seconds at all.
      if (seconds.isFinite && seconds < 0) {
        throw BadRequestError(
          field: 'exposuresSec[$index]',
          expected: 'number',
          message:
              'exposuresSec[$index] is $seconds, a negative exposure; every '
              'entry must be a finite value >= 0',
        );
      }
    }
  }

  /// What a decoded JSON value IS, in the words a refusal prints.
  ///
  /// The scalars carry their value as well as their kind — "the string
  /// \"60\"" is the half of `exposuresSec: ["60"]` an operator has to see to
  /// fix it, and it is what `serde` names too. The last arm is a map: the body
  /// came from [readJsonObject], so `jsonDecode` produced it, and null, bool,
  /// num, String and List are already answered above.
  static String _jsonValueName(Object? value) {
    if (value == null) return 'null';
    if (value is bool) return 'the boolean $value';
    if (value is num) return 'the number $value';
    if (value is String) return 'the string "$value"';
    if (value is List) return 'a list';
    return 'a JSON object';
  }

  /// Register [work] as a JobManager job and return the queued-job envelope.
  Future<Response> _startJob(
    String operation,
    Future<Map<String, Object?>> Function() work,
  ) async {
    final job = jobManager.start(
      operation: operation,
      deviceId: null,
      work: (sink, cancellation) async {
        sink.update(null, operation);
        final started = DateTime.now();
        // The native pipeline has no cancellation hook. Do not transition the
        // job to cancelled while host CPU work is still running; await its real
        // exit, then honour the pending cancellation instead of publishing the
        // discarded result as success.
        final Map<String, Object?> result;
        try {
          result = await work();
        } catch (e) {
          _logger.error(
            '[API] $operation failed after '
            '${DateTime.now().difference(started).inSeconds} s: $e',
            source: 'PostSessionHandlers',
          );
          rethrow;
        }
        if (cancellation.isCancelled) {
          _logInfo(
            '[API] $operation finished after cancellation was requested',
          );
          throw const JobCancelledException(
            'Post-session operation cancellation requested by client',
          );
        }
        _logInfo(
          '[API] $operation succeeded after '
          '${DateTime.now().difference(started).inSeconds} s: '
          '${_outcomeSummary(result)}',
        );
        return result;
      },
    );
    return jsonOk({
      'jobId': job.jobId,
      'status': job.state.wireName,
      'operation': job.operation,
    });
  }

  // Integrate session — one-shot batch integration of a sub list into a linear
  // FITS master. Wraps `api_integrate_session`.

  /// POST /api/post-session/integrate
  /// Body: the `IntegrateSessionArgs` JSON shape
  /// `{ lightPaths, reference?, exposuresSec?, calibration, settings, output }`
  /// (host paths). Returns `{jobId}`; the job result is the
  /// `IntegrateSessionResult` envelope.
  Future<Response> handleIntegrateSession(Request request) async {
    _logInfo('[API] POST /api/post-session/integrate');
    final args = await readJsonObject(request);
    _refuseExposuresSec(args, lightsField: 'lightPaths');
    final argsJson = _encodeArgs(args);
    return _startJob('post-session.integrate', () async {
      final out = await bridge.apiIntegrateSession(argsJson: argsJson);
      return _decodeObject(out);
    });
  }

  // Drizzle integrate — variable-pixel linear reconstruction onto a scaled
  // grid. Wraps `api_drizzle_integrate`.

  /// POST /api/post-session/drizzle
  /// Body: the `DrizzleIntegrateArgs` JSON shape
  /// `{ frames: [{ fitsPath, transform, weight }], refW, refH, config, bayer?,
  /// calibration?, outputFits, coverageFits?, coveragePngPath?,
  /// previewPngPath? }` (host paths).
  /// Returns `{jobId}`; the job result is
  /// `{outputPath, coveragePath?, coveragePngPath?, outWidth, outHeight,
  /// channels, previewPngPath?}`.
  Future<Response> handleDrizzleIntegrate(Request request) async {
    _logInfo('[API] POST /api/post-session/drizzle');
    final args = await readJsonObject(request);
    final argsJson = _encodeArgs(args);
    return _startJob('post-session.drizzle', () async {
      final out = await bridge.apiDrizzleIntegrate(argsJson: argsJson);
      return _decodeObject(out);
    });
  }

  // Analyze night — marginal-SNR integration curve + keep/cull recommendation.
  // Wraps `api_analyze_night` (a pure analytic predictor; no pixels integrated).

  /// POST /api/post-session/analyze-night
  /// Body: `{ qualities: [...], weights: [...], exposuresS: [...],
  /// optimizer?: { aggressiveness?, minKeep? } }`. Returns `{jobId}`; the job
  /// result is the `IntegrationCurve` envelope.
  Future<Response> handleAnalyzeNight(Request request) async {
    _logInfo('[API] POST /api/post-session/analyze-night');
    final args = await readJsonObject(request);
    // Validate the three aligned arrays exist (the native side requires them);
    // shape is otherwise pass-through.
    requireList<dynamic>(args, 'qualities');
    requireList<dynamic>(args, 'weights');
    requireList<dynamic>(args, 'exposuresS');
    final argsJson = _encodeArgs(args);
    return _startJob('post-session.analyze-night', () async {
      final out = await bridge.apiAnalyzeNight(argsJson: argsJson);
      return _decodeObject(out);
    });
  }

  // Build master flat — unit-mean master flat from raw flats. Wraps
  // `api_build_master_flat`.

  /// POST /api/post-session/build-master-flat
  /// Body: the `BuildMasterFlatArgs` JSON shape (host paths). Returns `{jobId}`;
  /// the job result is the `BuildMasterFlatResult` envelope.
  Future<Response> handleBuildMasterFlat(Request request) async {
    _logInfo('[API] POST /api/post-session/build-master-flat');
    final args = await readJsonObject(request);
    final argsJson = _encodeArgs(args);
    return _startJob('post-session.build-master-flat', () async {
      final out = await bridge.apiBuildMasterFlat(argsJson: argsJson);
      return _decodeObject(out);
    });
  }

  // Color calibrate — solve + apply a per-channel white balance from the
  // matched colour-indexed stars. Wraps `api_color_calibrate`.

  /// POST /api/post-session/color-calibrate
  /// Body: `{ inputFits, outputFits, channels, whiteRefBv?, matchedStars: [...] }`
  /// (host paths). Returns `{jobId}`; the job result is the
  /// `ColorCalibrationResult` envelope.
  Future<Response> handleColorCalibrate(Request request) async {
    _logInfo('[API] POST /api/post-session/color-calibrate');
    final args = await readJsonObject(request);
    requireString(args, 'inputFits');
    requireString(args, 'outputFits');
    requireInt(args, 'channels');
    requireList<dynamic>(args, 'matchedStars');
    final argsJson = _encodeArgs(args);
    return _startJob('post-session.color-calibrate', () async {
      final out = await bridge.apiColorCalibrate(argsJson: argsJson);
      return _decodeObject(out);
    });
  }

  // Detect stars (photometry) — measure each star's per-channel aperture flux,
  // the input to colour calibration's Dart-side cross-match. Wraps
  // `api_detect_stars_photometry`.

  /// POST /api/post-session/detect-stars
  /// Body: `{ inputFits, maxStars?, aperture? }` (host path). Returns `{jobId}`;
  /// the job result is the `StarPhotometryResult` envelope.
  Future<Response> handleDetectStars(Request request) async {
    _logInfo('[API] POST /api/post-session/detect-stars');
    final args = await readJsonObject(request);
    requireString(args, 'inputFits');
    final argsJson = _encodeArgs(args);
    return _startJob('post-session.detect-stars', () async {
      final out = await bridge.apiDetectStarsPhotometry(argsJson: argsJson);
      return _decodeObject(out);
    });
  }

  // Extract background — fit + subtract a low-order background model. Wraps
  // `api_extract_background`.

  /// POST /api/post-session/extract-background
  /// Body: `{ inputFits, outputFits, config? }` (host paths). Returns `{jobId}`;
  /// the job result is the `{outputPath}` envelope.
  Future<Response> handleExtractBackground(Request request) async {
    _logInfo('[API] POST /api/post-session/extract-background');
    final args = await readJsonObject(request);
    requireString(args, 'inputFits');
    requireString(args, 'outputFits');
    final argsJson = _encodeArgs(args);
    return _startJob('post-session.extract-background', () async {
      final out = await bridge.apiExtractBackground(argsJson: argsJson);
      return _decodeObject(out);
    });
  }

  // Combine channels — linearly combine single-channel narrowband masters into
  // an RGB composite. Wraps `api_combine_channels`.

  /// POST /api/post-session/combine-channels
  /// Body: the `CombineChannelsArgs` JSON shape (host paths). Returns `{jobId}`;
  /// the job result is the `{outputPath}` envelope.
  Future<Response> handleCombineChannels(Request request) async {
    _logInfo('[API] POST /api/post-session/combine-channels');
    final args = await readJsonObject(request);
    final argsJson = _encodeArgs(args);
    return _startJob('post-session.combine-channels', () async {
      final out = await bridge.apiCombineChannels(argsJson: argsJson);
      return _decodeObject(out);
    });
  }

  // Master accumulate — multi-night accumulating master (create / add /
  // finalize / info). Wraps `api_master_accumulate`. The `info` / `create` /
  // `finalize` ops are cheap, but `add` folds a whole night, so the whole op
  // family is job-backed for a uniform client contract.

  /// POST /api/post-session/master-accumulate
  /// Body: the `MasterAccumulateArgs` JSON shape, carrying an `op` of
  /// `create` / `add` / `finalize` / `info` plus that op's fields (host paths).
  /// Returns `{jobId}`; the job result is the `MasterAccumulateResult` envelope.
  Future<Response> handleMasterAccumulate(Request request) async {
    _logInfo('[API] POST /api/post-session/master-accumulate');
    final args = await readJsonObject(request);
    final op = requireString(args, 'op');
    // Only the `add` op folds lights, and it is the only one whose args carry
    // `exposuresSec` at all — `create` / `finalize` / `info` never reach
    // `exposures_per_light`, so refusing their (ignored) list here would be a
    // refusal the host itself does not make.
    if (op == 'add') {
      _refuseExposuresSec(args, lightsField: 'lightPaths');
    }
    final argsJson = _encodeArgs(args);
    return _startJob('post-session.master-accumulate', () async {
      final out = await bridge.apiMasterAccumulate(argsJson: argsJson);
      return _decodeObject(out);
    });
  }
}
