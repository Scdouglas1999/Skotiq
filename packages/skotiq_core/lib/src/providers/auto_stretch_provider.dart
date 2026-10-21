import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../models/equipment/equipment_models.dart';
import '../models/imaging/auto_stretch_settings.dart';
import '../models/imaging/imaging_models.dart' show RawLoadStatus;
import '../models/imaging/imaging_models.dart';
import '../services/imaging_service.dart';
import 'backend_provider.dart';
import 'equipment_provider.dart';
import 'imaging_provider.dart';

// Stretched image provider

/// Provider that renders the current captured image for the screen.
///
/// The result is PREVIEW ONLY: the original data is never modified. Null means
/// "show the frame's own display data", which already carries the default
/// screen stretch (the native STF applied when the frame was read out). So:
///
/// * stretch on with the default STF parameters: null, nothing to compute;
/// * stretch on with another method or tuned parameters: that stretch of the
///   raw pixels;
/// * stretch off: the raw pixels scaled linearly, darkest to brightest.
///
/// The linear and Dart stretches run in an isolate so they cannot block the
/// UI thread.
final stretchedImageProvider = FutureProvider.autoDispose<Uint8List?>((
  ref,
) async {
  final settings = ref.watch(autoStretchSettingsProvider);

  if (settings.enabled && isDefaultScreenStretch(settings)) {
    return null;
  }

  final imageData = ref.watch(currentImageProvider);
  if (imageData == null) {
    return null;
  }

  // Check if we have raw data available from the backend
  final backend = ref.watch(deviceBackendProvider);
  final cameraDeviceId = ref.read(connectedCameraIdProvider);

  try {
    Uint16List? rawData = imageData.hasRawReady ? imageData.rawU16 : null;

    if (rawData == null) {
      if (imageData.rawLoadStatus == RawLoadStatus.loading) {
        // The frame is published again when its raw pixels land, which runs
        // this again. Until then stay loading, so the screen keeps what it
        // shows instead of flashing the stretched display data in between.
        return Completer<Uint8List?>().future;
      }
      if (cameraDeviceId == null) {
        // No raw pixels to be had: the display data stays up.
        return null;
      }

      rawData = rawPixelsFromBackend(
        await backend.getLastRawImageData(cameraDeviceId),
        pixelCount: imageData.width * imageData.height,
      );
      if (rawData == null) {
        return null;
      }
    }

    if (!settings.enabled) {
      return compute(
        linearDisplayRgba,
        LinearDisplayParams(rawData, imageData.width, imageData.height),
      );
    }

    // Apply stretch based on method
    return await _applyStretch(
      rawData: rawData,
      width: imageData.width,
      height: imageData.height,
      isColor: imageData.isColor,
      settings: settings,
    );
  } catch (e) {
    // On error, fall back to the original display data (already stretched)
    developer.log(
      '[AutoStretch] Error applying stretch: $e',
      name: 'AutoStretch',
      level: 1000,
      error: e,
    );
    return null;
  }
});

/// The camera's last raw frame as 16-bit samples: one per pixel (mono or a
/// colour sensor's mosaic) or three (debayered RGB). The local bridge hands
/// back one value per sample and a remote host the little-endian bytes; null
/// when the length fits neither for [pixelCount] pixels (another frame's, or
/// none).
Uint16List? rawPixelsFromBackend(List<int> raw, {required int pixelCount}) {
  if (raw.isEmpty || pixelCount <= 0) return null;
  if (raw.length == pixelCount || raw.length == pixelCount * 3) {
    return raw is Uint16List ? raw : Uint16List.fromList(raw);
  }
  if (raw.length == pixelCount * 2 || raw.length == pixelCount * 6) {
    return Uint16List.view(Uint8List.fromList(raw).buffer);
  }
  return null;
}

/// Whether [settings] ask for exactly the stretch every frame already
/// carries: STF with its default parameters. Channel linking is left out
/// because the native preview stretch has no unlinked form for mono frames
/// and links colour ones the same way.
bool isDefaultScreenStretch(AutoStretchSettings settings) {
  final defaults = AutoStretchSettings.defaults();
  return settings.method == AutoStretchMethod.stf &&
      settings.shadowClip == defaults.shadowClip &&
      settings.highlightClip == defaults.highlightClip &&
      settings.targetMedian == defaults.targetMedian;
}

