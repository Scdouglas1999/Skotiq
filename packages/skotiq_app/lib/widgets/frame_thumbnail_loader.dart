import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../utils/image_decode_size.dart';
import 'red_night_filter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        DbCapturedImage,
        imagingBackendProvider,
        isRemoteModeProvider,
        loggingServiceProvider;
import 'package:skotiq_ui/skotiq_ui.dart' show SkotiqColors;

/// Result of asking the backend (and then the local disk) for a frame's
/// preview bytes.
class FrameThumbnailPayload {
  /// Decoded preview bytes, when the backend had a cached thumbnail.
  final Uint8List? bytes;

  /// Whether the frame's own file is readable on this machine. False in remote
  /// mode, where the file lives on the host.
  final bool fileExists;

  /// Why no bytes came back, for a tooltip. Null when nothing went wrong.
  final String? errorMessage;

  const FrameThumbnailPayload({
    this.bytes,
    required this.fileExists,
    this.errorMessage,
  });
}

/// True for the container formats Flutter's image decoders cannot open.
///
/// A FITS/XISF path must never be handed to `Image.file`: it renders as a
/// broken-image glyph rather than as the frame.
bool isFitsLikePath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.fits') ||
      lower.endsWith('.fit') ||
      lower.endsWith('.fts') ||
      lower.endsWith('.xisf');
}

/// True for the raster formats `Image.file` can actually decode.
///
/// This is the allowlist, and it is deliberately not `!isFitsLikePath`: the two
/// disagree on every extension neither names and on extension-less paths, which
/// is why the same frame used to preview on one surface and show a placeholder
/// on another. An unknown extension is not evidence that Flutter can decode it.
bool isDisplayableImagePath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.tif') ||
      lower.endsWith('.tiff');
}

/// Fetches a frame's preview, preferring the backend's thumbnail cache and
/// falling back to the local file.
///
/// Shared by the Analytics thumbnail rail and the frame inspector it opens so
/// the two can never disagree about whether a frame is viewable.
Future<FrameThumbnailPayload> loadFrameThumbnail(
  WidgetRef ref,
  DbCapturedImage image,
) async {
  final backend = ref.read(imagingBackendProvider);
  String? backendError;
  try {
    final bytes = await backend.getImageThumbnail(image.id);
    if (bytes.isNotEmpty) {
      return FrameThumbnailPayload(bytes: bytes, fileExists: true);
    }
    backendError =
        'Thumbnail not found in backend cache for image ${image.id}.';
  } catch (error) {
    backendError =
        'Backend thumbnail request failed for image ${image.id}: $error';
    ref.read(loggingServiceProvider).warning(
          'loadFrameThumbnail: $backendError',
          source: 'FrameThumbnail',
        );
  }

  // In remote mode the frame's path names a file on the HOST, so probing it
  // here would report the operator's own disk.
  if (ref.read(isRemoteModeProvider)) {
    return FrameThumbnailPayload(
      fileExists: false,
      errorMessage: backendError,
    );
  }

  try {
    final exists = await File(image.filePath).exists();
    return FrameThumbnailPayload(
      fileExists: exists,
      errorMessage: backendError,
    );
  } catch (error) {
    final localError =
        'Failed to check local image file "${image.filePath}": $error';
    ref.read(loggingServiceProvider).warning(
          'loadFrameThumbnail: $localError',
          source: 'FrameThumbnail',
        );
    return FrameThumbnailPayload(
      fileExists: false,
      errorMessage: '$backendError\n$localError',
    );
  }
}

/// Fetches just the backend's cached thumbnail bytes for a frame.
///
/// Returns null — rather than throwing — when the backend has no thumbnail or
/// the request fails, because every caller renders a placeholder in that case
/// and a thrown error would take down the surrounding strip. [source] names the
/// surface in the log so a failing rail is still attributable.
Future<Uint8List?> fetchFrameThumbnailBytes(
  WidgetRef ref,
  int imageId, {
  required String source,
}) async {
  try {
    final bytes = await ref.read(imagingBackendProvider).getImageThumbnail(
          imageId,
        );
    if (bytes.isNotEmpty) return bytes;
  } catch (e) {
    ref.read(loggingServiceProvider).debug(
          '$source: backend thumbnail fetch failed for image $imageId: $e',
          source: source,
        );
  }
  return null;
}

/// The frame-preview ladder every thumbnail surface renders: the backend's
/// cached thumbnail (which decodes both locally and remotely), then the frame's
/// own file when it is local and Flutter can decode it, then a placeholder.
///
/// Feed it a future from [fetchFrameThumbnailBytes].
class FrameThumbnail extends ConsumerWidget {
  final Future<Uint8List?>? bytesFuture;

  /// Path to the frame on disk, used only when not in remote mode.
  final String fallbackFilePath;

  final SkotiqColors colors;

  /// Size of both the placeholder icon and the loading spinner.
  final double iconSize;

  final BoxFit fit;

  /// Whether the placeholder and spinner are centred in the available space.
  /// False where the caller already centres the tile's contents.
  final bool center;

  const FrameThumbnail({
    super.key,
    required this.bytesFuture,
    required this.fallbackFilePath,
    required this.colors,
    this.iconSize = 16,
    this.fit = BoxFit.cover,
    this.center = true,
  });

  Widget _wrap(Widget child) => center ? Center(child: child) : child;

  Widget _placeholder() =>
      _wrap(Icon(LucideIcons.image, size: iconSize, color: colors.textMuted));

  /// Builds [image] with a `cacheWidth` matching the cell it lands in, so the
  /// decode is the size of the tile rather than the size of the file.
  Widget _decodedToCell(Widget Function(int? cacheWidth) image) {
    return LayoutBuilder(
      builder: (context, constraints) => RedNightImage(
        child: image(thumbnailDecodeWidth(context, constraints.maxWidth)),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    return FutureBuilder<Uint8List?>(
      future: bytesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _wrap(
            SizedBox(
              width: iconSize,
              height: iconSize,
              child: CircularProgressIndicator(
                strokeWidth: 1.4,
                valueColor: AlwaysStoppedAnimation<Color>(colors.textMuted),
              ),
            ),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          // No backend thumbnail. `Image.file` handles a missing file through
          // its own errorBuilder, so there is no need to stat it from a sync
          // build.
          if (!isRemoteMode && isDisplayableImagePath(fallbackFilePath)) {
            return _decodedToCell(
              (cacheWidth) => Image.file(
                File(fallbackFilePath),
                fit: fit,
                width: double.infinity,
                height: double.infinity,
                cacheWidth: cacheWidth,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _placeholder(),
              ),
            );
          }
          return _placeholder();
        }
        // A thumbnail is image DATA, so red night re-emits its luminance on
        // the red axis instead of putting a full-colour frame on screen.
        return _decodedToCell(
          (cacheWidth) => Image.memory(
            bytes,
            fit: fit,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: cacheWidth,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _placeholder(),
          ),
        );
      },
    );
  }
}
