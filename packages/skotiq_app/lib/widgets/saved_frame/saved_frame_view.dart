// A saved frame on screen at full resolution. Its thumbnail shows at once;
// the frame decoded from its own file replaces it when it lands, drawn the way
// the live frame is (FrameCanvas), so zoom 1:1, pan, the star circles and the
// catalog labels are the frame's own.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart' show SolvedWcs;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';
import '../frame_thumbnail_loader.dart';
import '../image_preview/frame_canvas.dart';
import '../image_preview/frame_overlay_controls.dart';

class SavedFrameView extends ConsumerWidget {
  const SavedFrameView({
    super.key,
    required this.frame,
    required this.viewport,
    required this.zoomLevel,
    required this.panOffset,
    required this.semanticsLabel,
    this.onPan,
    this.showStars = false,
    this.showCatalog = false,
  });

  final SavedFrameRef frame;
  final Size viewport;

  /// Relative to fit, as [FrameCanvas] takes it.
  final double zoomLevel;
  final Offset panOffset;
  final String semanticsLabel;
  final ValueChanged<Offset>? onPan;
  final bool showStars;
  final bool showCatalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = ref.watch(savedFrameProvider(frame));
    // At fit the full frame lands exactly over its thumbnail, which stays
    // under it until the decoded texture is up.
    final placeholder = zoomLevel == 1.0 || load is! SavedFrameReady;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (placeholder) ExcludeSemantics(child: _Thumbnail(frame: frame)),
        if (load case SavedFrameReady(:final image, :final localPath))
          FrameCanvas(
            image: image,
            viewport: viewport,
            zoomLevel: zoomLevel,
            panOffset: panOffset,
            onPan: onPan,
            semanticsLabel: semanticsLabel,
            stars: showStars
                ? ref
                    .watch(savedFrameStarsProvider(localPath))
                    .valueOrNull
                    ?.stars
                : null,
            showCatalog: showCatalog,
            wcs: showCatalog ? _wcs(ref, image) : null,
          )
        else
          Semantics(image: true, label: semanticsLabel),
      ],
    );
  }

  SolvedWcs? _wcs(WidgetRef ref, CapturedImageData image) {
    final stored =
        ref.watch(capturedImageWcsProvider(frame.imageId)).valueOrNull;
    if (stored == null || !stored.isPlateSolved) return null;
    return stored.solvedWcs(width: image.width, height: image.height);
  }
}

/// What a saved frame's load says while it is not on screen yet, and the
/// frame's size once it is; for the pill beside the view buttons.
FramePillText savedFrameLoadPill(
  SkotiqLocalizations l10n,
  SavedFrameLoad load,
) {
  return switch (load) {
    SavedFrameDecoding() => FramePillText(
        title: l10n.text('savedFrameLoading'),
        dot: FramePillTone.active,
      ),
    SavedFrameDownloading(:final fraction) => FramePillText(
        title: l10n.text('savedFrameDownloading'),
        dot: FramePillTone.active,
        mono: fraction == null ? null : '${(fraction * 100).floor()}%',
      ),
    SavedFrameFailed(:final message) => FramePillText(
        title: l10n.text('savedFrameFailed'),
        status: message,
        statusTone: FramePillTone.bad,
        dot: FramePillTone.bad,
      ),
    SavedFrameReady(:final image) => FramePillText(
        title: l10n.text('savedFrameFullResolution'),
        dot: FramePillTone.good,
        mono: '${image.width} × ${image.height}',
      ),
  };
}

class _Thumbnail extends ConsumerStatefulWidget {
  const _Thumbnail({required this.frame});

  final SavedFrameRef frame;

  @override
  ConsumerState<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends ConsumerState<_Thumbnail> {
  late Future<Uint8List?> _bytes = _load();

  @override
  void didUpdateWidget(covariant _Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame.imageId != widget.frame.imageId) _bytes = _load();
  }

  Future<Uint8List?> _load() =>
      fetchFrameThumbnailBytes(ref, widget.frame.imageId, source: 'SavedFrame');

  @override
  Widget build(BuildContext context) {
    return FrameThumbnail(
      bytesFuture: _bytes,
      // A frame file is never one Flutter can draw; the thumbnail or the
      // placeholder stands in until the frame is decoded.
      fallbackFilePath: '',
      colors: context.skotiqColors,
      iconSize: 28,
      fit: BoxFit.contain,
    );
  }
}
