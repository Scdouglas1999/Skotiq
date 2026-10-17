// APNs push-token registration (Phase E iOS side).
//
// Bridges the native AppDelegate APNs registration to the Phase D desktop
// server. The flow end to end:
//
//   1. The iOS host (apps/mobile/ios/Runner/AppDelegate.swift) owns the APNs
//      lifecycle: `registerForRemoteNotifications` -> the OS issues a device
//      token -> `didRegisterForRemoteNotificationsWithDeviceToken` encodes it
//      as lowercase hex and either pushes it to Dart via the
//      `skotiq/push` MethodChannel method `onApnsToken`, or caches it for
//      a later `getApnsToken` pull.
//   2. This service asks the host to register (once the phone is paired),
//      receives the hex token, and POSTs it to the desktop's
//      `POST /api/push/register-token` with `platform=apns`, authenticated
//      with the same bearer token the rest of the companion's REST traffic
//      uses. The server keys the token on the paired `deviceId`.
//   3. When the desktop later needs to wake a backgrounded/asleep phone with a
//      critical safety alert that the LAN UDP broadcaster cannot reach (phone
//      off-LAN, socket suspended), its remote-push delivery looks the token up
//      and sends an APNs push.
//
// Android (FCM) rides the same flow through the same channel: the native
// half is PushBridge.kt (+ SkotiqPushService for token rotation), the
// callbacks are `onFcmToken` / `getFcmToken`, and the POST registers with
// `platform=fcm`. PROVISIONING GATE: without `android/app/google-services.json`
// (owner's Firebase project) the native side answers
// `registerForRemoteNotifications` with a `fcm_unconfigured` PlatformException
// and this service logs + stays dormant — Android alerting then remains the
// LAN UDP receiver only (see lan_push_notification_receiver.dart). The
// server-side FCM sender (FcmRemotePushDelivery) is fully built and activates
// via the host's push config + service-account JSON. End-to-end delivery is
// UNVERIFIED until a real Firebase project is provisioned — the build, the
// dormant no-op path, and the registration POST are what's tested.
//
// Platform gating: a no-op on every platform except iOS and Android, where
// `ensureRegistered` returns immediately without touching the (absent)
// `skotiq/push` channel, so a `MissingPluginException` can never be
// thrown.
//
// Server contract note: the endpoint validates `platform` against the set
// {'fcm', 'apns'} (see apps/desktop/lib/headless_api/handlers/push_handlers.dart),
// NOT {'ios','android'} — iOS registers as `apns`, Android as `fcm`. The
// `deviceId` MUST be the same id the device paired with
// (MobilePairingService.deviceId()), or the server returns 404 unknown_device
// and the token is rejected.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';

/// Registers this device's push token (APNs on iOS, FCM on Android) with a
/// paired desktop server so the server can deliver off-LAN critical alerts.
/// A no-op on other platforms.
class PushRegistrationService {
  PushRegistrationService({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting http.Client? httpClient,
    @visibleForTesting bool? isIosOverride,
    @visibleForTesting bool? isAndroidOverride,
  }) : _channel = channel ?? const MethodChannel('skotiq/push'),
       _http = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _isIos = isIosOverride ?? Platform.isIOS,
       _isAndroid = isAndroidOverride ?? Platform.isAndroid {
    // The host pushes the token to us via `onApnsToken` / `onFcmToken` the
    // moment the OS issues it. We attach the handler eagerly (even before
    // `ensureRegistered`) so a token that arrives during launch — racing our
    // registration call — is never dropped.
    if (_isIos || _isAndroid) {
      _channel.setMethodCallHandler(_handleHostCall);
    }
  }

  final MethodChannel _channel;
  final http.Client _http;
  final bool _ownsHttpClient;
  final bool _isIos;
  final bool _isAndroid;

  /// Wire platform id the server's register-token endpoint expects.
  String get _platform => _isIos ? 'apns' : 'fcm';

