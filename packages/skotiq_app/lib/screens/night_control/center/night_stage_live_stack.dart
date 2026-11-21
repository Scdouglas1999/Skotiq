import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/image_preview/frame_overlay_controls.dart';
import '../../imaging/widgets/live_stack/live_stack_darkroom_provider.dart';
import '../../imaging/widgets/live_stack/live_stack_filter_pills.dart';
import '../../imaging/widgets/live_stack/live_stack_formatters.dart';
import '../../imaging/widgets/live_stack/live_stack_rgba_image.dart';
import '../../imaging/widgets/live_stack_canvas.dart' show StackedImageSource;
import '../../imaging/widgets/preview_viewport.dart';
import '../../imaging/widgets/stacking_panel.dart'
    show stackedPreviewStretchAsyncProvider;

/// Whether Night Control's stage shows the single captured sub or the active
/// per-filter live stack.
enum NightStageMode { sub, liveStack }

/// Selected preview mode for Night Control's stage.
final nightStageModeProvider = StateProvider<NightStageMode>(
  (ref) => NightStageMode.sub,
);

/// Observatory glass mode toggle (`Sub | Live stack`) shown on Night Control's
/// stage ONLY while live stacking is active or armed. Completely invisible when
/// live stacking is idle so users who don't use live stacking see zero extra
/// chrome.
///
/// Uses `.select(...)` so `Sub` mode never rebuilds on pixel updates.
class NightStageLiveStackModePill extends ConsumerWidget {
  const NightStageLiveStackModePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActiveOrArmed = ref.watch(
      liveStackingProvider.select((s) => s.isActiveOrArmed),
    );
    if (!isActiveOrArmed) return const SizedBox.shrink();

    final mode = ref.watch(nightStageModeProvider);
    final totalFrames = ref.watch(
      liveStackingProvider.select((s) => s.totalFramesAcrossFilters),
    );
    final colors = SkotiqColors.of(context);

    return Glass(
      key: const ValueKey('night_stage_mode_pill'),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _ModeSegment(
            key: const ValueKey('night_stage_mode_sub'),
            label: 'Sub',
            selected: mode == NightStageMode.sub,
            colors: colors,
            onTap: () => ref.read(nightStageModeProvider.notifier).state =
                NightStageMode.sub,
          ),
          _ModeSegment(
            key: const ValueKey('night_stage_mode_live_stack'),
            label: totalFrames > 0 ? 'Live stack ($totalFrames)' : 'Live stack',
            selected: mode == NightStageMode.liveStack,
            showLiveDot: true,
            colors: colors,
            onTap: () => ref.read(nightStageModeProvider.notifier).state =
                NightStageMode.liveStack,
          ),
        ],
      ),
    );
  }
}

class _ModeSegment extends StatelessWidget {
  const _ModeSegment({
    super.key,
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
    this.showLiveDot = false,
  });

