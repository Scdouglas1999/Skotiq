import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Shader types used for star point-spread rendering.
enum StarPsfShaderType { glow, outerRing, midRing, core, balanced }

/// Cache for star PSF shaders keyed by type, radius, and color.
class StarPsfShaderCache {
  final int maxEntries;
  final Map<String, ui.Shader> _cache = {};

  StarPsfShaderCache({this.maxEntries = 1024});

  ui.Shader getShader({
    required StarPsfShaderType type,
    required double radius,
    required Color color,
  }) {
    final key =
        '${type.index}_${color.toARGB32()}_${radius.toStringAsFixed(4)}';
    final existing = _cache[key];
    if (existing != null) return existing;

    if (_cache.length >= maxEntries) {
      _cache.clear();
    }

    final shader = _createShader(type, radius, color);
    _cache[key] = shader;
    return shader;
  }

  /// Cache for diffraction spike linear gradient shaders.
  /// Key: magnitude bucket (rounded to 0.5) + spike direction angle.
  final Map<String, ui.Shader> _spikeCache = {};
  static const int _maxSpikeEntries = 256;

  /// Get or create a cached linear gradient shader for diffraction spikes.
  /// Spikes are keyed by magnitude bucket (0.5 increments), color, and angle
  /// so the same shader is reused for stars of similar brightness.
  ui.Shader getSpikeShader({
    required Offset center,
    required Offset end,
    required Color color,
    required double brightness,
    required double magnitude,
    required double angle,
  }) {
    // Quantize magnitude to 0.5 buckets and brightness to 0.1
    final magBucket = (magnitude * 2).round() / 2.0;
    final brightBucket = (brightness * 10).round() / 10.0;
    // Quantize angle to nearest 45 degrees (spikes are at fixed angles)
    final angleBucket = (angle / 45).round() * 45;
    final key =
        'spike_${magBucket}_${brightBucket}_${angleBucket}_${color.toARGB32()}';

    final existing = _spikeCache[key];
    if (existing != null) return existing;

    if (_spikeCache.length >= _maxSpikeEntries) {
      _spikeCache.clear();
    }

    final shader = ui.Gradient.linear(center, end, [
      color.withValues(alpha: brightness * 0.6),
      color.withValues(alpha: 0.0),
    ]);
    _spikeCache[key] = shader;
    return shader;
  }

  void clear() {
    _cache.clear();
    _spikeCache.clear();
  }

  int get size => _cache.length + _spikeCache.length;

  ui.Shader _createShader(StarPsfShaderType type, double radius, Color color) {
    final baseColor = color.withValues(alpha: 1.0);
    final rect = Rect.fromCircle(center: Offset.zero, radius: radius);

    switch (type) {
      case StarPsfShaderType.glow:
        return RadialGradient(
          colors: [
            baseColor.withValues(alpha: 0.4),
            baseColor.withValues(alpha: 0.15),
            baseColor.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(rect);
      case StarPsfShaderType.outerRing:
        return RadialGradient(
          colors: [
            Colors.transparent,
            baseColor.withValues(alpha: 0.1),
            baseColor.withValues(alpha: 0.05),
            Colors.transparent,
          ],
          stops: const [0.0, 0.6, 0.8, 1.0],
        ).createShader(rect);
      case StarPsfShaderType.midRing:
        return RadialGradient(
          colors: [
            baseColor.withValues(alpha: 0.8),
            baseColor.withValues(alpha: 0.4),
            baseColor.withValues(alpha: 0.1),
            Colors.transparent,
          ],
          stops: const [0.0, 0.3, 0.6, 1.0],
        ).createShader(rect);
      case StarPsfShaderType.core:
        return RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 1.0),
            baseColor.withValues(alpha: 1.0),
            baseColor.withValues(alpha: 0.5),
          ],
          stops: const [0.0, 0.4, 1.0],
        ).createShader(rect);
      case StarPsfShaderType.balanced:
        return RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.9),
            baseColor.withValues(alpha: 1.0),
            baseColor.withValues(alpha: 0.3),
            Colors.transparent,
          ],
          stops: const [0.0, 0.3, 0.7, 1.0],
        ).createShader(rect);
    }
  }
}