/// Input to [linearDisplayRgba].
class LinearDisplayParams {
  const LinearDisplayParams(this.raw, this.width, this.height);

  final Uint16List raw;
  final int width;
  final int height;
}

/// The raw frame scaled linearly to 8 bits, the frame's darkest pixel black
/// and its brightest white, as RGBA. No curve: this is the frame as recorded,
/// which on a deep-sky frame is mostly dark with the brighter stars showing.
///
/// A mono frame has width * height samples; a colour one width * height * 3
/// interleaved RGB samples. Any other length is refused.
Uint8List linearDisplayRgba(LinearDisplayParams params) {
  final raw = params.raw;
  final pixels = params.width * params.height;
  final channels = raw.length == pixels * 3 ? 3 : 1;
  if (raw.length != pixels * channels) {
    throw ArgumentError(
      'Raw length ${raw.length} fits neither ${params.width}x${params.height} '
      'mono nor RGB',
    );
  }
  var lo = 65535;
  var hi = 0;
  for (final v in raw) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  final span = hi > lo ? hi - lo : 1;
  final out = Uint8List(pixels * 4);
  for (var i = 0; i < pixels; i++) {
    final o = i * 4;
    if (channels == 3) {
      final s = i * 3;
      out[o] = ((raw[s] - lo) * 255 ~/ span).clamp(0, 255);
      out[o + 1] = ((raw[s + 1] - lo) * 255 ~/ span).clamp(0, 255);
      out[o + 2] = ((raw[s + 2] - lo) * 255 ~/ span).clamp(0, 255);
    } else {
      final g = ((raw[i] - lo) * 255 ~/ span).clamp(0, 255);
      out[o] = g;
      out[o + 1] = g;
      out[o + 2] = g;
    }
    out[o + 3] = 255;
  }
  return out;
}

/// Provider for the connected camera device ID.
///
/// Separate from the equipment provider so raw image data has one source.
final connectedCameraIdProvider = Provider<String?>((ref) {
  final cameraState = ref.watch(cameraStateProvider);
  if (cameraState.connectionState == DeviceConnectionState.connected) {
    return cameraState.deviceId;
  }
  return null;
});

// Stretch implementation

/// Applies stretch to raw image data based on settings.
///
/// This is the main entry point for stretch operations. It delegates to
/// specific stretch methods and runs compute-intensive operations in isolates.
/// Always returns RGBA (4 bytes per pixel, alpha=255) to match the format
/// expected by Flutter's decodeImageFromPixels.
Future<Uint8List> _applyStretch({
  required Uint16List rawData,
  required int width,
  required int height,
  required bool isColor,
  required AutoStretchSettings settings,
}) async {
  final Uint8List stretched;
  switch (settings.method) {
    case AutoStretchMethod.stf:
      stretched = await _applyStfStretch(
        rawData: rawData,
        width: width,
        height: height,
        isColor: isColor,
        settings: settings,
      );
      // STF uses Rust bridge which now returns RGBA directly
      // Check if the result is already RGBA (4 bytes per pixel)
      if (stretched.length == width * height * 4) {
        return stretched;
      }
    case AutoStretchMethod.histogram:
      stretched = await _applyHistogramStretch(
        rawData: rawData,
        width: width,
        height: height,
        isColor: isColor,
        settings: settings,
      );
    case AutoStretchMethod.asinh:
      stretched = await _applyAsinhStretch(
        rawData: rawData,
        width: width,
        height: height,
        isColor: isColor,
        settings: settings,
      );
    case AutoStretchMethod.log:
      stretched = await _applyLogStretch(
        rawData: rawData,
        width: width,
        height: height,
        isColor: isColor,
        settings: settings,
      );
    case AutoStretchMethod.gamma:
      stretched = await _applyGammaStretch(
        rawData: rawData,
        width: width,
        height: height,
        isColor: isColor,
        settings: settings,
      );
  }

  // Convert grayscale or RGB stretch output to RGBA.
  // The Dart stretch isolates return grayscale (pixelCount bytes) or
  // RGB (pixelCount*3 bytes). Convert to RGBA for Flutter rendering.
  return _stretchedToRgba(stretched, width, height, isColor);
}

