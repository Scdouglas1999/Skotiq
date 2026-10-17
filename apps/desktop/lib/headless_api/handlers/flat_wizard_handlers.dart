import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for flat frame calibration and sequence generation
class FlatWizardHandlers {
  final ProviderContainer container;

  FlatWizardHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'FlatWizardHandlers');

  // Calibrate single filter

  Future<Response> handleCalibrateFilter(Request request) async {
    _logInfo('[API] POST /api/flat-wizard/calibrate');
    final payload = await readJsonObject(request);

    // Fail-fast validation: malformed/out-of-range request values are rejected
    // up front (a structured 400) BEFORE the service — and therefore the camera
    // — is ever touched, so a remote client cannot kick off a run against a bad
    // request. (A negative gain/offset stored on the active profile is host
    // misconfiguration, not a bad request, so `_resolveGainOffset` fails it as a
    // 500 rather than a 400.)
    final deviceId = _requireNonBlank(payload, 'deviceId');
    final filter = _requireNonBlank(payload, 'filter');
    final targetAdu = _requireTargetAdu(payload, 'targetAdu');
    final tolerance = _optionalTolerancePercent(payload, 'tolerance');
    final (minExposure, maxExposure) = _optionalExposureBounds(payload);
    final maxIterations = _optionalMaxIterations(payload);
    final (binX, binY) = _optionalBinning(payload);
    final (gain, offset) = _resolveGainOffset(payload);

    final service = container.read(flatWizardServiceProvider);
    final result = await service.calibrateFilter(
      deviceId: deviceId,
      filter: filter,
      targetAdu: targetAdu,
      tolerance: tolerance,
      minExposure: minExposure,
      maxExposure: maxExposure,
      maxIterations: maxIterations,
      binX: binX,
      binY: binY,
      gain: gain,
      offset: offset,
    );

    return jsonOk({'result': _flatResultToJson(result)});
  }

  // Calibrate multiple filters

  Future<Response> handleCalibrateMultipleFilters(Request request) async {
    _logInfo('[API] POST /api/flat-wizard/calibrate-multi');
    final payload = await readJsonObject(request);

    // Fail-fast validation before any camera work. `_requireFilterList` also
    // rejects an empty list, blank names, and duplicates so the batch can never
    // "succeed" by doing no work or clobber a filter by calibrating it twice.
    final deviceId = _requireNonBlank(payload, 'deviceId');
    final filters = _requireFilterList(payload, 'filters');
    final targetAdu = _requireTargetAdu(payload, 'targetAdu');
    final tolerance = _optionalTolerancePercent(payload, 'tolerance');
    final (minExposure, maxExposure) = _optionalExposureBounds(payload);
    final maxIterations = _optionalMaxIterations(payload);
    final (binX, binY) = _optionalBinning(payload);
    final (gain, offset) = _resolveGainOffset(payload);

    final service = container.read(flatWizardServiceProvider);
    final results = await service.calibrateMultipleFilters(
      deviceId: deviceId,
      filters: filters,
      targetAdu: targetAdu,
      tolerance: tolerance,
      minExposure: minExposure,
      maxExposure: maxExposure,
      maxIterations: maxIterations,
      binX: binX,
      binY: binY,
      gain: gain,
      offset: offset,
    );

    return jsonOk({
      'results': results.map((r) => _flatResultToJson(r)).toList(),
    });
  }

  // Generate Sequence from Calibrations

  Future<Response> handleGenerateSequence(Request request) async {
    _logInfo('[API] POST /api/flat-wizard/generate-sequence');
    final payload = await readJsonObject(request);

    // Why we hand-validate each calibration entry instead of using the
    // typed helpers: requireList<Map<String, dynamic>> rejects List<dynamic>
    // (JSON's natural list type), so we read as a generic list and validate
    // each element through readJsonObject-equivalent shape checks.
    final calibrationsRaw = payload['calibrations'];
    if (calibrationsRaw is! List) {
      throw BadRequestError(field: 'calibrations', expected: 'array');
    }
    if (calibrationsRaw.isEmpty) {
      throw BadRequestError(
        field: 'calibrations',
        expected: 'array',
        message: 'At least one calibration is required',
      );
    }
    final calibrations = <FlatResult>[];
    final seenFilters = <String>{};
    for (var i = 0; i < calibrationsRaw.length; i++) {
      final entry = calibrationsRaw[i];
      if (entry is! Map<String, dynamic>) {
        throw BadRequestError(field: 'calibrations[$i]', expected: 'object');
      }
      // Trimmed, non-blank, case-insensitively-unique filter: a blank name
      // would generate a nameless capture node, and a duplicate filter would
      // generate the same capture twice (duplicate work) — exactly what
      // calibrate-multi rejects up front.
      final filter = requireString(entry, 'filter').trim();
      if (filter.isEmpty) {
        throw BadRequestError(
          field: 'calibrations[$i].filter',
          expected: 'string',
          message: 'Filter name must not be blank',
        );
      }
      if (!seenFilters.add(filter.toLowerCase())) {
        throw BadRequestError(
          field: 'calibrations[$i].filter',
          expected: 'string',
          message: 'Duplicate filter "$filter"',
        );
      }
      calibrations.add(
        FlatResult(
          filter: filter,
          // A real flat exposure is finite and strictly positive; adu is a
          // measured mean and cannot be negative (a failed entry legitimately
          // carries adu 0). iterations is a nonnegative count bounded by the
          // same ceiling the calibration solver could ever run.
          exposure: _requirePositiveExposure(
            entry,
            'exposure',
            'calibrations[$i].exposure',
          ),
          adu: requireDouble(entry, 'adu', min: 0, max: _maxSupportedAdu),
          success: requireBool(entry, 'success'),
          iterations:
              optionalInt(
                entry,
                'iterations',
                min: 0,
                max: _maxIterationsLimit,
              ) ??
              0,
          errorMessage: optionalString(entry, 'errorMessage'),
        ),
      );
    }

    final framesPerFilter = requireInt(
      payload,
      'framesPerFilter',
      min: 1,
      max: _maxFramesPerFilter,
    );
    final sequenceName = _resolveSequenceName(payload);
    final description = optionalString(payload, 'description');
    // A generated ExposureNode carries a symmetric `BinningMode`, so asymmetric
    // input here would be silently collapsed to 1x1 by the service — reject it
    // rather than lie about what will actually run.
    final (binX, binY) = _optionalBinning(payload, requireSymmetric: true);
    final gain = optionalInt(payload, 'gain', min: 0);
    final offset = optionalInt(payload, 'offset', min: 0);
    final onlySuccessful = optionalBool(payload, 'onlySuccessful') ?? false;

    // Reject work that would produce a root-only, zero-exposure "sequence" and
    // report it as success: with onlySuccessful the eligible set is the
    // successful calibrations, otherwise it is all of them. If none are
    // eligible there is nothing to generate.
    final eligible = onlySuccessful
        ? calibrations.where((c) => c.success).length
        : calibrations.length;
    if (eligible == 0) {
      throw BadRequestError(
        field: 'calibrations',
        expected: 'array',
        message: onlySuccessful
            ? 'No successful calibrations to generate a sequence from'
            : 'No calibrations to generate a sequence from',
      );
    }

    final service = container.read(flatWizardServiceProvider);
    final sequence = service.generateCompleteSequence(
      calibrations: calibrations,
      framesPerFilter: framesPerFilter,
      sequenceName: sequenceName,
      description: description,
      binX: binX,
      binY: binY,
      gain: gain,
      offset: offset,
      onlySuccessful: onlySuccessful,
    );

    return jsonOk({'sequence': _sequenceToJson(sequence)});
  }

  // Quick calibrate

  Future<Response> handleQuickCalibrate(Request request) async {
    _logInfo('[API] POST /api/flat-wizard/quick-calibrate');
    final payload = await readJsonObject(request);

    // Same fail-fast validation as the full calibrate endpoint; targetAdu and
    // tolerance are optional here and fall back to the quick-calibrate defaults.
    final deviceId = _requireNonBlank(payload, 'deviceId');
    final filter = _requireNonBlank(payload, 'filter');
    final targetAdu = _requireTargetAdu(payload, 'targetAdu', orElse: 30000.0);
    final tolerancePercent = _optionalTolerancePercent(
      payload,
      'tolerancePercent',
    );
    final (binX, binY) = _optionalBinning(payload);
    final (gain, offset) = _resolveGainOffset(payload);

    final service = container.read(flatWizardServiceProvider);
    final result = await service.quickCalibrate(
      deviceId: deviceId,
      filter: filter,
      targetAdu: targetAdu,
      tolerancePercent: tolerancePercent,
      binX: binX,
      binY: binY,
      gain: gain,
      offset: offset,
    );

    return jsonOk({'result': _flatResultToJson(result)});
  }

  // Validation helpers
  //
  // Shared by all four endpoints so their limits cannot drift. The limits below
  // are sourced from the flat-wizard UI/model contract, not guessed:
  //   * [_maxSupportedAdu] — the largest full-scale ADU any supported sensor can
  //     reach. FlatWizardService.resolveCaptureConfig admits a bit depth up to
  //     32 (`(1 << bitDepth) - 1`), so 32-bit full scale is the ceiling. We
  //     deliberately do NOT assume 16-bit (the 65535 fallback is only a
  //     *display* default), so a genuine high-bit-depth sensor is not rejected.
  //   * tolerance — the canonical 1..25% control documented on
  //     `FlatWizardGlobalSettings.tolerancePercent`.
  //   * exposure — strictly positive, min <= max, capped at [_maxExposureSeconds]
  //     (1h) so a flat exposure cannot be an impossible/absurd duration.
  //   * [_maxIterationsLimit] — bound on the binary-search iteration count; also
  //     the ceiling for a supplied per-calibration `iterations` result count.
  //   * [_maxBinning] — `BinningMode` only models the SYMMETRIC bins one..four,
  //     so each axis is capped here and a larger bin (or, where the contract
  //     cannot preserve it, an asymmetric bin) is rejected up front rather than
  //     silently collapsed to 1x1 by the service.
  //   * [_maxFramesPerFilter] — the UI slider caps at 100; headless allows a
  //     larger but still-bounded batch.
  //   * [_maxSequenceNameLength] — the `sequences.name` column is
  //     `text().withLength(min: 1, max: 200)`, so a longer name would fail on
  //     save; reject it here instead.

  static const double _maxSupportedAdu = 4294967295.0; // (1 << 32) - 1
  static const double _maxExposureSeconds = 3600.0;
  static const int _maxIterationsLimit = 100;
  static const int _maxBinning = 4;
  static const int _maxFramesPerFilter = 1000;
  static const int _maxSequenceNameLength = 200;

  /// Required, finite, strictly-positive target ADU. When [orElse] is given and
  /// the field is absent it is used as the default (still range-checked when
  /// present).
  double _requireTargetAdu(
    Map<String, dynamic> payload,
    String field, {
    double? orElse,
  }) {
    if (payload[field] == null && orElse != null) return orElse;
    final value = requireDouble(payload, field, max: _maxSupportedAdu);
    if (value <= 0) {
      throw BadRequestError(
        field: field,
        expected: 'number',
        message: '$field must be greater than 0',
      );
    }
    return value;
  }

  /// Optional tolerance percent, defaulting to 10%, constrained to the canonical
  /// 1..25% control.
  double _optionalTolerancePercent(Map<String, dynamic> payload, String field) {
    return optionalDouble(payload, field, min: 1, max: 25) ?? 10.0;
  }

  /// Optional exposure bounds. Each is strictly positive and capped at a sane
  /// ceiling, and min must not exceed max.
  (double, double) _optionalExposureBounds(Map<String, dynamic> payload) {
    final minExposure =
        optionalDouble(payload, 'minExposure', max: _maxExposureSeconds) ??
        0.001;
    final maxExposure =
        optionalDouble(payload, 'maxExposure', max: _maxExposureSeconds) ??
        30.0;
    if (minExposure <= 0) {
      throw BadRequestError(
        field: 'minExposure',
        expected: 'number',
        message: 'minExposure must be greater than 0',
      );
    }
    if (maxExposure <= 0) {
      throw BadRequestError(
        field: 'maxExposure',
        expected: 'number',
        message: 'maxExposure must be greater than 0',
      );
    }
    if (minExposure > maxExposure) {
      throw BadRequestError(
        field: 'maxExposure',
        expected: 'number',
        message: 'maxExposure must be >= minExposure',
      );
    }
    return (minExposure, maxExposure);
  }

  /// Finite, strictly-positive exposure for a single calibration entry. [field]
  /// is the caller-facing path (e.g. `calibrations[2].exposure`).
  double _requirePositiveExposure(
    Map<String, dynamic> entry,
    String key,
    String field,
  ) {
    final value = requireDouble(entry, key, max: _maxExposureSeconds);
    if (value <= 0) {
      throw BadRequestError(
        field: field,
        expected: 'number',
        message: '$field must be greater than 0',
      );
    }
    return value;
  }

  /// Optional maximum iteration count, defaulting to 10, bounded and positive.
  int _optionalMaxIterations(Map<String, dynamic> payload) {
    return optionalInt(
          payload,
          'maxIterations',
          min: 1,
          max: _maxIterationsLimit,
        ) ??
        10;
  }

  /// Optional binning, defaulting to 1x1, each axis a positive value within the
  /// supported [_maxBinning] range.
  ///
  /// The calibrate/quick paths forward `binX` and `binY` as independent ints all
  /// the way to `cameraStartExposure`, so an asymmetric sensor bin is preserved
  /// end-to-end and is allowed. When [requireSymmetric] is set (sequence
  /// generation, whose `BinningMode`/`ExposureNode` can only carry a symmetric
  /// bin) an asymmetric pair is rejected instead of being silently collapsed to
  /// 1x1 by the service.
  (int, int) _optionalBinning(
    Map<String, dynamic> payload, {
    bool requireSymmetric = false,
  }) {
    final binX = optionalInt(payload, 'binX', min: 1, max: _maxBinning) ?? 1;
    final binY = optionalInt(payload, 'binY', min: 1, max: _maxBinning) ?? 1;
    if (requireSymmetric && binX != binY) {
      throw BadRequestError(
        field: 'binY',
        expected: 'integer',
        message:
            'binX and binY must be equal here: a generated flat sequence '
            'cannot represent asymmetric binning',
      );
    }
    return (binX, binY);
  }

  /// Required, trimmed, non-blank string. Unlike [requireString] (which only
  /// rejects the empty string) this also rejects a whitespace-only value and
  /// returns the trimmed result, so a blank deviceId/filter can never reach the
  /// camera.
  String _requireNonBlank(Map<String, dynamic> payload, String field) {
    final trimmed = requireString(payload, field).trim();
    if (trimmed.isEmpty) {
      throw BadRequestError(
        field: field,
        expected: 'string',
        message: '$field must not be blank',
      );
    }
    return trimmed;
  }

  /// Resolve the generated sequence's name. An absent name (the API, via
  /// [optionalString], also treats an empty string as absent) falls back to the
  /// default; a supplied name is trimmed and then rejected if it is blank
  /// (whitespace-only) or exceeds the canonical [_maxSequenceNameLength], rather
  /// than being shipped as a blank-looking name or failing later on save.
  String _resolveSequenceName(Map<String, dynamic> payload) {
    final raw = optionalString(payload, 'sequenceName');
    if (raw == null) return 'Flat Frame Sequence';
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw BadRequestError(
        field: 'sequenceName',
        expected: 'string',
        message: 'sequenceName must not be blank',
      );
    }
    if (trimmed.length > _maxSequenceNameLength) {
      throw BadRequestError(
        field: 'sequenceName',
        expected: 'string',
        message:
            'sequenceName exceeds maximum length of $_maxSequenceNameLength',
      );
    }
    return trimmed;
  }

  /// A non-empty list of trimmed, non-blank, unique filter names. Empty lists,
  /// blank entries, and duplicates (case-insensitively — a wheel cannot hold
  /// both `L` and `l`) are rejected so the batch cannot do no work or calibrate
  /// the same filter twice.
  List<String> _requireFilterList(Map<String, dynamic> payload, String field) {
    final raw = requireList<String>(payload, field);
    if (raw.isEmpty) {
      throw BadRequestError(
        field: field,
        expected: 'array',
        message: 'At least one filter is required',
      );
    }
    final cleaned = <String>[];
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final name = raw[i].trim();
      if (name.isEmpty) {
        throw BadRequestError(
          field: '$field[$i]',
          expected: 'string',
          message: 'Filter name must not be blank',
        );
      }
      if (!seen.add(name.toLowerCase())) {
        throw BadRequestError(
          field: '$field[$i]',
          expected: 'string',
          message: 'Duplicate filter "$name"',
        );
      }
      cleaned.add(name);
    }
    return cleaned;
  }

  // Helpers

  (int, int) _resolveGainOffset(Map<String, dynamic> payload) {
    // Client-supplied values are already floored at 0 here, so a negative can
    // only enter through a profile fallback below.
    final gain = optionalInt(payload, 'gain', min: 0);
    final offset = optionalInt(payload, 'offset', min: 0);

    int resolvedGain;
    int resolvedOffset;
    if (gain != null && offset != null) {
      resolvedGain = gain;
      resolvedOffset = offset;
    } else {
      final profile = container.read(activeEquipmentProfileProvider);
      final fallbackGain = gain ?? profile?.defaultGain;
      final fallbackOffset = offset ?? profile?.defaultOffset;
      if (fallbackGain == null || fallbackOffset == null) {
        throw BadRequestError(
          field: gain == null ? 'gain' : 'offset',
          expected: 'integer',
          message:
              'Flat calibration requires gain and offset, either in the request or on the active equipment profile.',
        );
      }
      resolvedGain = fallbackGain;
      resolvedOffset = fallbackOffset;
    }

    // Validate the FINAL resolved pair, not just the client input. A negative
    // value here can only have come from a stored profile default, which is host
    // misconfiguration rather than a malformed request — fail closed with a 500
    // (a HandlerFailure, the repo's structured host-side failure) so the bad
    // value can never reach the camera, and is never coerced to zero.
    if (resolvedGain < 0 || resolvedOffset < 0) {
      throw HandlerFailure(
        code: 'invalid_profile_gain_offset',
        statusCode: 500,
        message:
            'The active equipment profile has a negative default gain or '
            'offset; fix the profile before running flat calibration.',
      );
    }

    return (resolvedGain, resolvedOffset);
  }

  Map<String, dynamic> _flatResultToJson(FlatResult result) {
    return {
      'filter': result.filter,
      'exposure': result.exposure,
      'adu': result.adu,
      'success': result.success,
      'iterations': result.iterations,
      'errorMessage': result.errorMessage,
    };
  }

  Map<String, dynamic> _sequenceToJson(Sequence sequence) {
    return {
      'id': sequence.id,
      'name': sequence.name,
      'description': sequence.description,
      'rootNodeId': sequence.rootNodeId,
      'isTemplate': sequence.isTemplate,
      'createdAt': sequence.createdAt.millisecondsSinceEpoch,
      'modifiedAt': sequence.modifiedAt.millisecondsSinceEpoch,
      'nodes': sequence.nodes.map(
        (key, node) => MapEntry(key, _nodeToJson(node)),
      ),
    };
  }

  Map<String, dynamic> _nodeToJson(SequenceNode node) {
    final base = {
      'id': node.id,
      'name': node.name,
      'type': node.runtimeType.toString(),
      'parentId': node.parentId,
      'orderIndex': node.orderIndex,
      'isEnabled': node.isEnabled,
    };

    // Add type-specific fields
    if (node is ExposureNode) {
      base['durationSecs'] = node.durationSecs;
      base['count'] = node.count;
      base['filter'] = node.filter;
      base['gain'] = node.gain;
      base['offset'] = node.offset;
      base['binning'] = node.binning.name;
      base['frameType'] = node.frameType.name;
    } else if (node is InstructionSetNode) {
      base['childIds'] = node.childIds;
    }

    return base;
  }
}
