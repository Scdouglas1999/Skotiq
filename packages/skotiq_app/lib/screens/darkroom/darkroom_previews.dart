/// The pictures the Darkroom shows for a registered image: a recipe's
/// rendered draft when there is one, else the master's own auto-stretched
/// preview, written when the master was registered.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';

/// Bumped when a draft thumbnail is saved, so the lists that show one read
/// it again.
final darkroomDraftPreviewRevisionProvider = StateProvider<int>((ref) => 0);

/// The widest a saved draft thumbnail is.
const int kDarkroomDraftPreviewWidth = 960;

/// Where the rendered draft of recipe [recipeId] over [baseMasterPath] is
/// kept: a `previews` folder beside the master.
String darkroomRecipePreviewPath(String baseMasterPath, int recipeId) =>
    p.join(p.dirname(baseMasterPath), 'previews', 'recipe-$recipeId.jpg');

/// The newest rendered draft among [recipes] that is on disk, or null.
String? darkroomRecipeDraftPreview(
  Iterable<DarkroomRecipe> recipes, {
  bool Function(String path)? exists,
}) {
  final onDisk = exists ?? (path) => File(path).existsSync();
  final newest = recipes.where((r) => r.id != null).toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  for (final recipe in newest) {
    final path = darkroomRecipePreviewPath(recipe.baseMasterPath, recipe.id!);
    if (onDisk(path)) return path;
  }
  return null;
}

/// Whether a render's pixels are fit to show as a picture: stretched by the
/// recipe itself, or lifted by the engine's screen transfer.
bool darkroomRenderIsDisplayable(String? applied, String? sourceDomain) =>
    applied == 'screen' || sourceDomain == 'stretched';

/// Save a rendered RGBA frame as the draft thumbnail at [path], scaled to at
/// most [kDarkroomDraftPreviewWidth] wide. Runs off the UI isolate.
Future<void> saveDarkroomRecipePreview({
  required String path,
  required int width,
  required int height,
  required Uint8List rgba,
}) {
  return Isolate.run(() {
    final frame = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
    );
    final scaled = width > kDarkroomDraftPreviewWidth
        ? img.copyResize(
            frame,
            width: math.min(width, kDarkroomDraftPreviewWidth),
            interpolation: img.Interpolation.average,
          )
        : frame;
    final file = File(path);
    file.parent.createSync(recursive: true);
    // Written beside and renamed over, so a reader never sees half a file.
    final partial = File('$path.part');
    partial.writeAsBytesSync(img.encodeJpg(scaled, quality: 88));
    partial.renameSync(path);
  });
}