/// Convert grayscale or RGB stretched data to RGBA (4 bytes per pixel).
Uint8List _stretchedToRgba(Uint8List src, int width, int height, bool isColor) {
  final numPixels = width * height;
  // If already RGBA, return as-is
  if (src.length == numPixels * 4) {
    return src;
  }
  final rgba = Uint8List(numPixels * 4);
  if (isColor && src.length == numPixels * 3) {
    for (int i = 0; i < numPixels; i++) {
      final s = i * 3;
      final d = i * 4;
      rgba[d] = src[s];
      rgba[d + 1] = src[s + 1];
      rgba[d + 2] = src[s + 2];
      rgba[d + 3] = 255;
    }
  } else {
    for (int i = 0; i < numPixels; i++) {
      final gray = src[i];
      final d = i * 4;
      rgba[d] = gray;
      rgba[d + 1] = gray;
      rgba[d + 2] = gray;
      rgba[d + 3] = 255;
    }
  }
  return rgba;
}

// STF (screen transfer function) stretch

/// Applies PixInsight-style Screen Transfer Function stretch.
///
/// STF algorithm:
/// 1. Calculate median and MAD (median absolute deviation)
/// 2. Calculate shadows = median + shadowClip * MAD
/// 3. Calculate highlights = 1.0 (or median + highlightClip * MAD)
/// 4. Apply midtones transfer function (MTF)
///
/// This is compute-intensive, so it runs in an isolate.
Future<Uint8List> _applyStfStretch({
  required Uint16List rawData,
  required int width,
  required int height,
  required bool isColor,
  required AutoStretchSettings settings,
}) async {
  // Use the Rust implementation which is faster and matches the original STF
  try {
    // The Rust bridge's auto_stretch_image uses STF internally
    final result = bridge.apiAutoStretchImage(
      width: width,
      height: height,
      data: rawData.toList(),
    );
    return result;
  } catch (e) {
    // Fall back to Dart implementation
    developer.log(
      '[AutoStretch] Rust STF failed, using Dart fallback: $e',
      name: 'AutoStretch',
      level: 900,
      error: e,
    );
    return compute(
      _stfStretchIsolate,
      _StretchParams(rawData, width, height, isColor, settings),
    );
  }
}

/// Parameters for isolate computation
class _StretchParams {
  final Uint16List data;
  final int width;
  final int height;
  final bool isColor;
  final AutoStretchSettings settings;

  _StretchParams(
    this.data,
    this.width,
    this.height,
    this.isColor,
    this.settings,
  );
}

/// STF stretch implementation for isolate execution.
Uint8List _stfStretchIsolate(_StretchParams params) {
  final data = params.data;
  final width = params.width;
  final height = params.height;
  final isColor = params.isColor;
  final settings = params.settings;

  final pixelCount = width * height;

  if (isColor) {
    // RGB image: 3 channels
    if (data.length != pixelCount * 3) {
      throw ArgumentError(
        'Invalid RGB data length: expected ${pixelCount * 3}, got ${data.length}',
      );
    }

    if (settings.linkedChannels) {
      // Linked channels: calculate stats from luminance, apply to all channels
      final luminance = List<double>.filled(pixelCount, 0);
      for (var i = 0; i < pixelCount; i++) {
        final r = data[i * 3] / 65535.0;
        final g = data[i * 3 + 1] / 65535.0;
        final b = data[i * 3 + 2] / 65535.0;
        luminance[i] = 0.299 * r + 0.587 * g + 0.114 * b;
      }

      final params = _calculateStfParams(luminance, settings);
      final result = Uint8List(pixelCount * 3);

      for (var i = 0; i < pixelCount; i++) {
        result[i * 3] = _applyMtf(data[i * 3] / 65535.0, params);
        result[i * 3 + 1] = _applyMtf(data[i * 3 + 1] / 65535.0, params);
        result[i * 3 + 2] = _applyMtf(data[i * 3 + 2] / 65535.0, params);
      }

      return result;
    } else {
      // Unlinked channels: calculate stats for each channel independently
      final rChannel = List<double>.filled(pixelCount, 0);
      final gChannel = List<double>.filled(pixelCount, 0);
      final bChannel = List<double>.filled(pixelCount, 0);

      for (var i = 0; i < pixelCount; i++) {
        rChannel[i] = data[i * 3] / 65535.0;
        gChannel[i] = data[i * 3 + 1] / 65535.0;
        bChannel[i] = data[i * 3 + 2] / 65535.0;
      }

      final rParams = _calculateStfParams(rChannel, settings);
      final gParams = _calculateStfParams(gChannel, settings);
      final bParams = _calculateStfParams(bChannel, settings);

      final result = Uint8List(pixelCount * 3);

      for (var i = 0; i < pixelCount; i++) {
        result[i * 3] = _applyMtf(rChannel[i], rParams);
        result[i * 3 + 1] = _applyMtf(gChannel[i], gParams);
        result[i * 3 + 2] = _applyMtf(bChannel[i], bParams);
      }

      return result;
    }
  } else {
    // Grayscale image
    if (data.length != pixelCount) {
      throw ArgumentError(
        'Invalid grayscale data length: expected $pixelCount, got ${data.length}',
      );
    }

    final normalized = List<double>.filled(pixelCount, 0);
    for (var i = 0; i < pixelCount; i++) {
      normalized[i] = data[i] / 65535.0;
    }

    final params = _calculateStfParams(normalized, settings);
    final result = Uint8List(pixelCount);

    for (var i = 0; i < pixelCount; i++) {
      result[i] = _applyMtf(normalized[i], params);
    }

    return result;
  }
}

