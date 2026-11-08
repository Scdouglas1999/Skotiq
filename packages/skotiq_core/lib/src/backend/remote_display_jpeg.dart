import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/backend/image_result.dart';

/// Decode a remote host JPEG frame plus `x-image-meta` into [CapturedImageResult].
///
/// The wire format is produced by the headless `GET /api/camera/last-image/jpeg`
/// endpoint. [jpegBytes] are decoded to RGBA for UI consumers that expect
/// [CapturedImageResult.displayData].
CapturedImageResult capturedImageFromRemoteJpegWire({
  required Uint8List jpegBytes,
  required String metaHeaderBase64,
}) {
  final meta =
      jsonDecode(utf8.decode(base64Decode(metaHeaderBase64)))
          as Map<String, dynamic>;

  final decoded = img.decodeImage(jpegBytes);
  if (decoded == null) {
    throw const FormatException(
      'JPEG decode failed for remote last-image payload',
    );
  }

  final width = meta['width'] as int;
  final height = meta['height'] as int;
  var rgba = decoded.getBytes(order: img.ChannelOrder.rgba);
  if (decoded.width != width || decoded.height != height) {
    rgba = _nearestRgba(rgba, decoded.width, decoded.height, width, height);
  }
  final statsJson = meta['stats'] as Map<String, dynamic>;

  return CapturedImageResult(
    width: width,
    height: height,
    displayData: rgba,
    histogram: List<int>.from(meta['histogram'] as List),
    stats: ImageStatsResult.fromJson(statsJson),
    exposureTime: (meta['exposureTime'] as num).toDouble(),
    timestamp: meta['timestamp'] as String,
    isColor: meta['isColor'] as bool? ?? false,
  );
}

/// A preview JPEG smaller than the sensor, spread back over the sensor's
/// pixels. Everything that draws over the frame (stars, the catalog, a solve)
/// and every zoom works in sensor pixels, and the display buffer is always
/// width x height x 4; a nearest-neighbor spread keeps both true at a cost of
/// about 150 ms for 26 MP.
Uint8List _nearestRgba(
  Uint8List source,
  int sourceWidth,
  int sourceHeight,
  int width,
  int height,
) {
  final aligned = source.offsetInBytes % 4 == 0
      ? source
      : Uint8List.fromList(source);
  final src = aligned.buffer.asUint32List(
    aligned.offsetInBytes,
    sourceWidth * sourceHeight,
  );
  final out = Uint8List(width * height * 4);
  final dst = out.buffer.asUint32List();
  final columns = Int32List(width);
  for (var x = 0; x < width; x++) {
    columns[x] = x * sourceWidth ~/ width;
  }
  for (var y = 0; y < height; y++) {
    final from = (y * sourceHeight ~/ height) * sourceWidth;
    final to = y * width;
    for (var x = 0; x < width; x++) {
      dst[to + x] = src[from + columns[x]];
    }
  }
  return out;
}

/// [capturedImageFromRemoteJpegWire] on a worker isolate.
///
/// The decode is pure Dart: 2.9 s for a 26 MP frame on a desktop CPU, during
/// which a linked client's whole UI stood still each time the host announced
/// a frame. The RGBA result comes back without a copy.
Future<CapturedImageResult> decodeRemoteJpegWire({
  required Uint8List jpegBytes,
  required String metaHeaderBase64,
}) {
  return Isolate.run(
    () => capturedImageFromRemoteJpegWire(
      jpegBytes: jpegBytes,
      metaHeaderBase64: metaHeaderBase64,
    ),
    debugName: 'remote-jpeg-decode',
  );
}
