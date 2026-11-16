part of '../network_backend.dart';

/// The runtime state a linked imaging host mirrors to its clients, and what a client reports back.
final class HostRuntimeMirror {
  HostRuntimeMirror(this._host);

  final NetworkBackend _host;

  /// The host's latest value of every runtime channel.
  Future<List<HostRuntimeUpdate>> getHostRuntimeState() async {
    final response = await _host._get(RuntimeStateApi.getState);
    final raw = response['updates'];
    if (raw is! List) {
      throw const FormatException('runtime/state has no updates list');
    }
    final updates = <HostRuntimeUpdate>[];
    for (final item in raw.whereType<Map>()) {
      final update = HostRuntimeUpdate.fromJson(
        Map<String, dynamic>.from(item),
      );
      if (update != null) updates.add(update);
    }
    return updates;
  }

  /// Send a value this client computed for [channel] to the host.
  Future<void> reportRuntimeState({
    required String channel,
    required Map<String, dynamic>? value,
    required String origin,
  }) async {
    await _host._post(
      RuntimeStateApi.report,
      body: {'channel': channel, 'value': value, 'origin': origin},
      maxAttempts: 1,
    );
  }

  /// Invalidate device cache (called when "Scan Network" is clicked)
  void invalidateDeviceCache() {
    Log.info('[NetworkBackend] Cache invalidated', source: 'NetworkBackend');
    _host._cachedDevices = null;
    _host._cachedDevicesByType = null;
    _host._cacheTimestamp = null;
  }

  /// [maxWidth] asks the host for a smaller JPEG; the frame still comes
  /// back at the sensor's size (see [capturedImageFromRemoteJpegWire]), so
  /// overlays and zoom keep their geometry. Null is the full frame.
  Future<CapturedImageResult?> cameraGetLastImage(
    String deviceId, {
    int? maxWidth,
  }) async {
    try {
      final downloaded = await _host._downloadBytesWithHeaders(
        DeviceApi.cameraGetLastImageJpeg,
        query: {
          'deviceId': deviceId,
          if (maxWidth != null) 'maxWidth': '$maxWidth',
        },
      );
      final metaHeader = _host._headerValue(downloaded.headers, 'x-image-meta');
      if (metaHeader == null || metaHeader.isEmpty) {
        throw const dart_error.SkotiqError(
          category: dart_error.BackendErrorCategory.validation,
          message:
              'GET /api/camera/last-image/jpeg missing x-image-meta header',
        );
      }
      return await decodeRemoteJpegWire(
        jpegBytes: downloaded.bytes,
        metaHeaderBase64: metaHeader,
      );
    } on ServerError catch (e) {
      // No image cached yet.
      if (e.httpStatus == 404 || e.code == 'no_image') {
        return null;
      }
      rethrow;
    }
  }
}