/// Calculated STF parameters
class _StfParams {
  final double shadows;
  final double highlights;
  final double midtones;

  _StfParams(this.shadows, this.highlights, this.midtones);
}

/// Calculate STF parameters from pixel data.
_StfParams _calculateStfParams(
  List<double> pixels,
  AutoStretchSettings settings,
) {
  if (pixels.isEmpty) {
    return _StfParams(0, 1, 0.5);
  }

  // Sort for median calculation
  final sorted = List<double>.from(pixels)..sort();
  final len = sorted.length;
  final median = sorted[len ~/ 2];

  // Calculate MAD (Median Absolute Deviation)
  final deviations = sorted.map((v) => (v - median).abs()).toList()..sort();
  final mad = deviations[len ~/ 2];

  // Calculate shadows and highlights using clipping parameters
  // shadowClip and highlightClip are in standard deviations from median
  var shadows = (median + settings.shadowClip * mad * 1.4826).clamp(0.0, 1.0);
  var highlights = (median - settings.highlightClip * mad * 1.4826).clamp(
    0.0,
    1.0,
  );

  // Ensure valid range
  if (highlights <= shadows) {
    shadows = 0.0;
    highlights = 1.0;
  }

  // Calculate midtone balance for target median
  final range = highlights - shadows;
  final medianPos = range > 0
      ? ((median - shadows) / range).clamp(0.0, 1.0)
      : 0.5;

  // MTF to achieve target median
  double midtones;
  if (medianPos > 0 && medianPos < 1) {
    midtones = _mtfInverse(medianPos, settings.targetMedian);
  } else {
    midtones = 0.5;
  }

  return _StfParams(shadows, highlights, midtones);
}

/// Midtone Transfer Function
double _mtf(double x, double m) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  if (x == m) return 0.5;
  return ((m - 1) * x) / ((2 * m - 1) * x - m);
}

/// Inverse MTF to find m given input x and target output
double _mtfInverse(double x, double target) {
  // Solve for m: target = ((m-1)*x) / ((2*m-1)*x - m)
  // This is a simplified approximation
  if (x <= 0 || x >= 1) return 0.5;
  if (target <= 0 || target >= 1) return x;

  // Iterative solution
  double low = 0.001;
  double high = 0.999;

  for (var i = 0; i < 20; i++) {
    final mid = (low + high) / 2;
    final result = _mtf(x, mid);
    if ((result - target).abs() < 0.001) break;
    if (result < target) {
      high = mid;
    } else {
      low = mid;
    }
  }

  return (low + high) / 2;
}

