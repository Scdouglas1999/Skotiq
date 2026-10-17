/// HTTP handlers for the cellular-push token + preference endpoints
/// (Phase D).
///
/// A paired phone, once it has obtained its FCM (Android) or APNs (iOS)
/// token, posts it here so the desktop's remote-push delivery can fan a
/// critical alert out to it over cellular — the path the LAN UDP broadcaster
/// cannot reach. These endpoints are NOT in `publicPaths`: a token
/// registration must come from an already-paired client (the same bearer
/// token the rest of the authenticated API uses), so an off-host attacker
/// cannot enroll a rogue recipient.
///
/// Endpoints owned by this class:
///   * `POST   /api/push/register-token` — upsert `{deviceId, platform, token}`
///     into `device_push_tokens`.
///   * `DELETE /api/push/token` — remove a device's tokens (`{deviceId}`) or a
///     single stale token (`{token}`); used on unpair / sign-out.
///   * `GET    /api/push/preferences?deviceId=...` — the device's prefs row
///     (defaults when none).
///   * `PUT    /api/push/preferences` — upsert `{deviceId, enabled, mute*}`.
///
/// Storage is the same Drift `PairingDatabase` the pairing flow uses, reached
/// through [EnsurePairingService] so this handler stays decoupled from the
/// server's private state (mirrors `PairingHandlers`).
library;

import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:shelf/shelf.dart';

import '../request_context.dart';
import '../response_helpers.dart';
import '../validation.dart';
// Reuse the [EnsurePairingService] typedef declared by the pairing handlers
// so token storage and device pairing share one lazily-constructed
// [PairingService] (and one Drift DB) — re-declaring it here would collide on
// the `handlers.dart` barrel re-export.
import 'pairing_handlers.dart' show EnsurePairingService;

/// Recognised cellular-push platforms. Mirrors the `platform` column domain.
const Set<String> _kPushPlatforms = {'fcm', 'apns'};

/// HTTP handlers for the `/api/push/*` endpoints.
class PushHandlers {
  final EnsurePairingService ensurePairingService;
  final LoggingService logger;

  /// What the host's wired [RemotePushDelivery] does with an alert. Supplied
  /// as a closure so the handler reads the LIVE value — delivery can be
  /// (re)configured after the handler is constructed.
  ///
  /// Without this, `/api/push/targets` could only report whether anyone had
  /// registered, which is half the truth: registered tokens with no real
  /// channel still deliver nothing.
  final PushDeliveryChannel Function() deliveryChannel;

  PushHandlers({
    required this.ensurePairingService,
    required this.logger,
    PushDeliveryChannel Function()? deliveryChannel,
  }) : deliveryChannel = deliveryChannel ?? _noDeliveryChannel;

  static PushDeliveryChannel _noDeliveryChannel() => PushDeliveryChannel.none;

  void _logInfo(String message) => logger.info(message, source: 'PushHandlers');
  void _logWarning(String message) =>
      logger.warning(message, source: 'PushHandlers');

  /// Resolve the deviceId of the ACTIVE paired device that owns the bearer
  /// token which authenticated this request, or `null` if none does.
  ///
  /// The auth middleware never propagates the raw bearer — only its
  /// `computeServerFingerprint` digest, stashed on the request context and
  /// read here via [authIdentityFrom]. We map that digest back to the owning
  /// `paired_devices` row (revoked rows excluded), which is the only
  /// trustworthy "who is calling" signal available to a handler. The client-
  /// supplied `deviceId` is NEVER trusted for authorization — it is compared
  /// against this resolved value.
  Future<String?> _callerDeviceId(Request request) async {
    final identity = authIdentityFrom(request);
    if (identity == null || identity.isEmpty) return null;
    final db = ensurePairingService().database;
    final device = await db.getActivePairedDeviceByFingerprint(identity);
    return device?.deviceId;
  }

