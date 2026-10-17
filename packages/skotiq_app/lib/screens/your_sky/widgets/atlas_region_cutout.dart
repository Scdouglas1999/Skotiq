import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/image_decode_size.dart';

/// Renders the co-added cutout for a region at its LATEST depth, keyed by
/// region id via [atlasRegionCutoutProvider].
///
/// Portable across backends: on the desktop `FfiBackend` the provider hands back
/// a host-local PNG path ([AtlasRegionCutout.filePath]) loaded with `Image.file`;
/// on a mobile `NetworkBackend` companion it hands back PNG bytes fetched over
/// the host's `/api/atlas/region/<id>/cutout` route ([AtlasRegionCutout.bytes])
/// rendered with `Image.memory` — the host-local file path is never shipped over
/// the wire. Routing the hero image through the cone co-add (not a single
/// deepest tile) also gives the true region image rather than a fragment.
class AtlasRegionCutout extends ConsumerWidget {
  final int regionId;
  final BoxFit fit;

  const AtlasRegionCutout({
    super.key,
    required this.regionId,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final cutoutAsync = ref.watch(atlasRegionCutoutProvider(regionId));

    return cutoutAsync.when(
      data: (cutout) => _CutoutImage(cutout: cutout, fit: fit, colors: colors),
      loading: () => _CutoutState(
        colors: colors,
        child: const SkotiqCircularProgress(
          value: 0,
          indeterminate: true,
          size: SkotiqTokens.iconLg,
        ),
      ),
      error: (_, __) => _CutoutState(
        colors: colors,
        child: Icon(LucideIcons.imageOff,
            size: SkotiqTokens.iconLg, color: colors.textMuted),
      ),
    );
  }
}

class _CutoutImage extends StatelessWidget {
  final AtlasRegionCutoutImage cutout;
  final BoxFit fit;
  final SkotiqColors colors;

  const _CutoutImage({
    required this.cutout,
    required this.fit,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    // The same widget is the region card's small preview and the region detail
    // screen's hero, so the decode size comes from the box rather than from a
    // constant: the card gets a card-sized decode of a co-add that can be
    // several thousand pixels across, the hero gets a hero-sized one.
    return LayoutBuilder(builder: _buildImage);
  }

  Widget _buildImage(BuildContext context, BoxConstraints constraints) {
    final cacheWidth = thumbnailDecodeWidth(context, constraints.maxWidth);
    final bytes = cutout.bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: fit,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => _missing(),
      );
    }
    final path = cutout.filePath;
    if (path == null || !File(path).existsSync()) {
      return _missing();
    }
    return Image.file(
      File(path),
      fit: fit,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => _missing(),
    );
  }

  Widget _missing() => _CutoutState(
        colors: colors,
        child: Icon(LucideIcons.imageOff,
            size: SkotiqTokens.iconLg, color: colors.textMuted),
      );
}

class _CutoutState extends StatelessWidget {
  final SkotiqColors colors;
  final Widget child;

  const _CutoutState({required this.colors, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.well,
      alignment: Alignment.center,
      child: child,
    );
  }
}
