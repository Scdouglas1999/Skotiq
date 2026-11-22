import 'package:flutter/material.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A live stack's total integration ([DurationStyle.short]); an em dash
/// when nothing is stacked.
String formatLiveIntegration(double seconds) =>
    seconds.isFinite && seconds > 0
    ? DurationFormat.seconds(seconds, style: DurationStyle.short)
    : '—';

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
/// Delegates to [FilterColors.forName] so Red Night and light themes stay safe.
Color liveStackFilterDotColor(String filterKey, SkotiqColors colors) {
  if (FilterColors.knownColor(filterKey) == null) {
    return colors.primary;
  }
  return FilterColors.forName(filterKey, colors: colors);
}
