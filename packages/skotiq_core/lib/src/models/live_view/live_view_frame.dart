// Live-view stream frame model.
//
// Emitted by `NetworkBackend.subscribeLiveView()` once per JPEG frame
// pushed from the server's `/ws/live-view` socket. The actual JPEG bytes
// arrive as binary WS messages; the JSON envelope sent immediately
// before each binary frame carries the frame's metadata (dimensions,
// monotonic frame number, device id, server-side wall-clock timestamp).
//
// Why a paired metadata+binary protocol rather than base64-in-JSON:
// JPEGs at 1024 px on the long edge are 50-300 KB. Wrapping them in
// JSON adds ~33% bandwidth and forces a string<->bytes conversion on
// every frame. The binary WS frame goes straight from the socket into
// `Image.memory` (or `decodeImageFromList`) with no transcoding.

import 'dart:typed_data';

/// A single live-view JPEG frame plus its sidecar metadata.
class LiveViewFrame {
  /// JPEG-encoded frame bytes. Suitable to pass directly to
  /// `Image.memory(jpeg)` or `ui.decodeImageFromList(jpeg)`.
  final Uint8List jpeg;

  /// Device id the frame was captured from. Mirrors the `deviceId` the
  /// client passed in its `subscribe` message so a single socket
  /// multiplexing several cameras can route frames to the correct
  /// viewer.
  final String deviceId;

  /// Width of the encoded JPEG in pixels.
  final int width;

  /// Height of the encoded JPEG in pixels.
  final int height;

  /// Monotonically increasing frame counter assigned by the server.
  /// Starts at 1 on the first frame sent to a given subscriber, resets
  /// on resubscribe. Lets the client detect dropped frames (gap > 1) or
  /// out-of-order delivery (rare on WS, but possible on flaky links).
  final int frameNumber;

  /// UTC wall-clock time the server encoded the frame. Use only as a
  /// display hint; not monotonic and subject to NTP slew.
  final DateTime serverTimestamp;

  const LiveViewFrame({
    required this.jpeg,
    required this.deviceId,
    required this.width,
    required this.height,
    required this.frameNumber,
    required this.serverTimestamp,
  });

  /// Decode the sidecar JSON envelope. The companion `jpeg` field is
  /// filled in by the WS subscription loop once the next binary frame
  /// arrives.
  ///
  /// Throws [FormatException] on missing required fields. The
  /// subscription loop catches these and surfaces them as stream errors
  /// rather than silently dropping the frame — a malformed envelope
  /// almost certainly means a server/client wire-protocol mismatch and
  /// we want it loud.
  factory LiveViewFrame.fromMetadata(
    Map<String, Object?> json,
    Uint8List jpeg,
  ) {
    final deviceId = json['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) {
      throw const FormatException('LiveViewFrame metadata missing deviceId');
    }
    final width = json['width'];
    final height = json['height'];
    if (width is! int || height is! int || width <= 0 || height <= 0) {
      throw FormatException(
        'LiveViewFrame metadata width/height invalid: '
        'width=$width height=$height',
      );
    }
    final frameNumberRaw = json['frameNumber'];
    final frameNumber = frameNumberRaw is int ? frameNumberRaw : 0;
    final tsRaw = json['serverTimestamp'];
    final ts = tsRaw is String ? DateTime.tryParse(tsRaw) : null;
    return LiveViewFrame(
      jpeg: jpeg,
      deviceId: deviceId,
      width: width,
      height: height,
      frameNumber: frameNumber,
      serverTimestamp: ts ?? DateTime.now().toUtc(),
    );
  }
}

/// Optional crop region used in `subscribe` messages. Coordinates are
/// in the *master* (pre-downscale) JPEG's coordinate system so a phone
/// rendering a zoomed preview at 1024 px can ask the server to crop
/// out a 1024×1024 region from the centre of a 4000×4000 sensor without
/// first downloading the full frame.
class LiveViewRegion {
  final int x;
  final int y;
  final int width;
  final int height;

  const LiveViewRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'w': width, 'h': height};

  factory LiveViewRegion.fromJson(Map<String, Object?> json) {
    final x = (json['x'] as num?)?.toInt() ?? 0;
    final y = (json['y'] as num?)?.toInt() ?? 0;
    final w = (json['w'] as num?)?.toInt() ?? 0;
    final h = (json['h'] as num?)?.toInt() ?? 0;
    if (w <= 0 || h <= 0) {
      throw FormatException('LiveViewRegion w/h must be positive: w=$w h=$h');
    }
    return LiveViewRegion(x: x, y: y, width: w, height: h);
  }
}
