import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// User preferences for the inline frame thumbnail
/// strip rendered under each ExposureNode in the sequence tree.
///
/// Two knobs:
///   * `enabled` — whether the strip is rendered at all. Defaults to ON.
///     The setting exists so users on slow disks / massive sessions can
///     turn rendering off without disabling image grading.
///   * `size` — `small` (32px tall) or `medium` (48px tall). Small is
///     denser for crowded trees; medium is richer for inspection.
///
/// Backed by `settings_dao` under a single JSON key so adding more knobs
/// (e.g. "max thumbnails per node") doesn't fan out into separate
/// settings rows.
enum ThumbnailSize { small, medium }

class ThumbnailStripPrefs {
  final bool enabled;
  final ThumbnailSize size;

  const ThumbnailStripPrefs({
    required this.enabled,
    required this.size,
  });

  /// Spec-defined defaults: ON, medium (40px tall ≈ design system "tiny+").
  /// Medium gives more visual information than small without crowding the
  /// tree; small is opt-in for dense trees.
  static const defaults = ThumbnailStripPrefs(
    enabled: true,
    size: ThumbnailSize.medium,
  );

  /// Resolved square pixel dimension for each thumbnail (height = width).
  double get pixelSize {
    switch (size) {
      case ThumbnailSize.small:
        return 32.0;
      case ThumbnailSize.medium:
        return 48.0;
    }
  }

  /// Width of the textual badge area (filter chip + HFR) shown alongside
  /// the image; tracks `pixelSize` so the row stays compact when small.
  double get badgeRowHeight {
    switch (size) {
      case ThumbnailSize.small:
        return 14.0;
      case ThumbnailSize.medium:
        return 18.0;
    }
  }

  ThumbnailStripPrefs copyWith({
    bool? enabled,
    ThumbnailSize? size,
  }) =>
      ThumbnailStripPrefs(
        enabled: enabled ?? this.enabled,
        size: size ?? this.size,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'size': size.name,
      };

  factory ThumbnailStripPrefs.fromJson(Map<String, dynamic> json) {
    final enabledRaw = json['enabled'];
    final sizeRaw = json['size'];
    final enabled = enabledRaw is bool ? enabledRaw : defaults.enabled;
    final size = ThumbnailSize.values.firstWhere(
      (s) => s.name == sizeRaw,
      orElse: () => defaults.size,
    );
    return ThumbnailStripPrefs(enabled: enabled, size: size);
  }
}

const _thumbnailStripPrefsKey = 'thumbnail_strip_prefs_v1';

/// Persisted thumbnail-strip preferences. Backed by the
/// `settingsDaoProvider` persistence pattern. Errors
/// during read/write surface through the AsyncValue rather than being
/// swallowed — silent fallbacks hide bugs.
final thumbnailStripPrefsProvider =
    AsyncNotifierProvider<ThumbnailStripPrefsNotifier, ThumbnailStripPrefs>(() {
  return ThumbnailStripPrefsNotifier();
});

class ThumbnailStripPrefsNotifier extends AsyncNotifier<ThumbnailStripPrefs> {
  @override
  Future<ThumbnailStripPrefs> build() async {
    final dao = ref.read(settingsDaoProvider);
    final stored = await dao.getSetting(_thumbnailStripPrefsKey);
    if (stored == null || stored.trim().isEmpty) {
      return ThumbnailStripPrefs.defaults;
    }
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Thumbnail strip prefs JSON is not an object: $stored',
      );
    }
    return ThumbnailStripPrefs.fromJson(decoded);
  }

  Future<void> setEnabled(bool enabled) async {
    final current = state.value ?? ThumbnailStripPrefs.defaults;
    final updated = current.copyWith(enabled: enabled);
    await _persist(updated);
  }

  Future<void> setSize(ThumbnailSize size) async {
    final current = state.value ?? ThumbnailStripPrefs.defaults;
    final updated = current.copyWith(size: size);
    await _persist(updated);
  }

  Future<void> _persist(ThumbnailStripPrefs prefs) async {
    final dao = ref.read(settingsDaoProvider);
    await dao.setSetting(
      _thumbnailStripPrefsKey,
      jsonEncode(prefs.toJson()),
    );
    state = AsyncData(prefs);
  }
}
