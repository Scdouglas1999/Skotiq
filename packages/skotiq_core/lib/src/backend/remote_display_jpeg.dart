import 'dart:convert';
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

  final rgba = decoded.getBytes(order: img.ChannelOrder.rgba);
  final statsJson = meta['stats'] as Map<String, dynamic>;

  return CapturedImageResult(
    width: meta['width'] as int,
    height: meta['height'] as int,
    displayData: rgba,
    histogram: List<int>.from(meta['histogram'] as List),
    stats: ImageStatsResult.fromJson(statsJson),
    exposureTime: (meta['exposureTime'] as num).toDouble(),
    timestamp: meta['timestamp'] as String,
    isColor: meta['isColor'] as bool? ?? false,
  );
}
