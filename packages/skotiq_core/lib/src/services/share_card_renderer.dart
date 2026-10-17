// Stack-and-Share Loop — share-card renderer.
//
// The canonical, UI-free image-composition logic for the Stack-and-Share
// feature. It owns three concerns:
//
//   1. **Percentile auto-stretch** of raw 16-bit luminance frames
//      (0.5%/99.5% black/white points) — the difference between a frame
//      that "looks like M42" and "looks like a black square."
//   2. **Watermark text** drawn bottom-left with a drop shadow, matching the
//      Astrobin / Cuiv outreach convention.
//   3. **Stat overlay** — a translucent rounded panel of [ShareStatLine]s
//      (title + labelled values) drawn per [ShareCardLayout].
//
// Two input paths are supported:
//
//   * [renderJpegFromMono] — for the live-stacking engine, which emits a
//     single-channel u16 luminance buffer that still needs stretching.
//   * [renderPngFromRgba] / [renderJpegFromRgba] — for the export service,
//     which already produced a stretched 8-bit RGBA result and only needs
//     the overlay + watermark composited on top.
//
// Pure Dart (the `image` package only) so the desktop, mobile, and headless
// builds all share one path, and so it is unit-testable without a Flutter
// binding. A short buffer throws rather than rendering garbage.

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/imaging/stack_and_share_models.dart'
    show ShareCardFontScale, ShareCardLayout, ShareCardSpec, ShareStatLine;

/// Renders share-ready images (watermark + stretch + stat overlay) from either
/// raw mono u16 frames or already-stretched RGBA buffers.
///
/// Stateless and cheap to construct; a single instance can be reused for every
/// frame. [LiveStackingBroadcastService] holds one and delegates to it so the
/// broadcast and the Stack-and-Share export produce byte-identical overlays.
class ShareCardRenderer {
  const ShareCardRenderer();

  // Public API — mono u16 source (needs stretching)

  /// Render a single-channel u16 luminance buffer to a watermarked,
  /// stat-overlaid JPEG.
  ///
  /// The buffer is percentile-stretched (see [computeStretchEnds]), optionally
  /// downscaled to [ShareCardSpec.targetWidth]/[ShareCardSpec.targetHeight]
  /// preserving aspect ratio, then composited with the overlay defined by
  /// [spec].
  ///
  /// Throws [StateError] when [data] is shorter than `width * height` — a short
  /// buffer would corrupt the encode, and silently serving garbage would hide
  /// the bug.
  Uint8List renderJpegFromMono({
    required int width,
    required int height,
    required Uint16List data,
    required ShareCardSpec spec,
    int quality = 90,
  }) {
    final bitmap = _stretchMonoToRgb(
      width: width,
      height: height,
      data: data,
      targetWidth: spec.targetWidth,
      targetHeight: spec.targetHeight,
    );
    _composite(bitmap, spec);
    return Uint8List.fromList(img.encodeJpg(bitmap, quality: quality));
  }

  // Public API — already-stretched RGBA source

  /// Render an already-stretched 8-bit RGBA buffer to a watermarked,
  /// stat-overlaid PNG (lossless — the preferred archival/share format for the
  /// stacked master).
  ///
  /// The [rgba] buffer is interpreted as tightly-packed `R,G,B,A` bytes,
  /// `width * height * 4` long. Throws [StateError] on a short buffer.
  Uint8List renderPngFromRgba({
    required int width,
    required int height,
    required Uint8List rgba,
    required ShareCardSpec spec,
  }) {
    final bitmap = _rgbaToImage(width: width, height: height, rgba: rgba);
    _composite(bitmap, spec);
    return Uint8List.fromList(img.encodePng(bitmap));
  }

  /// Render an already-stretched 8-bit RGBA buffer to a watermarked,
  /// stat-overlaid JPEG. Same input contract as [renderPngFromRgba]; emits a
  /// compressed JPEG for size-constrained shares (social posts, LAN preview).
  Uint8List renderJpegFromRgba({
    required int width,
    required int height,
    required Uint8List rgba,
    required ShareCardSpec spec,
    int quality = 90,
  }) {
    final bitmap = _rgbaToImage(width: width, height: height, rgba: rgba);
    _composite(bitmap, spec);
    return Uint8List.fromList(img.encodeJpg(bitmap, quality: quality));
  }

  // Stretch + decode helpers

