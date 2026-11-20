import 'package:flutter/material.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Format an integration duration in seconds into a concise Observatory readout.
String formatLiveIntegration(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return '—';
  final rounded = seconds.round();
  if (rounded < 60) return '${rounded}s';
  final hours = rounded ~/ 3600;
  final mins = (rounded % 3600) ~/ 60;
  final secs = rounded % 60;
  if (hours > 0) {
    return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
  }
  return secs > 0 ? '${mins}m ${secs.toString().padLeft(2, '0')}s' : '${mins}m';
}

/// Format a pixel count into compact readable units (e.g. `12.4K px`, `1.2M px`).
String formatPixelCount(int count) {
  if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M px';
  if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K px';
  return '$count px';
}

/// Display label for a live stack filter key.
String liveStackFilterDisplayName(String filterKey) {
  if (filterKey == kDefaultLiveStackFilterKey || filterKey.trim().isEmpty) {
    return 'All';
  }
  return filterKey;
}

/// Chart-palette dot colour for an optical filter (Observatory rule: filters
/// may use the chart palette in charts, dots, and thumbnails, never on chrome).
Color liveStackFilterDotColor(String filterKey, SkotiqColors colors) {
  final lower = filterKey.trim().toLowerCase();
  if (lower == 'l' || lower == 'lum' || lower == 'luminance') {
    return colors.textPrimary;
  }
  if (lower == 'r' || lower == 'red') {
    return const Color(0xFFE06C75);
  }
  if (lower == 'g' || lower == 'green') {
    return const Color(0xFF7EC699);
  }
  if (lower == 'b' || lower == 'blue') {
    return const Color(0xFF61AFEF);
  }
  if (lower == 'ha' || lower == 'h-alpha' || lower == 'halpha') {
    return const Color(0xFFD9534F);
  }
  if (lower == 'oiii' || lower == 'o3' || lower == 'o-iii') {
    return const Color(0xFF4FD1C5);
  }
  if (lower == 'sii' || lower == 's2' || lower == 's-ii') {
    return const Color(0xFFF0AD4E);
  }
  return colors.primary;
}