  /// Enforce that the request's target [targetDeviceId] is the caller's OWN
  /// device. Returns a 403 [Response] to short-circuit on mismatch (or when
  /// the caller cannot be resolved to an active device), or `null` to proceed.
  ///
  /// Every `/api/push/*` mutation is scoped to the caller's own push
  /// registration, so a low-trust, guest, or stolen control token cannot
  /// register, delete, or mute another operator's safety-alert delivery.
  /// Resolving through the active-device fingerprint lookup also rejects
  /// revoked and inactive callers.
  Future<Response?> _requireOwnDevice(
    Request request,
    String targetDeviceId,
    String requestId,
  ) async {
    final caller = await _callerDeviceId(request);
    if (caller == null) {
      _logWarning(
        '[push][$requestId] rejected: caller is not an active paired device',
      );
      return jsonForbidden(
        {
          'error': 'forbidden',
          'message':
              'The authenticated session is not an active paired '
              'device.',
          'requestId': requestId,
        },
        headers: {requestIdHeader: requestId},
      );
    }
    if (caller != targetDeviceId) {
      _logWarning(
        '[push][$requestId] rejected: caller=$caller may not act on '
        'deviceId=$targetDeviceId',
      );
      return jsonForbidden(
        {
          'error': 'forbidden',
          'message':
              'deviceId does not match the authenticated device. A '
              'device may only manage its own push registration.',
          'requestId': requestId,
        },
        headers: {requestIdHeader: requestId},
      );
    }
    return null;
  }

  /// `POST /api/push/register-token` — body `{deviceId, platform, token}`.
  ///
  /// Upserts into `device_push_tokens` keyed on `(deviceId, platform)`, so a
  /// token refresh overwrites in place. The `deviceId` MUST belong to a
  /// currently-paired device — registering a token for an unknown device is a
  /// 404 so a deauthorized client cannot keep a recipient alive.
  Future<Response> handleRegisterToken(Request request) async {
    final requestId = requestIdFrom(request);
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId', maxLength: 128);
    final platform = requireString(payload, 'platform', maxLength: 16);
    final token = requireString(payload, 'token', maxLength: 4096);

    if (!_kPushPlatforms.contains(platform)) {
      throw BadRequestError(
        field: 'platform',
        expected: "'fcm' | 'apns'",
        message: "platform must be one of: ${_kPushPlatforms.join(', ')}",
      );
    }

    // IDOR fix: a device may only register a token for ITSELF. Resolve the
    // caller from the authenticated session and require deviceId == caller.
    final ownership = await _requireOwnDevice(request, deviceId, requestId);
    if (ownership != null) return ownership;

    final db = ensurePairingService().database;
    final device = await db.getPairedDevice(deviceId);
    if (device == null) {
      _logWarning(
        '[push][$requestId] register-token rejected: unknown deviceId',
      );
      return jsonNotFound(
        {
          'error': 'unknown_device',
          'message':
              'deviceId is not a paired device. Pair before registering a '
              'push token.',
          'requestId': requestId,
        },
        headers: {requestIdHeader: requestId},
      );
    }

    await db.upsertPushToken(
      deviceId: deviceId,
      platform: platform,
      token: token,
    );
    _logInfo(
      '[push][$requestId] registered $platform token for device=$deviceId',
    );
    return jsonOk(
      {'status': 'registered', 'deviceId': deviceId, 'platform': platform},
      headers: {requestIdHeader: requestId},
    );
  }

