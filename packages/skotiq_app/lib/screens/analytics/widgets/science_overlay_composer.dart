import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'science_overlay_legend.dart';

class ScienceOverlayComposer extends ConsumerWidget {
  final SkotiqColors colors;

  const ScienceOverlayComposer({
    super.key,
    required this.colors,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overlayState = ref.watch(scienceOverlayStateProvider);
    final prefsAsync = ref.watch(scienceVisualizationPrefsProvider);

    if (prefsAsync.hasError || !prefsAsync.hasValue) {
      return SkotiqPanel(
        padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!prefsAsync.hasError)
              const CircularProgressIndicator(strokeWidth: 2)
            else ...[
              Text(
                'Could not load science overlay preferences',
                style: SkotiqTypography.body.copyWith(color: colors.error),
              ),
              const SizedBox(height: 6),
              Text(
                prefsAsync.error.toString(),
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: 10),
              SkotiqButton(
                label: 'Retry overlay preferences',
                icon: LucideIcons.refreshCw,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () =>
                    ref.invalidate(scienceVisualizationPrefsProvider),
              ),
            ],
          ],
        ),
      );
    }
    final prefs = prefsAsync.requireValue;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Overlay Composer',
                style: SkotiqTypography.bodyStrong
                    .copyWith(color: colors.textPrimary),
              ),
              const Spacer(),
              Text(
                'Tap ⓘ for what each layer means',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(LucideIcons.info, size: 12, color: colors.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Overlays apply to the Imaging live view',
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textMuted),
                ),
              ),
              TextButton.icon(
                onPressed: () => context.go('/imaging'),
                icon: Icon(
                  LucideIcons.arrowRight,
                  size: 12,
                  color: colors.primary,
                ),
                label: Text(
                  'Open Imaging',
                  style: SkotiqTypography.caption.copyWith(
                      color: colors.primary, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _LayerChip(
                legendKey: 'uniformity',
                label: 'Uniformity',
                active: overlayState.showUniformityMap,
                onTap: () {
                  ref.read(scienceOverlayStateProvider.notifier).state =
                      overlayState.copyWith(
                    showUniformityMap: !overlayState.showUniformityMap,
                  );
                },
              ),
              _LayerChip(
                legendKey: 'clip_high',
                label: 'Clip high',
                active: overlayState.showClipHighMap,
                onTap: () {
                  ref.read(scienceOverlayStateProvider.notifier).state =
                      overlayState.copyWith(
                    showClipHighMap: !overlayState.showClipHighMap,
                  );
                },
              ),
              _LayerChip(
                legendKey: 'clip_low',
                label: 'Clip low',
                active: overlayState.showClipLowMap,
                onTap: () {
                  ref.read(scienceOverlayStateProvider.notifier).state =
                      overlayState.copyWith(
                    showClipLowMap: !overlayState.showClipLowMap,
                  );
                },
              ),
              _LayerChip(
                legendKey: 'residuals',
                label: 'Residual',
                active: overlayState.showResidualVectors,
                onTap: () {
                  ref.read(scienceOverlayStateProvider.notifier).state =
                      overlayState.copyWith(
                    showResidualVectors: !overlayState.showResidualVectors,
                  );
                },
              ),
              _LayerChip(
                legendKey: 'moving',
                label: 'Moving tracks',
                active: overlayState.showMovingObjectTracks,
                onTap: () {
                  ref.read(scienceOverlayStateProvider.notifier).state =
                      overlayState.copyWith(
                    showMovingObjectTracks:
                        !overlayState.showMovingObjectTracks,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Overlay Opacity ${(prefs.overlayOpacity * 100).round()}%',
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                ),
              ),
            ],
          ),
          Slider(
            min: 0.05,
            max: 0.95,
            value: prefs.overlayOpacity.clamp(0.05, 0.95),
            onChanged: (value) {
              final next = prefs.copyWith(overlayOpacity: value);
              ref
                  .read(scienceVisualizationPrefsProvider.notifier)
                  .savePrefs(next);
            },
          ),
          // Show the inline gradient legend for whichever quantitative
          // overlay is currently active. This gives users immediate "color
          // = meaning" guidance the moment they enable an overlay, instead
          // of forcing them into the long-form info dialog.
          if (overlayState.showUniformityMap ||
              overlayState.showClipHighMap ||
              overlayState.showClipLowMap)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ScienceOverlayLegend.inlineFor(
                context,
                overlayState.showClipHighMap
                    ? 'clip_high'
                    : overlayState.showClipLowMap
                        ? 'clip_low'
                        : 'uniformity',
              ),
            ),
        ],
      ),
    );
  }
}

class _LayerChip extends StatelessWidget {
  final String label;
  final String legendKey;
  final bool active;
  final VoidCallback onTap;

  const _LayerChip({
    required this.label,
    required this.legendKey,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Semantics(
        button: true,
        enabled: true,
        selected: active,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => ScienceOverlayLegend.show(context, legendKey),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: active
                ? SkotiqDecorations.panelSelected(colors)
                : BoxDecoration(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    color: colors.surfaceElevated,
                    border: Border.all(color: colors.border),
                  ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: SkotiqTypography.caption
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 6),
                Semantics(
                    button: true,
                    enabled: true,
                    child: InkWell(
                      onTap: () =>
                          ScienceOverlayLegend.show(context, legendKey),
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusLg),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          LucideIcons.info,
                          size: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )),
              ],
            ),
          ),
        ));
  }
}