/// Apply MTF and convert to 8-bit
int _applyMtf(double value, _StfParams params) {
  final range = params.highlights - params.shadows;
  if (range <= 0) return 0;

  // Normalize to shadows/highlights range
  final normalized = ((value - params.shadows) / range).clamp(0.0, 1.0);

  // Apply MTF
  final stretched = _mtf(normalized, params.midtones);

  // Convert to 8-bit
  return (stretched * 255).round().clamp(0, 255);
}

// Histogram stretch

/// Applies histogram equalization stretch.
Future<Uint8List> _applyHistogramStretch({
  required Uint16List rawData,
  required int width,
  required int height,
  required bool isColor,
  required AutoStretchSettings settings,
}) async {
  return compute(
    _histogramStretchIsolate,
    _StretchParams(rawData, width, height, isColor, settings),
  );
}

Uint8List _histogramStretchIsolate(_StretchParams params) {
  final data = params.data;
  final width = params.width;
  final height = params.height;
  final isColor = params.isColor;
  final pixelCount = width * height;

  if (isColor) {
    // For RGB, stretch luminance and reconstruct
    final result = Uint8List(pixelCount * 3);

    // Build histogram from luminance
    final histogram = List<int>.filled(65536, 0);
    for (var i = 0; i < pixelCount; i++) {
      final r = data[i * 3];
      final g = data[i * 3 + 1];
      final b = data[i * 3 + 2];
      final lum = ((r * 299 + g * 587 + b * 114) / 1000).round();
      histogram[lum.clamp(0, 65535)]++;
    }

    // Calculate CDF
    final cdf = List<double>.filled(65536, 0);
    var sum = 0;
    for (var i = 0; i < 65536; i++) {
      sum += histogram[i];
      cdf[i] = sum / pixelCount;
    }

    // Apply equalization
    for (var i = 0; i < pixelCount; i++) {
      final r = data[i * 3];
      final g = data[i * 3 + 1];
      final b = data[i * 3 + 2];

      // Scale by equalized luminance
      final origLum = (r * 299 + g * 587 + b * 114) / 1000;
      if (origLum > 0) {
        final newLum = cdf[origLum.round().clamp(0, 65535)];
        final scale = newLum * 65535 / origLum;
        result[i * 3] = ((r * scale) / 256).round().clamp(0, 255);
        result[i * 3 + 1] = ((g * scale) / 256).round().clamp(0, 255);
        result[i * 3 + 2] = ((b * scale) / 256).round().clamp(0, 255);
      } else {
        result[i * 3] = 0;
        result[i * 3 + 1] = 0;
        result[i * 3 + 2] = 0;
      }
    }

    return result;
  } else {
    // Grayscale histogram equalization
    final histogram = List<int>.filled(65536, 0);
    for (var i = 0; i < pixelCount; i++) {
      histogram[data[i]]++;
    }

    // Calculate CDF
    final cdf = List<double>.filled(65536, 0);
    var sum = 0;
    for (var i = 0; i < 65536; i++) {
      sum += histogram[i];
      cdf[i] = sum / pixelCount;
    }

    // Apply equalization
    final result = Uint8List(pixelCount);
    for (var i = 0; i < pixelCount; i++) {
      result[i] = (cdf[data[i]] * 255).round().clamp(0, 255);
    }

    return result;
  }
}

// Asinh stretch

/// Applies arcsinh (inverse hyperbolic sine) stretch.
///
/// Asinh provides a smooth transition from linear to logarithmic behavior,
/// preserving star colors while stretching faint details.
Future<Uint8List> _applyAsinhStretch({
  required Uint16List rawData,
  required int width,
  required int height,
  required bool isColor,
  required AutoStretchSettings settings,
}) async {
  return compute(
    _asinhStretchIsolate,
    _StretchParams(rawData, width, height, isColor, settings),
  );
}

