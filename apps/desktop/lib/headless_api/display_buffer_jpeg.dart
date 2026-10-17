import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:skotiq_core/skotiq_core.dart';

/// Result of encoding a host [CapturedImageResult.displayData] buffer to JPEG.
class DisplayBufferJpegEncodeResult {
  const DisplayBufferJpegEncodeResult({
    required this.bytes,
    required this.encodedWidth,
    required this.encodedHeight,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.metaHeaderValue,
  });

  final Uint8List bytes;
  final int encodedWidth;
  final int encodedHeight;
  final int sourceWidth;
  final int sourceHeight;

  /// Value for the `x-image-meta` response header (base64 JSON).
  final String metaHeaderValue;
}

/// Return a wire-safe UTC timestamp for camera frames.
String capturedImageTimestampUtc(String value) => normalizeUtcTimestamp(value);

/// Tail of the encode queue. Only one full-resolution encode runs at a time:
/// `/api/run-watch/frame-thumbnail` is documented for 2-5 Hz polling, and an
/// unbounded fan-out would hold one sensor-sized buffer per in-flight isolate.
/// Errors are routed into each caller's completer so the tail never rejects
/// and the queue cannot poison.
Future<void> _encodeTail = Future<void>.value();

Future<T> _serializeEncode<T>(Future<T> Function() body) {
  final result = Completer<T>();
  _encodeTail = _encodeTail.then((_) async {
    try {
      result.complete(await body());
    } catch (error, stack) {
      result.completeError(error, stack);
    }
  });
  return result.future;
}

/// Runs on a worker isolate. [pixels] arrives as a zero-copy transfer and is
/// materialised into a buffer whose length is exactly `width * height * 4`,
/// which is what `img.Image.fromBytes` requires of the `ByteBuffer` it takes.
Uint8List _encodeRgbaToJpeg({
  required TransferableTypedData pixels,
  required int sourceWidth,
  required int sourceHeight,
  required int encodedWidth,
  required int encodedHeight,
  required int quality,
}) {
  var bitmap = img.Image.fromBytes(
    width: sourceWidth,
    height: sourceHeight,
    bytes: pixels.materialize(),
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  if (encodedWidth != sourceWidth || encodedHeight != sourceHeight) {
    bitmap = img.copyResize(bitmap, width: encodedWidth, height: encodedHeight);
  }
  return img.encodeJpg(bitmap, quality: quality);
}

/// Encode stretched RGBA [CapturedImageResult.displayData] to JPEG.
///
/// The resize + encode run on a worker isolate. In the desktop GUI the
/// headless server shares the Flutter root isolate, so encoding a full-sensor
/// frame inline would stall painting and every other in-flight request for the
/// duration (measured at 285 ms for 1800x1800).
///
/// Returns `null` when the display buffer size does not match width×height×4.
Future<DisplayBufferJpegEncodeResult?> encodeCapturedImageDisplayBufferToJpeg(
  CapturedImageResult image, {
  int maxWidth = 0,
  int quality = 85,
}) async {
  final expected = image.width * image.height * 4;
  if (image.displayData.length != expected) {
    return null;
  }

  // On the native path `displayData` already is a `Uint8List`; copying it
  // would cost width×height×4 bytes per request (~104 MB on a 26 MP sensor).
  // The JSON transport path hands back a `List<int>`, which still needs one.
  final source = image.displayData;
  final rgba = source is Uint8List ? source : Uint8List.fromList(source);

  var encodedWidth = image.width;
  var encodedHeight = image.height;
  if (maxWidth > 0 && image.width > maxWidth) {
    encodedHeight = (image.height * (maxWidth / image.width)).round().clamp(
      1,
      1 << 16,
    );
    encodedWidth = maxWidth;
  }

  // Everything the worker closure reads must be a local: capturing `image`
  // would ship the whole CapturedImageResult — display buffer included —
  // across the port and undo the transfer above.
  final pixels = TransferableTypedData.fromList([rgba]);
  final sourceWidth = image.width;
  final sourceHeight = image.height;
  final targetWidth = encodedWidth;
  final targetHeight = encodedHeight;
  final clampedQuality = quality.clamp(1, 100);
  final jpeg = await _serializeEncode(
    () => Isolate.run(
      () => _encodeRgbaToJpeg(
        pixels: pixels,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        encodedWidth: targetWidth,
        encodedHeight: targetHeight,
        quality: clampedQuality,
      ),
    ),
  );

  final metaJson = jsonEncode({
    'width': image.width,
    'height': image.height,
    'encodedWidth': encodedWidth,
    'encodedHeight': encodedHeight,
    'histogram': image.histogram,
    'stats': image.stats.toJson(),
    'exposureTime': image.exposureTime,
    'timestamp': capturedImageTimestampUtc(image.timestamp),
    'isColor': image.isColor,
  });

  return DisplayBufferJpegEncodeResult(
    bytes: jpeg,
    encodedWidth: encodedWidth,
    encodedHeight: encodedHeight,
    sourceWidth: image.width,
    sourceHeight: image.height,
    metaHeaderValue: base64Encode(utf8.encode(metaJson)),
  );
}

/// Decode the `x-image-meta` header produced by [encodeCapturedImageDisplayBufferToJpeg].
Map<String, dynamic> decodeImageMetaHeader(String headerValue) {
  final decoded = utf8.decode(base64Decode(headerValue));
  return jsonDecode(decoded) as Map<String, dynamic>;
}
