import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../framing_hips_layer_wiring.dart';
import 'framing_canvas.dart';
import 'optical_config_panel.dart';

/// The framing sky: the survey and HiPS imagery with the field-of-view
/// reticle, its canvas controls, the survey credit and the optical config
/// panel, all on the one framing session ([framingProvider]). Plan > Framing
/// and the sequencer's Frame target dialog both show it.
class FramingSkyCanvas extends ConsumerWidget {
  const FramingSkyCanvas({super.key, this.canvasKey});

  /// Key for the canvas itself, for the screen whose tour points at it.
  final Key? canvasKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final framingState = ref.watch(framingProvider);
    final equipmentResult = ref.watch(framingFOVProvider);
    return Stack(
      children: [
        Positioned.fill(
          child: FramingCanvas(
            key: canvasKey,
            colors: colors,
            framingState: framingState,
            equipmentResult: equipmentResult.valueOrNull,
            onPan: (dx, dy, canvasSize) {
              ref
                  .read(framingProvider.notifier)
                  .pan(dx, dy, canvasSize: canvasSize);
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
          ),
        ),
        // GPU HiPS framing attribution chrome. The streamed tile
        // mosaic itself is composed INSIDE FramingCanvas's Stack — above
        // the single-cutout survey snapshot and UNDER the grid / FOV /
        // equipment overlays — so the imagery never hides the FOV
        // reticle. This wiring only adds the survey attribution credit
        // badge as top chrome (a license requirement), self-positioning
        // in the canvas's bottom band and gated internally by
        // hipsFramingActiveProvider, so it contributes nothing when the
        // feature is off or the survey has no verified HiPS pyramid.
        const Positioned.fill(child: FramingHipsLayerWiring()),
        if (framingState.showOpticalConfigPanel)
          const Positioned(
            top: 16,
            left: 16,
            child: OpticalConfigPanel(),
          )
        else
          Positioned(
            top: 16,
            left: 16,
            child: Tooltip(
              message: 'Show optical config panel',
              child: Material(
                color: colors.surface,
                borderRadius: SkotiqTokens.borderRadiusInline8,
                child: InkWell(
                  borderRadius: SkotiqTokens.borderRadiusInline8,
                  onTap: () {
                    ref
                        .read(framingProvider.notifier)
                        .setOpticalConfigPanelVisible(true);
                  },
                  child: Container(
                    // ≥48px touch target so the show-config affordance is
                    // tappable on a phone (the inner icon stays 16px).
                    constraints: const BoxConstraints(
                      minWidth: SkotiqTokens.minTouchTarget,
                      minHeight: SkotiqTokens.minTouchTarget,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.border),
                      borderRadius: SkotiqTokens.borderRadiusInline8,
                    ),
                    child: Icon(
                      SkotiqIcons.aperture,
                      size: 16,
                      color: colors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