Uint8List _asinhStretchIsolate(_StretchParams params) {
  final data = params.data;
  final width = params.width;
  final height = params.height;
  final isColor = params.isColor;
  final settings = params.settings;
  final pixelCount = width * height;

  // Calculate scale factor based on data range
  double maxVal = 0;
  for (var i = 0; i < data.length; i++) {
    if (data[i] > maxVal) maxVal = data[i].toDouble();
  }
  if (maxVal == 0) maxVal = 65535;

  // Asinh stretch factor - higher values = more aggressive stretch
  // Derived from target median setting
  final beta = 10.0 / settings.targetMedian;

  if (isColor) {
    final result = Uint8List(pixelCount * 3);
    for (var i = 0; i < pixelCount; i++) {
      for (var c = 0; c < 3; c++) {
        final val = data[i * 3 + c] / maxVal;
        final stretched = _asinh(val * beta) / _asinh(beta);
        result[i * 3 + c] = (stretched * 255).round().clamp(0, 255);
      }
    }
    return result;
  } else {
    final result = Uint8List(pixelCount);
    for (var i = 0; i < pixelCount; i++) {
      final val = data[i] / maxVal;
      final stretched = _asinh(val * beta) / _asinh(beta);
      result[i] = (stretched * 255).round().clamp(0, 255);
    }
    return result;
  }
}

double _asinh(double x) => math.log(x + math.sqrt(x * x + 1));

// Log stretch

/// Applies logarithmic stretch.
///
/// Compresses high values while expanding low values, useful for
/// high dynamic range images with bright cores.
Future<Uint8List> _applyLogStretch({
  required Uint16List rawData,
  required int width,
  required int height,
  required bool isColor,
  required AutoStretchSettings settings,
}) async {
  return compute(
    _logStretchIsolate,
    _StretchParams(rawData, width, height, isColor, settings),
  );
}

Uint8List _logStretchIsolate(_StretchParams params) {
  final data = params.data;
  final width = params.width;
  final height = params.height;
  final isColor = params.isColor;
  final pixelCount = width * height;

  // Find max value for normalization
  double maxVal = 0;
  for (var i = 0; i < data.length; i++) {
    if (data[i] > maxVal) maxVal = data[i].toDouble();
  }
  if (maxVal == 0) maxVal = 65535;

  // Log stretch: output = log(1 + input) / log(1 + max)
  final logMaxPlusOne = math.log(maxVal + 1);

  if (isColor) {
    final result = Uint8List(pixelCount * 3);
    for (var i = 0; i < pixelCount; i++) {
      for (var c = 0; c < 3; c++) {
        final val = data[i * 3 + c].toDouble();
        final stretched = math.log(val + 1) / logMaxPlusOne;
        result[i * 3 + c] = (stretched * 255).round().clamp(0, 255);
      }
    }
    return result;
  } else {
    final result = Uint8List(pixelCount);
    for (var i = 0; i < pixelCount; i++) {
      final val = data[i].toDouble();
      final stretched = math.log(val + 1) / logMaxPlusOne;
      result[i] = (stretched * 255).round().clamp(0, 255);
    }
    return result;
  }
}

// Gamma stretch

/// Applies simple gamma correction.
///
/// Fast and predictable power-law transformation.
Future<Uint8List> _applyGammaStretch({
  required Uint16List rawData,
  required int width,
  required int height,
  required bool isColor,
  required AutoStretchSettings settings,
}) async {
  return compute(
    _gammaStretchIsolate,
    _StretchParams(rawData, width, height, isColor, settings),
  );
}

Uint8List _gammaStretchIsolate(_StretchParams params) {
  final data = params.data;
  final width = params.width;
  final height = params.height;
  final isColor = params.isColor;
  final settings = params.settings;
  final pixelCount = width * height;

  final gamma = settings.gammaValue;
  final invGamma = 1.0 / gamma;

  // Build lookup table for performance
  final lut = Uint8List(65536);
  for (var i = 0; i < 65536; i++) {
    final normalized = i / 65535.0;
    final corrected = math.pow(normalized, invGamma);
    lut[i] = (corrected * 255).round().clamp(0, 255);
  }

  if (isColor) {
    final result = Uint8List(pixelCount * 3);
    for (var i = 0; i < pixelCount; i++) {
      result[i * 3] = lut[data[i * 3]];
      result[i * 3 + 1] = lut[data[i * 3 + 1]];
      result[i * 3 + 2] = lut[data[i * 3 + 2]];
    }
    return result;
  } else {
    final result = Uint8List(pixelCount);
    for (var i = 0; i < pixelCount; i++) {
      result[i] = lut[data[i]];
    }
    return result;
  }
}