  final String label;
  final bool selected;
  final SkotiqColors colors;
  final VoidCallback onTap;
  final bool showLiveDot;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? colors.primary.withValues(alpha: 0.22)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          border: selected
              ? Border.all(color: colors.primary.withValues(alpha: 0.55))
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showLiveDot) ...<Widget>[
              StatusDot(color: colors.success, live: true),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: SkotiqTypography.labelSm.copyWith(
                color: selected ? colors.textPrimary : colors.textSecondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live-stack canvas inside Night Control's stage: renders the currently
/// selected per-filter live stack (using Live Darkroom output when enabled, or
/// the progressive F32 auto-stretch off the UI thread) with zoom/pan and
/// bottom per-filter pills + Darkroom controls.
class NightStageLiveStackView extends ConsumerStatefulWidget {
  const NightStageLiveStackView({super.key});

  @override
  ConsumerState<NightStageLiveStackView> createState() =>
      _NightStageLiveStackViewState();
}

class _NightStageLiveStackViewState
    extends ConsumerState<NightStageLiveStackView> {
  double _zoom = 1.0;
  Offset _pan = Offset.zero;
  bool _isPromoting = false;

  void _applyZoom(double factor) {
    setState(() {
      _zoom = (_zoom * factor).clamp(0.25, 8.0);
    });
  }

  Future<void> _openInDarkroom(String filterKey) async {
    if (_isPromoting) return;
    final refusal = darkroomHostOnlyRefusal(ref);
    if (refusal != null) {
      context.showInfoSnackBar(refusal);
      return;
    }
    setState(() => _isPromoting = true);
    try {
      final promoted = await promoteLiveStackToDarkroom(
        ref: ref,
        filterKey: filterKey,
      );
      if (!mounted) return;
      final loc = promoted.recipeId != null
          ? darkroomEditLocation(
              masterId: promoted.masterId,
              recipeId: promoted.recipeId,
            )
          : darkroomEditLocation(masterId: promoted.masterId);
      unawaited(context.push(loc));
    } catch (error) {
      if (!mounted) return;
      context.showErrorSnackBar(
        'Could not open in Darkroom: ${userFacingError(error)}',
      );
    } finally {
      if (mounted) setState(() => _isPromoting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final stack = ref.watch(liveStackingProvider);
    final darkroom = ref.watch(liveStackDarkroomProvider);
    final isRemoteClient = ref.watch(isRemoteClientProvider);

    final activeKey =
        stack.selectedFilterKey ??
        stack.activeFilterStack?.filterKey ??
        kDefaultLiveStackFilterKey;
    final hasPixels =
        stack.previewData != null &&
        stack.previewWidth > 0 &&
        stack.previewHeight > 0;
    final darkroomRender =
        hasPixels && darkroom.enabled && !darkroom.compareBeforeAfter
            ? darkroom.renderFor(activeKey)
            : null;
    final channels = hasPixels &&
            stack.previewData!.length >=
                stack.previewWidth * stack.previewHeight * 3
        ? 3
        : 1;

    Widget buildViewport(BuildContext context, ui.Image image) {
      return RepaintBoundary(
        child: PreviewViewport(
          image: image,
          zoomLevel: _zoom,
          panOffset: _pan,
          onZoomIn: () => _applyZoom(1.25),
          onZoomOut: () => _applyZoom(1 / 1.25),
          onPanUpdate: (delta) => setState(() => _pan += delta),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (!hasPixels)
          Center(
            child: SkotiqImageSurface(
              child: EmptyState(
                icon: SkotiqIcons.layers,
                title: 'Live stacking armed',
                body: 'Waiting for the next light frame. Each filter builds '
                    'its own live stack automatically.',
                action: SkotiqButton(
                  label: 'Back to sub',
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () =>
                      ref.read(nightStageModeProvider.notifier).state =
                          NightStageMode.sub,
                ),
              ),
            ),
          )
        else if (darkroomRender != null)
          RgbaImageSource(
            rgba: darkroomRender.rgba,
            width: darkroomRender.width,
            height: darkroomRender.height,
            builder: buildViewport,
          )
        else
          StackedImageSource(
            data: stack.previewData!,
            width: stack.previewWidth,
            height: stack.previewHeight,
            channels: channels,
            stretchAsync: ref.watch(stackedPreviewStretchAsyncProvider),
            filterKey: activeKey,
            revision:
                stack.activeFilterStack?.revision ??
                stack.stats.stackedFrameCount,
            maxDimension: 1600,
            colors: colors,
            builder: buildViewport,
          ),

        // Bottom overlay: per-filter switcher pills + quick Darkroom & Stop controls
        Positioned(
          left: 10,
          right: 10,
          bottom: 10,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: stack.availableFilters.isNotEmpty
                    ? Glass(
                        padding: const EdgeInsets.symmetric(
                          horizontal: SkotiqTokens.spaceSm,
                          vertical: SkotiqTokens.spaceXs,
                        ),
                        child: LiveStackFilterPills(
                          filters: stack.availableFilters,
                          stacks: stack.filterStacks,
                          selectedFilter: activeKey,
                          compact: true,
                          onSelect: (key) => ref
                              .read(liveStackingProvider.notifier)
                              .selectFilter(key),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Wrap(
                spacing: SkotiqTokens.spaceXs,
                runSpacing: SkotiqTokens.spaceXs,
                alignment: WrapAlignment.end,
                children: <Widget>[
                  if (hasPixels && !isRemoteClient)
                    FrameViewButton(
                      key: const ValueKey('night_stage_live_darkroom_toggle'),
                      label: darkroom.enabled ? 'Darkroom on' : 'Darkroom',
                      icon: SkotiqIcons.aperture,
                      selected: darkroom.enabled,
                      tooltip: darkroom.enabled
                          ? 'Turn off Live Darkroom processing'
                          : 'Apply Live Darkroom processing over this stack',
                      onPressed: () => ref
                          .read(liveStackDarkroomProvider.notifier)
                          .setEnabled(!darkroom.enabled),
                    ),
                  if (hasPixels && !isRemoteClient)
                    FrameViewButton(
                      key: const ValueKey('night_stage_open_darkroom'),
                      label: _isPromoting ? 'Opening…' : 'Open Darkroom',
                      icon: SkotiqIcons.externalLink,
                      tooltip: 'Promote this live stack into the full Darkroom editor',
                      onPressed:
                          _isPromoting ? null : () => _openInDarkroom(activeKey),
                    ),
                  if (hasPixels && _zoom != 1.0)
                    FrameViewButton(
                      label: 'Fit',
                      tooltip: 'Reset zoom and pan',
                      onPressed: () => setState(() {
                        _zoom = 1.0;
                        _pan = Offset.zero;
                      }),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Top-left status summary pill when Night Control is viewing a live stack.
FramePillText nightLiveStackStatusPill(LiveStackingState stack) {
  final activeKey =
      stack.selectedFilterKey ??
      stack.activeFilterStack?.filterKey ??
      kDefaultLiveStackFilterKey;
  final label = liveStackFilterDisplayName(activeKey);
  final frames = stack.stats.stackedFrameCount;
  final integration = formatLiveIntegration(stack.stats.totalIntegrationSecs);
  return FramePillText(
    title: 'Live stack · $label',
    time: frames > 0
        ? '$frames ${frames == 1 ? 'frame' : 'frames'}'
            '${integration != '—' ? ' · $integration' : ''}'
        : 'Armed',
    dot: FramePillTone.good,
    mono: frames > 1
        ? '${stack.stats.avgAlignmentResidual.toStringAsFixed(2)} px'
        : null,
  );
}
