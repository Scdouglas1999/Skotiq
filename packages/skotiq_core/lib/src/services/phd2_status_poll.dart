import '../backend/roles/guiding_backend.dart';
import '../models/backend/phd2_status.dart';
import '../utils/device_id.dart';

/// Status returned when the host has no active PHD2 client.
const Phd2Status kPhd2DisconnectedStatus = Phd2Status(
  state: 'Disconnected',
  connected: false,
);

/// Default wait after launch/connect before giving up.
const Duration kPhd2PollTimeout = Duration(seconds: 30);

/// Poll interval while waiting for PHD2 socket + client registration.
const Duration kPhd2PollInterval = Duration(milliseconds: 500);

/// Legacy aliases for tests and callers that used the earlier constant names.
const Duration phd2StatusPollTimeout = kPhd2PollTimeout;
const Duration phd2StatusPollInterval = kPhd2PollInterval;

/// Whether a guiding event indicates PHD2 is still reachable (not link loss).
bool isPhd2GuidingHeartbeatEvent(String eventType) {
  switch (eventType) {
    case 'Disconnected':
    case 'LostStar':
    case 'UnknownGuidingEvent':
      return false;
    case 'GuideStep':
    case 'GuideStats':
    case 'Connected':
    case 'AppState':
    case 'GuidingStarted':
    case 'GuidingStopped':
    case 'Paused':
    case 'Resumed':
    case 'Settling':
    case 'SettleDone':
    case 'LoopingExposures':
    case 'Calibrating':
    case 'CalibrationComplete':
      return true;
    default:
      return false;
  }
}

/// Whether [deviceId] is a PHD2 guider id, matched EXACTLY (no trim, no case
/// folding) — unlike [isPhd2DeviceId], which normalizes first.
///
/// The difference is deliberate and preserved: this screens ids that arrived
/// over the wire already canonical, so `'PHD2_GUIDER'` and `'  phd2  '` are
/// correctly NOT PHD2 here while they ARE for [isPhd2DeviceId]. Only the token
/// list is shared ([isPhd2WireToken]) so the four spellings cannot drift apart.
bool isPhd2GuiderDeviceId(String? deviceId) {
  if (deviceId == null || deviceId.isEmpty) return false;
  return isPhd2WireToken(deviceId);
}

/// Resolve PHD2 TCP host for local connections (avoids Windows localhost/IPv6).
String resolvePhd2ConnectHost(String host) {
  final normalized = host.trim().toLowerCase();
  if (normalized.isEmpty || normalized == 'localhost' || normalized == '::1') {
    return '127.0.0.1';
  }
  return host.trim();
}

/// Poll [backend.phd2GetStatus] until PHD2 reports connected or [timeout].
///
/// Transient errors (host still launching PHD2, status endpoint not ready)
/// are retried instead of failing immediately.
Future<Phd2Status> pollPhd2Connected(
  GuidingBackend backend, {
  Duration timeout = kPhd2PollTimeout,
  Duration interval = kPhd2PollInterval,
}) async {
  final deadline = DateTime.now().add(timeout);
  Object? lastError;

  while (DateTime.now().isBefore(deadline)) {
    try {
      final status = await backend.phd2GetStatus();
      if (status.connected) {
        return status;
      }
      lastError = null;
    } catch (e) {
      lastError = e;
    }

    if (DateTime.now().add(interval).isAfter(deadline)) {
      break;
    }
    await Future<void>.delayed(interval);
  }

  try {
    final status = await backend.phd2GetStatus();
    if (status.connected) {
      return status;
    }
  } catch (e) {
    lastError = e;
  }

  if (lastError != null) {
    throw StateError(
      'PHD2 did not report a connection within ${timeout.inSeconds}s: $lastError',
    );
  }
  throw StateError(
    'PHD2 did not report a connection within ${timeout.inSeconds}s.',
  );
}

/// Best-effort status read; returns disconnected when the host has no client.
Future<Phd2Status> readPhd2StatusOrDisconnected(GuidingBackend backend) async {
  try {
    return await backend.phd2GetStatus();
  } catch (_) {
    return kPhd2DisconnectedStatus;
  }
}