  /// Percentile-stretch a u16 luminance buffer into a 3-channel RGB
  /// [img.Image], optionally aspect-fit downscaled to the target box.
  img.Image _stretchMonoToRgb({
    required int width,
    required int height,
    required Uint16List data,
    required int targetWidth,
    required int targetHeight,
  }) {
    final expected = width * height;
    if (width <= 0 || height <= 0) {
      throw StateError(
        'Share-card mono source has non-positive dimensions '
        '(width=$width height=$height)',
      );
    }
    if (data.length < expected) {
      throw StateError(
        'Share-card mono buffer too small: ${data.length} < $expected '
        '(width=$width height=$height)',
      );
    }

    // Per-frame percentile stretch: black at the 0.5% percentile, white at the
    // 99.5%. Matches the desktop preview's default auto-stretch and looks
    // correct for the typical long-exposure DSO this is built for.
    final (blackPoint, whitePoint) = computeStretchEnds(data);
    final range = (whitePoint - blackPoint).clamp(1, 65535).toInt();

    final bytes = Uint8List(expected);
    for (var i = 0; i < expected; i++) {
      final value = data[i] - blackPoint;
      final scaled = (value * 255 ~/ range).clamp(0, 255);
      bytes[i] = scaled;
    }

    var bitmap = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      numChannels: 1,
      order: img.ChannelOrder.red,
      format: img.Format.uint8,
    );

    bitmap = _aspectFitResize(
      bitmap,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );

