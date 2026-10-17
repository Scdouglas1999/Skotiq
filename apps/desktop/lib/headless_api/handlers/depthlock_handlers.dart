import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_error;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for the DepthLock goal store (`/api/depthlock/*`).
///
/// A remote client edits goals through exactly the same calls the desktop
/// makes, so the models' own JSON is the wire shape: a goal read here and a
/// goal read over FFI decode to the same object, and there is no second
/// schema to keep in step.
///
/// Concurrency is the reason every mutation carries `expectedRevision`. The
/// native store refuses a mutation whose expected revision has moved on, and
/// that refusal is a 409 here — a phone and a desktop editing one goal are a
/// normal night, and the loser needs to know it lost rather than to discover
/// its edit silently vanished.
class DepthLockHandlers {
  final ProviderContainer container;

  DepthLockHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'DepthLockHandlers');

  DepthLockBackend get _backend => container.read(backendProvider);

  /// Run [action], translating the native refusal into the status that names
  /// what happened.
  ///
  /// The native reason is passed through verbatim: it is written for the
  /// operator ("stale revision for DepthLock goal m42-ha") and every surface
  /// above renders it as-is, so rewording it here would only make the same
  /// event read differently depending on which client saw it.
  Future<T> _translating<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on bridge_error.SkotiqError catch (error, stackTrace) {
      final reason = describeBackendError(error);
      final code = _depthLockErrorCode(reason);
      throw HandlerFailure(
        code: code,
        message: reason,
        statusCode: _depthLockErrorStatus(reason),
        // `error` alone is the legacy prose slot, which a remote client folds
        // into "<code>: <reason>". Emitting the machine `code` beside it is
        // the canonical envelope, so the operator reads the native reason
        // verbatim and a client can still branch on the code.
        details: {'code': code},
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// The store's refusals are distinguishable by their own sentences, which
  /// are stable strings in `depthlock_service/store.rs`. Anything else is a
  /// definition the caller can fix, so it answers 400 rather than claiming a
  /// host fault.
  static int _depthLockErrorStatus(String reason) {
    if (reason.contains('does not exist')) return 404;
    if (reason.contains('stale revision')) return 409;
    if (reason.contains('storage is not initialized')) return 503;
    return 400;
  }

  static String _depthLockErrorCode(String reason) =>
      switch (_depthLockErrorStatus(reason)) {
        404 => 'depthlock_goal_not_found',
        409 => 'depthlock_stale_revision',
        503 => 'depthlock_unavailable',
        _ => 'depthlock_invalid_request',
      };

  /// A required nested JSON object, named by its own field path on failure.
  static Map<String, dynamic> _requireObject(
    Map<String, dynamic> payload,
    String field,
  ) {
    final value = payload[field];
    if (value is! Map) {
      throw BadRequestError(field: field, expected: 'object');
    }
    return value.cast<String, dynamic>();
  }

  /// Decode one of the DepthLock wire models, turning a shape mismatch into a
  /// 400 that names the field instead of the 500 a raw cast would produce.
  static T _decode<T>(
    Map<String, dynamic> payload,
    String field,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final json = _requireObject(payload, field);
    try {
      return fromJson(json);
    } on FormatException catch (e) {
      throw BadRequestError(
        field: field,
        expected: 'object',
        message: e.message,
      );
    } on TypeError {
      throw BadRequestError(
        field: field,
        expected: 'object',
        message: '$field is missing a required value or has the wrong type',
      );
    }
  }

  /// `GET /api/depthlock/status`
  Future<Response> handleGetStatus(Request request) async {
    _logInfo('[API] GET /api/depthlock/status');
    final status = await _translating(_backend.depthLockStatus);
    return jsonOk({'status': status.toJson()});
  }

  /// `GET /api/depthlock/goals`
  Future<Response> handleListGoals(Request request) async {
    _logInfo('[API] GET /api/depthlock/goals');
    final goals = await _translating(_backend.listDepthLockGoals);
    return jsonOk({
      'goals': goals.map((goal) => goal.toJson()).toList(growable: false),
    });
  }

  /// `POST /api/depthlock/goals` — `{goalId?, definition}`.
  ///
  /// An omitted `goalId` asks the store to generate one; the created goal
  /// comes back in full so the caller never has to re-read it to learn its id
  /// or its starting revision.
  Future<Response> handleCreateGoal(Request request) async {
    _logInfo('[API] POST /api/depthlock/goals');
    final payload = await readJsonObject(request);
    final goalId = optionalString(payload, 'goalId', maxLength: 200);
    final definition = _decode(
      payload,
      'definition',
      DepthLockGoalDefinition.fromJson,
    );
    final goal = await _translating(
      () => _backend.createDepthLockGoal(definition, goalId: goalId),
    );
    return jsonOk({'goal': goal.toJson()});
  }

  /// `GET /api/depthlock/goals/<goalId>`
  Future<Response> handleGetGoal(Request request, String goalId) async {
    _logInfo('[API] GET /api/depthlock/goals/$goalId');
    final goal = await _translating(() => _backend.getDepthLockGoal(goalId));
    return jsonOk({'goal': goal.toJson()});
  }

  /// `PUT /api/depthlock/goals/<goalId>` — `{expectedRevision, definition}`.
  ///
  /// A revision, not an edit in place: the earlier one is archived and its
  /// evidence stops counting, which is why the caller has to say which
  /// revision it believed it was replacing.
  Future<Response> handleReviseGoal(Request request, String goalId) async {
    _logInfo('[API] PUT /api/depthlock/goals/$goalId');
    final payload = await readJsonObject(request);
    final expectedRevision = requireInt(payload, 'expectedRevision', min: 0);
    final definition = _decode(
      payload,
      'definition',
      DepthLockGoalDefinition.fromJson,
    );
    final goal = await _translating(
      () => _backend.reviseDepthLockGoal(
        goalId: goalId,
        expectedRevision: expectedRevision,
        definition: definition,
      ),
    );
    return jsonOk({'goal': goal.toJson()});
  }

  /// `POST /api/depthlock/goals/<goalId>/preferences` —
  /// `{expectedRevision, enabled, automaticCompletion}`.
  Future<Response> handleSetPreferences(Request request, String goalId) async {
    _logInfo('[API] POST /api/depthlock/goals/$goalId/preferences');
    final payload = await readJsonObject(request);
    final expectedRevision = requireInt(payload, 'expectedRevision', min: 0);
    final enabled = requireBool(payload, 'enabled');
    final automaticCompletion = requireBool(payload, 'automaticCompletion');
    final goal = await _translating(
      () => _backend.setDepthLockGoalPreferences(
        goalId: goalId,
        expectedRevision: expectedRevision,
        enabled: enabled,
        automaticCompletion: automaticCompletion,
      ),
    );
    return jsonOk({'goal': goal.toJson()});
  }

  /// `DELETE /api/depthlock/goals/<goalId>?expectedRevision=<n>`
  ///
  /// The revision rides in the query string because a DELETE body is not
  /// carried by every client; it is still required, so a delete can never
  /// remove a goal the caller has not seen.
  Future<Response> handleRemoveGoal(Request request, String goalId) async {
    _logInfo('[API] DELETE /api/depthlock/goals/$goalId');
    final expectedRevision = optionalQueryInt(
      request.url.queryParameters,
      'expectedRevision',
      min: 0,
    );
    if (expectedRevision == null) {
      throw BadRequestError(
        field: 'expectedRevision',
        expected: 'integer',
        message:
            'expectedRevision is required so a delete cannot remove a goal '
            'the caller has not seen',
      );
    }
    await _translating(
      () => _backend.removeDepthLockGoal(
        goalId: goalId,
        expectedRevision: expectedRevision,
      ),
    );
    return jsonOk({'removed': true});
  }

  /// `POST /api/depthlock/goals/<goalId>/ingest` — `{path}`.
  ///
  /// The path is a host path: the frame is already on the rig's disk, and
  /// nothing is uploaded. The outcome says what became of it, including the
  /// refusals (`duplicate`, `preSelection`, `rejected`) that are answers, not
  /// errors.
  Future<Response> handleIngestFrame(Request request, String goalId) async {
    _logInfo('[API] POST /api/depthlock/goals/$goalId/ingest');
    final payload = await readJsonObject(request);
    final path = requireString(payload, 'path', maxLength: 4096);
    final outcome = await _translating(
      () => _backend.ingestDepthLockFrame(goalId: goalId, path: path),
    );
    return jsonOk({'outcome': outcome.toJson()});
  }

  /// Points a curve may carry when the caller asks for none, or asks for
  /// something that is not a count. Display-only, so an unusable value takes
  /// the default rather than refusing a read that has no side effects.
  static const int _defaultCurvePoints = 60;
  static const int _maxCurvePoints = 500;

  /// `GET /api/depthlock/goals/<goalId>/curve?maxPoints=60`
  ///
  /// The goal's score after each prefix of its evidence, then the noise
  /// model's projection past the last measured point. Nothing here changes a
  /// verdict — it exists so the operator can see whether the curve is still
  /// climbing before deciding to keep the filter on target.
  Future<Response> handleGoalCurve(Request request, String goalId) async {
    _logInfo('[API] GET /api/depthlock/goals/$goalId/curve');
    final raw = request.url.queryParameters['maxPoints'];
    final parsed = raw == null ? null : int.tryParse(raw);
    final maxPoints = (parsed == null || parsed < 2 || parsed > _maxCurvePoints)
        ? _defaultCurvePoints
        : parsed;
    final points = await _translating(
      () => _backend.depthLockGoalCurve(goalId, maxPoints: maxPoints),
    );
    return jsonOk({
      'points': points.map((point) => point.toJson()).toList(growable: false),
    });
  }

  /// `POST /api/depthlock/goals/<goalId>/replay`
  Future<Response> handleReplayGoal(Request request, String goalId) async {
    _logInfo('[API] POST /api/depthlock/goals/$goalId/replay');
    final goal = await _translating(() => _backend.replayDepthLockGoal(goalId));
    return jsonOk({'goal': goal.toJson()});
  }

  /// `POST /api/depthlock/reference/inspect` — `{path}`.
  Future<Response> handleInspectReference(Request request) async {
    _logInfo('[API] POST /api/depthlock/reference/inspect');
    final payload = await readJsonObject(request);
    final path = requireString(payload, 'path', maxLength: 4096);
    final reference = await _translating(
      () => _backend.inspectDepthLockReference(path),
    );
    return jsonOk({'reference': reference.toJson()});
  }

  /// `POST /api/depthlock/reference/sky-rectangle` —
  /// `{reference, x0, y0, x1, y1}`.
  Future<Response> handleSkyRectangle(Request request) async {
    _logInfo('[API] POST /api/depthlock/reference/sky-rectangle');
    final payload = await readJsonObject(request);
    final reference = _decode(payload, 'reference', ReferenceGeometry.fromJson);
    final rectangle = await _translating(
      () => _backend.depthLockSkyRectangle(
        reference: reference,
        x0: requireDouble(payload, 'x0'),
        y0: requireDouble(payload, 'y0'),
        x1: requireDouble(payload, 'x1'),
        y1: requireDouble(payload, 'y1'),
      ),
    );
    return jsonOk({'rectangle': rectangle.toJson()});
  }

  /// `POST /api/depthlock/measurement/suggest-floor` —
  /// `{referencePath, darkPath, flatPath, scaleArcsec, pixelScaleArcsec?}`.
  ///
  /// The systematic floor is the one number in a measurement an operator
  /// cannot reason their way to, so it is measured from the reference light
  /// and the two masters rather than guessed. An omitted `pixelScaleArcsec`
  /// means "read it from the reference's TAN header"; a reference with no
  /// solution then refuses, naming that.
  Future<Response> handleSuggestFloor(Request request) async {
    _logInfo('[API] POST /api/depthlock/measurement/suggest-floor');
    final payload = await readJsonObject(request);
    final suggestion = await _translating(
      () => _backend.suggestDepthLockFloor(
        referencePath: requireString(payload, 'referencePath', maxLength: 4096),
        darkPath: requireString(payload, 'darkPath', maxLength: 4096),
        flatPath: requireString(payload, 'flatPath', maxLength: 4096),
        scaleArcsec: requireDouble(payload, 'scaleArcsec', min: 0),
        pixelScaleArcsec: optionalDouble(payload, 'pixelScaleArcsec', min: 0),
      ),
    );
    return jsonOk({'suggestion': suggestion.toJson()});
  }

  /// `POST /api/depthlock/measurement/check` — `{measurement}`.
  ///
  /// Creates nothing: the editor calls this as the operator drags the region
  /// so a bad scale or a background that lands off the frame is explained
  /// while it can still be fixed.
  Future<Response> handleCheckMeasurement(Request request) async {
    _logInfo('[API] POST /api/depthlock/measurement/check');
    final payload = await readJsonObject(request);
    final measurement = _decode(
      payload,
      'measurement',
      DepthLockMeasurement.fromJson,
    );
    final cells = await _translating(
      () => _backend.checkDepthLockMeasurement(measurement),
    );
    return jsonOk({'cells': cells});
  }
}
