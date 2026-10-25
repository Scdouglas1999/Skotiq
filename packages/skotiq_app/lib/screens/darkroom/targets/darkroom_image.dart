import 'dart:io';

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A master's preview image from disk, or a quiet placeholder when it has none
/// or the file is gone.
class DarkroomPreviewImage extends StatelessWidget {
  const DarkroomPreviewImage({
    super.key,
    required this.path,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.decodeWidth,
    this.placeholderIcon = SkotiqIcons.image,
  });

  final String? path;
  final BoxFit fit;
  final Alignment alignment;

  /// Decode width in physical pixels; previews are full-frame, so every
  /// caller decodes at the size it draws.
  final int? decodeWidth;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final placeholder = ColoredBox(
      color: colors.well,
      child: Center(
        child: Icon(
          placeholderIcon,
          size: SkotiqTokens.iconMd,
          color: colors.textMuted,
        ),
      ),
    );
    final file = path;
    if (file == null || file.isEmpty || !File(file).existsSync()) {
      return placeholder;
    }
    return Image.file(
      File(file),
      fit: fit,
      alignment: alignment,
      cacheWidth: decodeWidth,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => placeholder,
    );
  }
}
