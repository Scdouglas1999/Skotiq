import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'framing_canvas.dart';

/// The framing sky: the survey and HiPS imagery with the field-of-view
/// reticle and its glass chrome, on the one framing session
/// ([framingProvider]). Plan > Framing and the sequencer's Frame target dialog
/// both show it.
class FramingSkyCanvas extends ConsumerWidget {
  const FramingSkyCanvas({super.key, this.canvasKey});

  /// Key for the canvas itself, for the screen whose tour points at it.
  final Key? canvasKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final framingState = ref.watch(framingProvider);
    final equipmentResult = ref.watch(framingFOVProvider);
    // The mosaic's panels are cut from the camera field, so a field that
    // resolves or changes after the mosaic was drawn re-cuts them.
    ref.listen(framingFOVProvider, (previous, next) {
      final before = previous?.valueOrNull?.equipment;
      final after = next.valueOrNull?.equipment;
      if (before?.fovWidthDeg != after?.fovWidthDeg ||
          before?.fovHeightDeg != after?.fovHeightDeg) {
        ref.read(framingProvider.notifier).recalculateMosaicIfNeeded();
      }
    });
    return FramingCanvas(
      key: canvasKey,
      colors: colors,
      framingState: framingState,
      equipmentResult: equipmentResult.valueOrNull,
      onPan: (dx, dy, canvasSize) {
        ref.read(framingProvider.notifier).pan(dx, dy, canvasSize: canvasSize);
      },
      onRotate: (angle) {
        ref.read(framingProvider.notifier).setRotation(angle);
      },
      onAimChanged: (raHours, decDegrees) {
        ref.read(framingProvider.notifier).setAim(raHours, decDegrees);
      },
      onCanvasResized: (canvasSize) {
        ref.read(framingProvider.notifier).onCanvasResized(canvasSize);
      },
    );
  }
}
