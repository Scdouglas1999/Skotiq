part of '../stack_and_share_models.dart';

/// Layout options for the annotated share card.
enum ShareCardLayout {
  /// A translucent stat bar pinned to the bottom edge of the image.
  bottomBar,

  /// A compact stat card floated in a corner of the image.
  cornerCard,
}

/// Overlay glyph-size policy for a [ShareCardSpec].
///
/// The renderer normally derives the bitmap font from the rendered image
/// height (~4% of height) so an overlay scales sensibly from a thumbnail to a
/// 4K master. Some callers need a fixed size instead — notably the live
/// broadcast, which draws its watermark at the largest built-in font (arial48)
/// regardless of the 720px thumbnail it renders at, so the outreach overlay
/// does not shrink.
enum ShareCardFontScale {
  /// Pick the font from the rendered image height (the default, scales).
  scaleToHeight,

  /// Always use the small built-in bitmap font (arial14).
  small,

  /// Always use the medium built-in bitmap font (arial24).
  medium,

  /// Always use the large built-in bitmap font (arial48).
  large,
}

/// A single labelled statistic rendered on a share card.
class ShareStatLine {
  /// The stat label (e.g. `'Integration'`).
  final String label;

  /// The stat value (e.g. `'2h12m'`).
  final String value;

  const ShareStatLine({required this.label, required this.value});

  ShareStatLine copyWith({String? label, String? value}) {
    return ShareStatLine(
      label: label ?? this.label,
      value: value ?? this.value,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShareStatLine &&
          runtimeType == other.runtimeType &&
          label == other.label &&
          value == other.value;

  @override
  int get hashCode => Object.hash(label, value);
}

/// Specification for rendering an annotated share card over a stacked image.
class ShareCardSpec {
  /// Card title (typically the target name).
  final String title;

  /// Stat lines rendered on the card.
  final List<ShareStatLine> stats;

  /// Optional watermark text overlaid on the image.
  final String? watermark;

  /// Target render width in pixels.
  final int targetWidth;

  /// Target render height in pixels.
  final int targetHeight;

  /// Layout of the stat overlay.
  final ShareCardLayout layout;

  /// Glyph-size policy for the watermark + stat overlay. Defaults to
  /// [ShareCardFontScale.scaleToHeight] so an overlay scales with the rendered
  /// image; callers that need a fixed glyph size (e.g. the broadcast's arial48
  /// watermark) override it.
  final ShareCardFontScale fontScale;

  const ShareCardSpec({
    required this.title,
    this.stats = const [],
    this.watermark,
    this.targetWidth = 1080,
    this.targetHeight = 1080,
    this.layout = ShareCardLayout.bottomBar,
    this.fontScale = ShareCardFontScale.scaleToHeight,
  });

  ShareCardSpec copyWith({
    String? title,
    List<ShareStatLine>? stats,
    String? watermark,
    int? targetWidth,
    int? targetHeight,
    ShareCardLayout? layout,
    ShareCardFontScale? fontScale,
  }) {
    return ShareCardSpec(
      title: title ?? this.title,
      stats: stats ?? this.stats,
      watermark: watermark ?? this.watermark,
      targetWidth: targetWidth ?? this.targetWidth,
      targetHeight: targetHeight ?? this.targetHeight,
      layout: layout ?? this.layout,
      fontScale: fontScale ?? this.fontScale,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShareCardSpec &&
          runtimeType == other.runtimeType &&
          title == other.title &&
          _listEquals(stats, other.stats) &&
          watermark == other.watermark &&
          targetWidth == other.targetWidth &&
          targetHeight == other.targetHeight &&
          layout == other.layout &&
          fontScale == other.fontScale;

  @override
  int get hashCode => Object.hash(
    title,
    Object.hashAll(stats),
    watermark,
    targetWidth,
    targetHeight,
    layout,
    fontScale,
  );
}

/// Output format for a Stack-and-Share export.
enum ShareExportFormat {
  /// Lossless PNG of the stacked image.
  png,

  /// Compressed JPEG of the stacked image.
  jpeg,

  /// Annotated share card (image + stat overlay).
  shareCard,
}
