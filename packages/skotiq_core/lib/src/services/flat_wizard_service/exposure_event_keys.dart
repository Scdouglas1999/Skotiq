part of '../flat_wizard_service.dart';

/// Clamp [value] into the inclusive `[lo, hi]` capability range when known.
/// A null [value] stays null (the camera/driver default is used).
int? _clampToRange(int? value, int? lo, int? hi) {
  if (value == null) return null;
  var v = value;
  if (lo != null && v < lo) v = lo;
  if (hi != null && v > hi) v = hi;
  return v;
}

/// Imaging event types that terminate an in-flight exposure. Anything else
/// on the stream (progress, temperature, download-started, unrelated
/// categories) is ignored so the wait cannot be woken by a stray event.
const Set<String> _terminalExposureEventTypes = {
  'ExposureComplete',
  'ExposureCompleted',
  'ExposureFailed',
  'ExposureCancelled',
};

/// Keys under which an imaging event may carry the originating camera id.
/// FFI-originated exposure events do NOT carry any of these (the native side
/// has a single active camera), so absence means "accept" (operation
/// scoping). When a key IS present it MUST match the camera we drove, so a
/// second camera's completion on a shared stream can never satisfy our wait.
const List<String> _deviceIdKeys = [
  'deviceId',
  'device_id',
  'cameraId',
  'camera_id',
];