    // Promote to RGB so the overlay can render in colour. The pixel data is
    // luminance, so RGB == grey == identical channels.
    return bitmap.convert(numChannels: 3);
  }

  /// Build a 3-channel RGB [img.Image] from a tightly-packed RGBA buffer.
  ///
  /// The export pipeline produces RGBA; we drop alpha to RGB here because the
  /// stacked master is fully opaque and the overlay composites onto opaque
  /// pixels. Throws [StateError] on a short or mis-dimensioned buffer.
  img.Image _rgbaToImage({
    required int width,
    required int height,
    required Uint8List rgba,
  }) {
    if (width <= 0 || height <= 0) {
      throw StateError(
        'Share-card RGBA source has non-positive dimensions '
        '(width=$width height=$height)',
      );
    }
    final expected = width * height * 4;
    if (rgba.length < expected) {
      throw StateError(
        'Share-card RGBA buffer too small: ${rgba.length} < $expected '
        '(width=$width height=$height)',
      );
    }
    final bitmap = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
      format: img.Format.uint8,
    );
    // Composite onto opaque RGB so JPEG/PNG carry no surprise alpha and the
    // translucent overlay blends against the image, not transparency.
    return bitmap.convert(numChannels: 3);
  }

  /// Aspect-fit downscale [bitmap] so it fits inside the target box, preserving
  /// the source aspect ratio. A target dimension of `<= 0`, or a source that
  /// already matches the target, returns the bitmap unchanged.
  img.Image _aspectFitResize(
    img.Image bitmap, {
    required int targetWidth,
    required int targetHeight,
  }) {
    final width = bitmap.width;
    final height = bitmap.height;
    if (targetWidth <= 0 || targetHeight <= 0) return bitmap;
    if (width == targetWidth && height == targetHeight) return bitmap;

    final srcRatio = width / height;
    final tgtRatio = targetWidth / targetHeight;
    int outW;
    int outH;
    if (srcRatio > tgtRatio) {
      outW = targetWidth;
      outH = (targetWidth / srcRatio).round().clamp(1, targetHeight);
    } else {
      outH = targetHeight;
      outW = (targetHeight * srcRatio).round().clamp(1, targetWidth);
    }
    if (outW == width && outH == height) return bitmap;
    return img.copyResize(bitmap, width: outW, height: outH);
  }

  // Overlay compositing (watermark + stat panel)

  /// Draw the stat panel then the watermark onto [bitmap], in place. The
  /// watermark is drawn last so it always sits on top of the panel when the
  /// two would overlap.
  ///
  /// The font is resolved once from [spec] (so the panel and watermark share a
  /// glyph size) honouring [ShareCardSpec.fontScale].
  void _composite(img.Image bitmap, ShareCardSpec spec) {
    final font = fontForSpec(spec, bitmap.height);
    _drawStatPanel(bitmap, spec, font);

    final watermark = spec.watermark?.trim();
    if (watermark != null && watermark.isNotEmpty) {
      drawWatermark(bitmap, watermark, font: font);
    }
  }

  /// Resolve the bitmap font for [spec] at the given rendered [imageHeight],
  /// honouring [ShareCardSpec.fontScale]: a fixed scale pins a specific
  /// built-in font; [ShareCardFontScale.scaleToHeight] defers to
  /// [fontForHeight].
  ///
  /// Exposed (not private) so tests can assert which font a given spec/height
  /// resolves to — that the 720px broadcast frame keeps the arial48 watermark
  /// rather than dropping to arial24.
  img.BitmapFont fontForSpec(ShareCardSpec spec, int imageHeight) {
    return switch (spec.fontScale) {
      ShareCardFontScale.small => img.arial14,
      ShareCardFontScale.medium => img.arial24,
      ShareCardFontScale.large => img.arial48,
      ShareCardFontScale.scaleToHeight => fontForHeight(imageHeight),
    };
  }

  /// Pick a built-in bitmap font whose line height is roughly 4% of the image
  /// height, so the overlay scales sensibly from a 256px thumbnail to a 4K
  /// master without needing a TTF rasteriser.
  ///
  /// Exposed (not private) so tests can pin the height→font thresholds.
  img.BitmapFont fontForHeight(int imageHeight) {
    final target = imageHeight * 0.04;
    if (target >= 40) return img.arial48;
    if (target >= 20) return img.arial24;
    return img.arial14;
  }

  /// Panel padding / gap / corner radius derived from [font]'s line height, so
  /// the geometry scales with whichever font the caption ends up rendered in.
  ///
  /// Exposed so tests can reproduce the exact bar geometry.
  ({int lineHeight, int pad, int gap, int radius}) panelGeometry(
    img.BitmapFont font,
  ) {
    final lineHeight = font.lineHeight;
    return (
      lineHeight: lineHeight,
      pad: (lineHeight * 0.5).round().clamp(4, 48),
      gap: (lineHeight * 0.4).round().clamp(2, 32),
      radius: (lineHeight * 0.35).round().clamp(2, 24),
    );
  }

  /// The built-in bitmap fonts in descending size — the ladder a caption steps
  /// down when it will not fit the card width.
  static List<img.BitmapFont> get _fontLadder => [
    img.arial48,
    img.arial24,
    img.arial14,
  ];

  /// Rows a caption may occupy before it stops being a caption.
  static const int _maxCaptionRows = 3;

  /// Choose the largest font at or below [preferred] whose greedy wrap of
  /// [segments] fits [cardWidth] in at most [_maxCaptionRows] rows with no
  /// single segment overflowing, and return that font with the wrapped rows.
  ///
  /// When nothing on the ladder fits, the smallest font is used and any segment
  /// still wider than the card is ellipsized to fit. A long target name is the
  /// one segment that can do this (the stat segments are short and bounded), and
  /// letting [img.drawString] run it off the right edge is exactly the defect
  /// this method exists to fix — a caption ending in "..." is honest about being
  /// shortened, one sliced mid-glyph by the card edge is not.
  ///
  /// Exposed so a test can assert the fit without rendering.
  ({img.BitmapFont font, List<List<String>> rows}) fitCaption(
    img.BitmapFont preferred,
    List<String> segments,
    int cardWidth,
  ) {
    var reached = false;
    for (final candidate in _fontLadder) {
      // Skip anything larger than the caller's height-derived choice.
      if (!reached) {
        if (candidate.lineHeight > preferred.lineHeight) continue;
        reached = true;
      }
      final available = cardWidth - panelGeometry(candidate).pad * 2;
      final gap = panelGeometry(candidate).gap * 3;
      final rows = _wrapSegments(candidate, segments, gap, available);
      final everyFits = segments.every(
        (s) => _measureText(candidate, s) <= available,
      );
      if (everyFits && rows.length <= _maxCaptionRows) {
        return (font: candidate, rows: rows);
      }
    }
    final smallest = _fontLadder.last;
    final geometry = panelGeometry(smallest);
    final available = cardWidth - geometry.pad * 2;
    final clamped = [
      for (final segment in segments) _ellipsize(smallest, segment, available),
    ];
    return (
      font: smallest,
      rows: _wrapSegments(smallest, clamped, geometry.gap * 3, available),
    );
  }

  /// Shorten [text] with a trailing ellipsis until it measures within
  /// [available] in [font]; returns [text] unchanged when it already fits.
  ///
  /// ASCII dots rather than U+2026: the built-in bitmap fonts carry no ellipsis
  /// glyph, and [_measureText] / [img.drawString] silently drop a character the
  /// font has no entry for — the shortened caption would then carry no mark that
  /// anything had been removed.
  String _ellipsize(img.BitmapFont font, String text, int available) {
    if (_measureText(font, text) <= available) return text;
    const marker = '...';
    final markerWidth = _measureText(font, marker);
    if (markerWidth > available) return '';
    // Walk whole runes, not code units: cutting a surrogate pair in half would
    // leave an unpaired half in the caption.
    final runes = text.runes.toList();
    for (var end = runes.length; end > 0; end--) {
      final candidate = String.fromCharCodes(runes.take(end)).trimRight();
      if (_measureText(font, candidate) + markerWidth <= available) {
        return '$candidate$marker';
      }
    }
    return marker;
  }

  /// Greedy wrap of whole [segments] into rows no wider than [available].
  /// Segments are never split: each is one "LABEL value" unit and breaking it
  /// is what produced the truncated caption in the first place.
  List<List<String>> _wrapSegments(
    img.BitmapFont font,
    List<String> segments,
    int gap,
    int available,
  ) {
    final rows = <List<String>>[];
    var current = <String>[];
    var width = 0;
    for (final segment in segments) {
      final segmentWidth = _measureText(font, segment);
      final needed = current.isEmpty
          ? segmentWidth
          : width + gap + segmentWidth;
      if (current.isNotEmpty && needed > available) {
        rows.add(current);
        current = <String>[segment];
        width = segmentWidth;
      } else {
        current.add(segment);
        width = needed;
      }
    }
    if (current.isNotEmpty) rows.add(current);
    return rows;
  }

  /// Measure the rendered pixel width of [text] in [font], summing per-glyph
  /// advances (matching how [img.drawString] lays glyphs out). Used to size the
  /// stat panel to its contents.
  int _measureText(img.BitmapFont font, String text) {
    var width = 0;
    for (final c in text.codeUnits) {
      final ch = font.characters[c];
      if (ch == null) continue;
      width += ch.xAdvance;
    }
    return width;
  }

  /// Draw the [ShareCardSpec.title] + [ShareCardSpec.stats] as a translucent
  /// rounded dark panel, positioned per [ShareCardSpec.layout]:
  ///
  ///   * [ShareCardLayout.bottomBar] — a full-width bar pinned to the bottom
  ///     edge, title on the left, stats laid out left-to-right after it.
  ///   * [ShareCardLayout.cornerCard] — a compact card floated in the
  ///     top-right corner, title on its own line above one stat per line.
  ///
  /// No-op when there is neither a title nor any stats (e.g. a watermark-only
  /// share), so a bare image isn't gratuitously darkened.
  void _drawStatPanel(
    img.Image bitmap,
    ShareCardSpec spec,
    img.BitmapFont font,
  ) {
    final title = spec.title.trim();
    final stats = spec.stats;
    if (title.isEmpty && stats.isEmpty) return;

    final geometry = panelGeometry(font);
    final lineHeight = geometry.lineHeight;
    final pad = geometry.pad;
    final gap = geometry.gap;
    final radius = geometry.radius;

    // Panel fill + stroke: a low-alpha dark fill keeps the underlying image
    // readable; a faint light stroke separates it from a bright nebula edge.
    final fill = img.ColorUint8.rgba(0, 0, 0, 140);
    final stroke = img.ColorUint8.rgba(255, 255, 255, 40);

    switch (spec.layout) {
      case ShareCardLayout.bottomBar:
        _drawBottomBar(
          bitmap,
          font: font,
          fill: fill,
          stroke: stroke,
          title: title,
          stats: stats,
        );
      case ShareCardLayout.cornerCard:
        _drawCornerCard(
          bitmap,
          font: font,
          lineHeight: lineHeight,
          pad: pad,
          gap: gap,
          radius: radius,
          fill: fill,
          stroke: stroke,
          title: title,
          stats: stats,
        );
    }
  }

  void _drawBottomBar(
    img.Image bitmap, {
    required img.BitmapFont font,
    required img.Color fill,
    required img.Color stroke,
    required String title,
    required List<ShareStatLine> stats,
  }) {
    // Title, then each stat as a self-contained "LABEL value" segment.
    final segments = <String>[
      if (title.isNotEmpty) title,
      for (final s in stats)
        if ('${s.label.trim()}  ${s.value.trim()}'.trim().isNotEmpty)
          '${s.label.trim()}  ${s.value.trim()}'.trim(),
    ];
    if (segments.isEmpty) return;

    // Fit the caption to the card WIDTH, not only to its height. The font is
    // derived from the image HEIGHT alone, and nothing ever measured the
    // composed caption against the available width — so on a 512px card
    // "M51 · Integration 00:35:00 · Frames 7 · Filter L" needed 565px, ran off
    // the right edge, and drawString silently clipped the last stat mid-word.
    // This is the artefact the feature exists to produce; it must not ship
    // truncated.
    final fitted = fitCaption(font, segments, bitmap.width);
    final barFont = fitted.font;
    final rows = fitted.rows;
    final geometry = panelGeometry(barFont);
    final lineHeight = geometry.lineHeight;
    final pad = geometry.pad;
    final gap = geometry.gap;
    final radius = geometry.radius;

    final barHeight =
        rows.length * lineHeight + (rows.length - 1) * gap + pad * 2;
    final y0 = bitmap.height - barHeight;
    final y1 = bitmap.height - 1;

    img.fillRect(
      bitmap,
      x1: 0,
      y1: y0,
      x2: bitmap.width - 1,
      y2: y1,
      color: fill,
      radius: radius,
    );
    img.drawRect(
      bitmap,
      x1: 0,
      y1: y0,
      x2: bitmap.width - 1,
      y2: y1,
      color: stroke,
      radius: radius,
    );

    // The title renders brighter than the stat segments for hierarchy; it is
    // segment 0 whenever a title is present.
    final statColor = img.ColorUint8.rgb(210, 220, 235);
    final titleColor = img.ColorUint8.rgb(255, 255, 255);
    final shadow = img.ColorUint8.rgba(0, 0, 0, 200);
    var index = 0;
    var textY = y0 + pad;
    for (final row in rows) {
      var x = pad;
      for (final segment in row) {
        img.drawString(
          bitmap,
          segment,
          font: barFont,
          x: x + 1,
          y: textY + 1,
          color: shadow,
        );
        img.drawString(
          bitmap,
          segment,
          font: barFont,
          x: x,
          y: textY,
          color: (index == 0 && title.isNotEmpty) ? titleColor : statColor,
        );
        x += _measureText(barFont, segment) + gap * 3;
        index++;
      }
      textY += lineHeight + gap;
    }
  }

  void _drawCornerCard(
    img.Image bitmap, {
    required img.BitmapFont font,
    required int lineHeight,
    required int pad,
    required int gap,
    required int radius,
    required img.Color fill,
    required img.Color stroke,
    required String title,
    required List<ShareStatLine> stats,
  }) {
    // Lay out the title on its own line, then one "label  value" per stat line.
    final lines = <String>[
      if (title.isNotEmpty) title,
      for (final s in stats) '${s.label.trim()}  ${s.value.trim()}'.trim(),
    ].where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return;

    // Card sized to its widest line + its line count.
    var contentWidth = 0;
    for (final line in lines) {
      final w = _measureText(font, line);
      if (w > contentWidth) contentWidth = w;
    }
    final cardWidth = (contentWidth + pad * 2).clamp(1, bitmap.width).toInt();
    final cardHeight =
        (lines.length * lineHeight + (lines.length - 1) * gap + pad * 2)
            .clamp(1, bitmap.height)
            .toInt();

    // Top-right corner with a small inset margin.
    final margin = pad;
    final x1 = (bitmap.width - margin - cardWidth).clamp(0, bitmap.width - 1);
    final y0 = margin.clamp(0, bitmap.height - 1);
    final x2 = (x1 + cardWidth).clamp(0, bitmap.width - 1);
    final y1 = (y0 + cardHeight).clamp(0, bitmap.height - 1);

    img.fillRect(
      bitmap,
      x1: x1,
      y1: y0,
      x2: x2,
      y2: y1,
      color: fill,
      radius: radius,
    );
    img.drawRect(
      bitmap,
      x1: x1,
      y1: y0,
      x2: x2,
      y2: y1,
      color: stroke,
      radius: radius,
    );

    final titleColor = img.ColorUint8.rgb(255, 255, 255);
    final statColor = img.ColorUint8.rgb(210, 220, 235);
    var ly = y0 + pad;
    final textX = x1 + pad;
    for (var i = 0; i < lines.length; i++) {
      final isTitle = title.isNotEmpty && i == 0;
      img.drawString(
        bitmap,
        lines[i],
        font: font,
        x: textX + 1,
        y: ly + 1,
        color: img.ColorUint8.rgba(0, 0, 0, 200),
      );
      img.drawString(
        bitmap,
        lines[i],
        font: font,
        x: textX,
        y: ly,
        color: isTitle ? titleColor : statColor,
      );
      ly += lineHeight + gap;
    }
  }

  // Watermark (bottom-left, drop shadow)

  /// Draw the watermark [text] onto [bitmap] in place, bottom-left, with a
  /// subtle dark drop shadow under a white fill — the convention Astrobin /
  /// Cuiv overlays use for outreach. No-op for empty text.
  ///
  /// [font] selects the glyph size; when omitted it scales with the image
  /// height via [fontForHeight].
  void drawWatermark(img.Image bitmap, String text, {img.BitmapFont? font}) {
    if (text.isEmpty) return;
    font ??= fontForHeight(bitmap.height);
    // Padding from the bottom-left corner; scales with image height so small
    // downscales still look right.
    final pad = (bitmap.height * 0.025).clamp(8, 64).toInt();
    final x = pad;
    final y = bitmap.height - pad - font.lineHeight;
    // Drop shadow for legibility on bright nebula edges.
    img.drawString(
      bitmap,
      text,
      font: font,
      x: x + 2,
      y: y + 2,
      color: img.ColorUint8.rgb(0, 0, 0),
    );
    img.drawString(
      bitmap,
      text,
      font: font,
      x: x,
      y: y,
      color: img.ColorUint8.rgb(255, 255, 255),
    );
  }

  // Percentile stretch

  /// Compute the 0.5%/99.5% percentile black/white points for the stretch.
  ///
  /// Builds a sparse histogram (a full 65536-bin array would be wasteful for
  /// small previews) and walks the unique values sorted. Falls back to the full
  /// `(0, 65535)` range when the histogram is empty or degenerate (a single
  /// tone), which would otherwise hand the encoder a divide-by-zero range.
  (int, int) computeStretchEnds(Uint16List data) {
    final counts = <int, int>{};
    for (final v in data) {
      counts[v] = (counts[v] ?? 0) + 1;
    }
    final keys = counts.keys.toList()..sort();
    if (keys.isEmpty) return (0, 65535);
    final total = data.length;
    final lowTarget = (total * 0.005).floor();
    final highTarget = (total * 0.995).ceil();
    var acc = 0;
    int? black;
    int? white;
    for (final k in keys) {
      acc += counts[k]!;
      if (black == null && acc >= lowTarget) {
        black = k;
      }
      if (white == null && acc >= highTarget) {
        white = k;
      }
      if (black != null && white != null) break;
    }
    black ??= keys.first;
    white ??= keys.last;
    if (white <= black) {
      return (0, 65535);
    }
    return (black, white);
  }
}

/// Expand the small watermark template language shared by the broadcast
/// watermark and the Stack-and-Share share card.
///
/// Supports `${token}` substitutions from [tokens]; a `${` with no closing `}`
/// is left literal. Unknown tokens fall through as literal `${token}` text so a
/// user sees their typo rather than having it silently dropped (matching the
/// lenient behaviour the Run Dashboard's notification template uses).
///
/// The caller owns the token→value mapping (e.g. the broadcast builds it from
/// its `BroadcastSessionState`); this helper is purely the string machinery so
/// every caller interpolates identically.
String expandWatermarkTokens(String template, Map<String, String> tokens) {
  final buf = StringBuffer();
  var i = 0;
  while (i < template.length) {
    final ch = template[i];
    if (ch == r'$' && i + 1 < template.length && template[i + 1] == '{') {
      final close = template.indexOf('}', i + 2);
      if (close > 0) {
        final token = template.substring(i + 2, close).trim();
        final resolved = tokens[token];
        // Unknown tokens surface unmodified so the user can spot the typo.
        buf.write(resolved ?? '\${$token}');
        i = close + 1;
        continue;
      }
    }
    buf.write(ch);
    i++;
  }
  return buf.toString();
}