  /// `DELETE /api/push/token` — body `{deviceId}` (delete all of a device's
  /// tokens) or `{token}` (delete one stale token). At least one is required.
  ///
  /// Used on unpair / sign-out, and as the manual counterpart to the
  /// delivery's automatic stale-token cleanup. Idempotent — deleting an
  /// already-absent token is a 200.
  Future<Response> handleDeleteToken(Request request) async {
    final requestId = requestIdFrom(request);
    final payload = await readJsonObject(request);
    final deviceId = optionalString(payload, 'deviceId', maxLength: 128);
    final token = optionalString(payload, 'token', maxLength: 4096);

    if (deviceId == null && token == null) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message:
            'Provide deviceId (delete all of a device\'s tokens) or '
            'token (delete one).',
      );
    }

    // IDOR fix: a device may only delete ITS OWN tokens. Resolve the caller
    // up front and scope every delete to it.
    final caller = await _callerDeviceId(request);
    if (caller == null) {
      _logWarning(
        '[push][$requestId] delete-token rejected: caller is not an active '
        'paired device',
      );
      return jsonForbidden(
        {
          'error': 'forbidden',
          'message':
              'The authenticated session is not an active paired '
              'device.',
          'requestId': requestId,
        },
        headers: {requestIdHeader: requestId},
      );
    }

    final db = ensurePairingService().database;
    if (deviceId != null && deviceId != caller) {
      _logWarning(
        '[push][$requestId] delete-token rejected: caller=$caller may not '
        'delete tokens for deviceId=$deviceId',
      );
      return jsonForbidden(
        {
          'error': 'forbidden',
          'message': 'deviceId does not match the authenticated device.',
          'requestId': requestId,
        },
        headers: {requestIdHeader: requestId},
      );
    }
    if (deviceId != null) {
      await db.deletePushTokensForDevice(caller);
    }
    if (token != null) {
      // Only delete the token VALUE if it belongs to the caller's device;
      // deleting another device's token by value would be a cross-device
      // IDOR. Silent no-op (idempotent 200) when it isn't the caller's, so
      // an attacker can't probe other devices' token values via the status.
      final ownTokens = await db.getPushTokensForDevice(caller);
      if (ownTokens.any((row) => row.token == token)) {
        await db.deletePushToken(token);
      } else {
        _logWarning(
          '[push][$requestId] delete-token by-value ignored: token not owned '
          'by caller=$caller',
        );
      }
    }
    _logInfo(
      '[push][$requestId] deleted push tokens '
      '(deviceId=${deviceId ?? '-'}, byToken=${token != null})',
    );
    return jsonOk({'status': 'deleted'}, headers: {requestIdHeader: requestId});
  }

  /// `GET /api/push/preferences?deviceId=...` — the device's per-category mute
  /// matrix. Returns the all-enabled defaults when the device has never
  /// written a row (so a client can render the toggles before the first PUT).
  Future<Response> handleGetPreferences(Request request) async {
    final requestId = requestIdFrom(request);
    final deviceId = request.url.queryParameters['deviceId'];
    if (deviceId == null || deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: 'deviceId query parameter is required',
      );
    }

    // IDOR fix: a device may only read ITS OWN preferences (another device's
    // mute matrix is private — and probing it leaks who is paired).
    final ownership = await _requireOwnDevice(request, deviceId, requestId);
    if (ownership != null) return ownership;

    final db = ensurePairingService().database;
    final prefs = await db.getPushPrefs(deviceId);
    return jsonOk(
      {
        'deviceId': deviceId,
        // Default to all-enabled when no row exists — matches the delivery's
        // fail-open default so the rendered toggles and the actual gate agree.
        'enabled': prefs?.enabled ?? true,
        'muteSequenceFailed': prefs?.muteSequenceFailed ?? false,
        'muteWeatherUnsafe': prefs?.muteWeatherUnsafe ?? false,
        'muteGuidingLost': prefs?.muteGuidingLost ?? false,
        'muteAutofocusFailed': prefs?.muteAutofocusFailed ?? false,
        'muteEquipmentDisconnected': prefs?.muteEquipmentDisconnected ?? false,
      },
      headers: {requestIdHeader: requestId},
    );
  }

  /// `GET /api/push/targets` — can a critical alert actually reach a phone
  /// right now?
  ///
  /// The answer drives the desktop's "Push critical alerts to mobile" switch,
  /// which must never render as delivering when nothing can receive. On
  /// Android in a stock build nothing can: the FCM client is a dormant
  /// scaffold pending Firebase provisioning, so the phone registers no token
  /// and the count here stays 0. A would-send mock is likewise reported as a
  /// host with no cloud delivery — `deliveryChannel` names it as `mock` so a
  /// client can say so, but it never counts as delivery.
  ///
  /// Deliberately returns COUNTS and a verdict, never token values or device
  /// identifiers: a client that can read this must not be able to enumerate
  /// who else is paired, or lift another device's push token. Unlike the
  /// per-device preference routes this is not scoped to the caller's own
  /// device — it answers a host-wide capability question ("will an unattended
  /// failure reach anyone?") that any paired client is entitled to ask.
  Future<Response> handleGetTargets(Request request) async {
    final requestId = requestIdFrom(request);
    final db = ensurePairingService().database;

    final tokens = await db.getAllPushTokens();
    final deviceIds = <String>{};
    var fcm = 0;
    var apns = 0;
    for (final token in tokens) {
      deviceIds.add(token.deviceId);
      switch (token.platform) {
        case 'fcm':
          fcm++;
        case 'apns':
          apns++;
      }
    }

    final targets = PushDeliveryTargets(
      registeredDeviceCount: deviceIds.length,
      fcmTokenCount: fcm,
      apnsTokenCount: apns,
      channel: deliveryChannel(),
    );

    return jsonOk(targets.toJson(), headers: {requestIdHeader: requestId});
  }

  /// `PUT /api/push/preferences` — body `{deviceId, enabled, mute*}`.
  ///
  /// The client sends the full row each time (master `enabled` plus every
  /// mute flag); omitted flags default to "not muted" so a partial body is a
  /// reset-to-enabled rather than a silent re-mute. The `deviceId` MUST belong
  /// to a paired device.
  Future<Response> handlePutPreferences(Request request) async {
    final requestId = requestIdFrom(request);
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId', maxLength: 128);

    // IDOR fix: a device may only mutate ITS OWN preferences. Without this a
    // low-trust token could mute weatherUnsafe/guidingLost for another
    // operator's phone and silence their safety paging.
    final ownership = await _requireOwnDevice(request, deviceId, requestId);
    if (ownership != null) return ownership;

    final db = ensurePairingService().database;
    final device = await db.getPairedDevice(deviceId);
    if (device == null) {
      return jsonNotFound(
        {
          'error': 'unknown_device',
          'message': 'deviceId is not a paired device.',
          'requestId': requestId,
        },
        headers: {requestIdHeader: requestId},
      );
    }

    final enabled = optionalBool(payload, 'enabled') ?? true;
    final muteSequenceFailed =
        optionalBool(payload, 'muteSequenceFailed') ?? false;
    final muteWeatherUnsafe =
        optionalBool(payload, 'muteWeatherUnsafe') ?? false;
    final muteGuidingLost = optionalBool(payload, 'muteGuidingLost') ?? false;
    final muteAutofocusFailed =
        optionalBool(payload, 'muteAutofocusFailed') ?? false;
    final muteEquipmentDisconnected =
        optionalBool(payload, 'muteEquipmentDisconnected') ?? false;

    await db.upsertPushPrefs(
      deviceId: deviceId,
      enabled: enabled,
      muteSequenceFailed: muteSequenceFailed,
      muteWeatherUnsafe: muteWeatherUnsafe,
      muteGuidingLost: muteGuidingLost,
      muteAutofocusFailed: muteAutofocusFailed,
      muteEquipmentDisconnected: muteEquipmentDisconnected,
    );
    _logInfo(
      '[push][$requestId] updated preferences for device=$deviceId '
      '(enabled=$enabled)',
    );
    return jsonOk(
      {
        'deviceId': deviceId,
        'enabled': enabled,
        'muteSequenceFailed': muteSequenceFailed,
        'muteWeatherUnsafe': muteWeatherUnsafe,
        'muteGuidingLost': muteGuidingLost,
        'muteAutofocusFailed': muteAutofocusFailed,
        'muteEquipmentDisconnected': muteEquipmentDisconnected,
      },
      headers: {requestIdHeader: requestId},
    );
  }
}
