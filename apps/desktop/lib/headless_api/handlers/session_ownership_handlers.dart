// REST surface for the SessionOwnershipManager.
//
// Exposes:
//   POST /api/session/claim       - claim the operator slot when free
//   POST /api/session/take-over   - displace the current owner
//   POST /api/session/release     - voluntary release by the owner
//   GET  /api/session/owner       - current owner snapshot (or null)
//   GET  /api/session/status      - status with isYouTheOwner / mode

import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../session_ownership.dart';
import '../validation.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

/// Handlers for the operator-slot endpoints.
class SessionOwnershipHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    SessionOwnershipApi.getOwner: handleGetOwner,
    SessionOwnershipApi.getStatus: handleGetStatus,
    SessionOwnershipApi.claim: handleClaim,
    SessionOwnershipApi.takeOver: handleTakeOver,
    SessionOwnershipApi.release: handleRelease,
  };

  final SessionOwnershipManager manager;

  /// Resolver the handler uses to read the caller's bearer token off the
  /// request. The auth middleware has already validated the token; we
  /// need the raw value to derive the digest the manager keyed on.
  final String? Function(Request request) tokenResolver;

  SessionOwnershipHandlers({
    required this.manager,
    required this.tokenResolver,
  });

  /// `POST /api/session/claim` — `{clientName, clientId?}`.
  ///
  /// Success: 200 `{owner, claimed: true}`.
  /// Slot taken by another client: 409 `{owner, claimed: false,
  /// retryWithTakeOver: true, message}`.
  Future<Response> handleClaim(Request request) async {
    final payload = await readJsonObject(request);
    final clientName = optionalString(payload, 'clientName', maxLength: 120);
    final clientId = optionalString(payload, 'clientId', maxLength: 120);
    final token = _requireToken(request);

    final claimed = manager.claim(
      token: token,
      clientId: clientId,
      clientName: clientName,
    );
    if (claimed != null) {
      return jsonOk({
        'owner': claimed.toJson(),
        'claimed': true,
        'isYouTheOwner': true,
      });
    }
    final existing = manager.current!; // claim returned null => slot taken
    return jsonConflict({
      'owner': existing.toJson(),
      'claimed': false,
      'retryWithTakeOver': true,
      'message':
          'Another client holds the operator slot. POST /api/session/take-over to displace.',
    });
  }

  /// `POST /api/session/take-over` — `{clientName, clientId?, reason}`.
  ///
  /// Always succeeds for any control-scope caller. The previous owner
  /// observes an `OwnershipTakenOver` event so its UI can show a toast.
  Future<Response> handleTakeOver(Request request) async {
    final payload = await readJsonObject(request);
    final reason = requireString(payload, 'reason', maxLength: 240);
    final clientName = optionalString(payload, 'clientName', maxLength: 120);
    final clientId = optionalString(payload, 'clientId', maxLength: 120);
    final token = _requireToken(request);

    final owner = manager.takeOver(
      token: token,
      reason: reason,
      clientId: clientId,
      clientName: clientName,
    );
    return jsonOk({
      'owner': owner.toJson(),
      'tookOver': true,
      'isYouTheOwner': true,
    });
  }

  /// `POST /api/session/release` — owner-only.
  ///
  /// 200 on success (slot is now open). 403 when called by a non-owner —
  /// only the operator may voluntarily release. Idempotent: releasing
  /// an already-empty slot succeeds.
  Future<Response> handleRelease(Request request) async {
    final token = _requireToken(request);
    final ok = manager.release(token);
    if (!ok) {
      return jsonForbidden({
        'error': 'not_owner',
        'message':
            'Only the current operator can voluntarily release the slot. '
            'Use /api/session/take-over to displace the owner.',
      });
    }
    return jsonOk({'released': true, 'owner': null});
  }

  /// `GET /api/session/owner` — current owner snapshot. The body has
  /// `{owner}` which is null when the slot is open.
  Future<Response> handleGetOwner(Request request) async {
    final owner = manager.current;
    return jsonOk({'owner': owner?.toJson()});
  }

  /// `GET /api/session/status` — combines owner snapshot with the
  /// caller-relative view (`isYouTheOwner`, `mode`).
  Future<Response> handleGetStatus(Request request) async {
    final owner = manager.current;
    final token = tokenResolver(request);
    final isOwner = token != null && manager.isOwner(token);
    final mode = owner == null
        ? 'unowned'
        : isOwner
        ? 'operator'
        : 'viewer';
    return jsonOk({
      'owner': owner?.toJson(),
      'isYouTheOwner': isOwner,
      'mode': mode,
      'heartbeatTimeoutSeconds': manager.heartbeatTimeout.inSeconds,
    });
  }

  String _requireToken(Request request) {
    final token = tokenResolver(request);
    if (token == null || token.isEmpty) {
      // The auth middleware already filtered unauthenticated requests, so
      // reaching this branch is a wiring bug (e.g. tests constructing the
      // handler without a tokenResolver). Surface loudly.
      throw HandlerFailure(
        code: 'auth_required',
        message:
            'Session ownership endpoints require an authenticated bearer token.',
        statusCode: 401,
      );
    }
    return token;
  }
}