  /// The most recent server target + identity, captured on [ensureRegistered]
  /// so a late-arriving `onApnsToken` (pushed by the host after we returned)
  /// can still be registered against the right host without re-plumbing.
  _RegistrationTarget? _target;

  /// The last `(host:port + deviceId + token)` tuple we successfully POSTed,
  /// to suppress redundant re-posts on every foreground (APNs hands back the
  /// same token unless it rotated).
  ///
  /// CRITICAL: the gate keys on the *target* (host:port) and deviceId, not just
  /// the token. APNs returns the SAME token across desktop servers, so gating
  /// on the token alone would skip the POST after a re-pair/server-switch and
  /// the new server would never learn the token — silently losing the cellular
  /// safety-push path. Including the target forces a re-POST whenever we switch
  /// or re-pair a server even when the token itself is unchanged.
  String? _lastRegistered;

  /// Ensure this device's APNs token is registered with [backend] for the
  /// paired [deviceId].
  ///
  /// Safe to call repeatedly (on pair, on connect, on app-foreground). It:
  ///   * returns immediately and silently on non-iOS,
  ///   * asks the host to (re)register for remote notifications,
  ///   * pulls any already-cached token synchronously (covers the case where
  ///     the OS callback fired before this Dart object existed),
  ///   * POSTs the token if we have one and the
  ///     `(host:port + deviceId + token)` tuple changed since last time (so a
  ///     server switch re-POSTs even when APNs hands back the same token).
  ///
  /// Never throws to the caller — push registration is best-effort and must
  /// not break the connect path. Failures are logged.
  Future<void> ensureRegistered({
    required NetworkBackend backend,
    required String deviceId,
  }) async {
    if (!_isIos && !_isAndroid) {
      return;
    }
    if (deviceId.isEmpty) {
      developer.log(
        'Skipping $_platform registration: empty deviceId (not paired yet)',
        name: 'PushRegistration',
      );
      return;
    }

    _target = _RegistrationTarget(
      scheme: backend.scheme,
      host: backend.serverHost,
      port: backend.serverPort,
      authToken: backend.authToken,
      deviceId: deviceId,
    );

    try {
      // Ask the OS to (re)issue a token. The host returns immediately; the
      // token arrives asynchronously via `onApnsToken`, or we pull the cached
      // value below if registration already completed.
      await _channel.invokeMethod<bool>('registerForRemoteNotifications');
    } on MissingPluginException {
      // Defensive: should be unreachable on iOS/Android (the host always
      // registers the channel). Treat as "host has no push support" rather
      // than crashing.
      developer.log(
        'skotiq/push channel unavailable; $_platform registration skipped',
        name: 'PushRegistration',
      );
      return;
    } on PlatformException catch (e) {
      if (e.code == 'fcm_unconfigured') {
        // Expected on Android builds without google-services.json: the owner
        // has not provisioned a Firebase project, so background push is
        // dormant by design. Info-level, not an error.
        developer.log(
          'FCM not provisioned in this build; background push dormant',
          name: 'PushRegistration',
        );
        return;
      }
      developer.log(
        'registerForRemoteNotifications failed: ${e.message}',
        name: 'PushRegistration',
        level: 900,
      );
      // Fall through — a token may still be cached from a prior launch.
    }

    final cached = await _cachedToken();
    if (cached != null && cached.isNotEmpty) {
      await _postToken(cached);
    }
  }

  /// Forget the last-registered tuple so the next [ensureRegistered] re-POSTs
  /// even if the OS hands back the same token. Call on unpair / server switch
  /// so a token isn't assumed registered against a server it was never sent to.
  ///
  /// The target-keyed no-op gate ([_lastRegistered]) already forces a re-POST
  /// on a server switch on its own; this stays as an explicit belt-and-braces
  /// hook for disconnect/unpair where the caller wants to drop all cached
  /// registration state.
  void reset() {
    _lastRegistered = null;
    _target = null;
  }

