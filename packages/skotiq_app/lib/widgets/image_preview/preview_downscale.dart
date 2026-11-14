import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

/// Resamples premultiplied RGBA pixels by their covered area.
///
/// Unlike point sampling, every source pixel contributes when a small preview
/// contains a narrow star. The source buffer stays available for native zoom;
/// only the smaller result is copied into Flutter's immutable image buffer.
/// Brief work slices let a new frame or zoom cancel the resize. Checking the
/// time after bounded pixel batches avoids a timer wakeup for every small batch.
Future<Uint8List?> downscalePreviewRgba({
  required Uint8List pixels,
  required int width,
  required int height,
  required int targetWidth,
  required int targetHeight,
  required bool Function() isCancelled,
}) async {
  if (width <= 0 ||
      height <= 0 ||
      targetWidth <= 0 ||
      targetHeight <= 0 ||
      targetWidth > width ||
      targetHeight > height ||
      pixels.length != width * height * 4) {
    throw ArgumentError('Invalid preview pixel dimensions');
  }
  if (isCancelled()) return null;
  if (targetWidth == width && targetHeight == height) return pixels;

  // Leave the post-frame callback before allocating or scanning image data.
  await Future<void>.delayed(Duration.zero);
  if (isCancelled()) return null;
  final slice = Stopwatch()..start();
  final result = Uint8List(targetWidth * targetHeight * 4);
  final scaleX = width / targetWidth;
  final scaleY = height / targetHeight;
  final area = scaleX * scaleY;
  const samplesPerBatch = 8192;
  var samples = 0;
  var output = 0;

  for (var y = 0; y < targetHeight; y++) {
    final top = y * scaleY;
    final bottom = math.min((y + 1) * scaleY, height.toDouble());
    for (var x = 0; x < targetWidth; x++) {
      final left = x * scaleX;
      final right = math.min((x + 1) * scaleX, width.toDouble());
      var red = 0.0;
      var green = 0.0;
      var blue = 0.0;
      var alpha = 0.0;
      for (var sourceY = top.floor(); sourceY < bottom; sourceY++) {
        final yWeight =
            math.min(sourceY + 1.0, bottom) - math.max(sourceY.toDouble(), top);
        var input = (sourceY * width + left.floor()) * 4;
        for (var sourceX = left.floor(); sourceX < right; sourceX++) {
          final weight = yWeight *
              (math.min(sourceX + 1.0, right) -
                  math.max(sourceX.toDouble(), left));
          red += pixels[input] * weight;
          green += pixels[input + 1] * weight;
          blue += pixels[input + 2] * weight;
          alpha += pixels[input + 3] * weight;
          input += 4;

          if (++samples == samplesPerBatch) {
            samples = 0;
            if (slice.elapsedMicroseconds >= 1000) {
              await Future<void>.delayed(Duration.zero);
              if (isCancelled()) return null;
              slice.reset();
            }
          }
        }
      }
      result[output++] = (red / area).round();
      result[output++] = (green / area).round();
      result[output++] = (blue / area).round();
      result[output++] = (alpha / area).round();
    }
  }
  return isCancelled() ? null : result;
}