  /// Releases the owned HTTP client. No-op if a client was injected.
  void dispose() {
    if (_ownsHttpClient) {
      _http.close();
    }
  }

  Future<String?> _cachedToken() async {
    final method = _isIos ? 'getApnsToken' : 'getFcmToken';
    try {
      return await _channel.invokeMethod<String>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      developer.log(
        '$method failed: ${e.message}',
        name: 'PushRegistration',
        level: 900,
      );
      return null;
    }
  }

  Future<dynamic> _handleHostCall(MethodCall call) async {
    switch (call.method) {
      case 'onApnsToken':
      case 'onFcmToken':
        final token = call.arguments as String?;
        if (token != null && token.isNotEmpty) {
          await _postToken(token);
        }
        return null;
      case 'onApnsRegistrationError':
      case 'onFcmRegistrationError':
        developer.log(
          '$_platform registration error from host: ${call.arguments}',
          name: 'PushRegistration',
          level: 900,
        );
        return null;
      default:
        // Unknown host->Dart call. Surface loudly in dev logs but don't throw
        // back across the channel.
        developer.log(
          'Unhandled skotiq/push call: ${call.method}',
          name: 'PushRegistration',
          level: 900,
        );
        return null;
    }
  }

  /// POST the hex APNs token to the paired server's register-token endpoint.
  /// Idempotent server-side (upsert keyed on deviceId+platform); we additionally
  /// suppress a redundant re-POST when the `(host:port + deviceId + token)`
  /// tuple is unchanged, to save a round trip — but a target/deviceId change
  /// always re-POSTs even when APNs hands back the same token.
  Future<void> _postToken(String token) async {
    final target = _target;
    if (target == null) {
      // Token arrived before any `ensureRegistered` captured a server. Hold it
      // implicitly: the next ensureRegistered pulls it via getApnsToken.
      developer.log(
        '$_platform token received before a registration target was set; '
        'will register on next connect',
        name: 'PushRegistration',
      );
      return;
    }
    // Key the no-op gate on (host:port + deviceId + token), NOT the token
    // alone. APNs hands back the same token across servers, so a token-only
    // gate would skip this POST after a re-pair/server-switch and the new
    // server would never learn the token. Folding the target in forces a
    // re-POST whenever we point at a different host/port or pair as a
    // different deviceId, even when the token itself is unchanged.
    final registrationKey =
        '${target.host}:${target.port}|${target.deviceId}|$token';
    if (registrationKey == _lastRegistered) {
      return;
    }

    final uri = Uri(
      scheme: target.scheme,
      host: target.host,
      port: target.port,
      path: '/api/push/register-token',
    );
    try {
      final response = await _http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              if (target.authToken != null && target.authToken!.isNotEmpty)
                'Authorization': 'Bearer ${target.authToken}',
            },
            body: jsonEncode({
              'deviceId': target.deviceId,
              'platform': _platform,
              'token': token,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        _lastRegistered = registrationKey;
        developer.log(
          'Registered $_platform token with ${target.host}:${target.port}',
          name: 'PushRegistration',
        );
      } else {
        developer.log(
          'register-token rejected (${response.statusCode}): ${response.body}',
          name: 'PushRegistration',
          level: 900,
        );
      }
    } catch (e) {
      // Network error, server down, timeout — best-effort, retried next
      // foreground/connect.
      developer.log(
        'register-token POST failed: $e',
        name: 'PushRegistration',
        level: 900,
      );
    }
  }
}

/// Immutable snapshot of where to register and as whom.
class _RegistrationTarget {
  const _RegistrationTarget({
    required this.scheme,
    required this.host,
    required this.port,
    required this.authToken,
    required this.deviceId,
  });

  final String scheme;
  final String host;
  final int port;
  final String? authToken;
  final String deviceId;
}
