import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import '../../../utils/snackbar_helper.dart';
import 'depthlock/depthlock_hint.dart';
import 'depthlock/depthlock_region_layer.dart';
import 'depthlock/depthlock_selection.dart';
import 'live_stack/live_stack_darkroom_provider.dart';
import 'live_stack/live_stack_filter_pills.dart';
import 'live_stack/live_stack_formatters.dart';
import 'live_stack/live_stack_rgba_image.dart';
import 'live_stack/live_stack_side_panel.dart';
import 'preview_viewport.dart';
import 'session_stack_plan.dart';
import 'stacking_panel.dart'
    show
        StackedPreviewStretch,
        StackedPreviewStretchAsync,
        stackedPreviewStretchAsyncProvider;

/// Where the live stack canvas is zoomed and panned to.
///
/// Its own state rather than the live view's: the two canvases show different
/// pictures at different scales, and carrying one's zoom onto the other means
/// switching tabs moves the frame under the operator.
@immutable
class StackCanvasView {
  const StackCanvasView({this.zoomLevel = 1.0, this.panOffset = Offset.zero});

  /// Multiplier on top of fit-to-window, matching the live view's convention.
  final double zoomLevel;
  final Offset panOffset;

  StackCanvasView copyWith({double? zoomLevel, Offset? panOffset}) =>
      StackCanvasView(
        zoomLevel: zoomLevel ?? this.zoomLevel,
        panOffset: panOffset ?? this.panOffset,
      );
}

final stackCanvasViewProvider = StateProvider<StackCanvasView>(
  (ref) => const StackCanvasView(),
);

/// The Live stack tab's canvas: the stacked image, pannable and zoomable, with
/// per-filter switching, real-time Live Darkroom rendering, Observatory glass
/// telemetry readouts, and the DepthLock region tool / saved-goal overlay.
///
/// Marking here is legitimate because the stacker warps every frame into the
/// reference sub's pixel grid — a rectangle on this image is a rectangle in
/// that sub's pixels. `depthLockStackSelectionProvider` is what enforces the
/// conditions that make that true, including the size check.
class LiveStackCanvas extends ConsumerWidget {
  const LiveStackCanvas({super.key});

  /// Zoom step per press or wheel notch, matching the live view.
  static const double zoomStep = 1.25;
  static const double minZoom = 0.25;
  static const double maxZoom = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final stack = ref.watch(liveStackingProvider);
    final view = ref.watch(stackCanvasViewProvider);
    final darkroom = ref.watch(liveStackDarkroomProvider);

    if (stack.previewData == null ||
        stack.previewWidth <= 0 ||
        stack.previewHeight <= 0) {
      final isRunning = stack.status == LiveStackingStatus.running;
      final isRemote = ref.watch(isRemoteModeProvider);
      final plan = ref.watch(sessionStackPlanProvider);
      final currentFilePath = ref.watch(
        currentImageProvider.select((img) => img?.filePath),
      );
      final canStartFromCurrent = !isRunning &&
          !isRemote &&
          currentFilePath != null &&
          currentFilePath.isNotEmpty;

      return Container(
        color: colors.isRedNight
            ? colors.background
            : SkotiqColors.dark.background,
        child: Center(
          child: SkotiqImageSurface(
            child: EmptyState(
              icon: SkotiqIcons.layers,
              title: isRunning
                  ? 'Waiting for the first stacked frame'
                  : 'No stack running',
              body: isRunning
                  ? 'Live stacking is armed — your next captured frame becomes '
                      'the reference for its filter and subsequent frames stack '
                      'automatically.'
                  : plan != null
                      ? 'Stack tonight\'s frames or arm live stacking to build '
                          'per-filter integrations as exposures arrive.'
                      : 'Arm live stacking to build per-filter integrations as '
                          'exposures arrive, or pick a reference frame in the '
                          'side panel.',
              action: isRunning
                  ? null
                  : Wrap(
                      spacing: SkotiqTokens.spaceSm,
                      runSpacing: SkotiqTokens.spaceSm,
                      alignment: WrapAlignment.center,
                      children: <Widget>[
                        SkotiqButton(
                          key: const ValueKey('live_stack_canvas_arm_btn'),
                          label: 'Arm live stacking',
                          icon: SkotiqIcons.layers,
                          onPressed: () =>
                              ref.read(liveStackingProvider.notifier).arm(),
                        ),
                        if (canStartFromCurrent)
                          SkotiqButton(
                            key: const ValueKey(
                              'live_stack_canvas_from_current_btn',
                            ),
                            label: 'Stack current frame',
                            icon: SkotiqIcons.image,
                            variant: ButtonVariant.secondary,
                            onPressed: () {
                              final img = ref.read(currentImageProvider);
                              if (img == null || img.filePath == null) return;
                              final filter = img.settings.filter;
                              if (filter != null && filter.trim().isNotEmpty) {
                                ref
                                    .read(liveStackingProvider.notifier)
                                    .startFromFileForFilter(
                                      img.filePath!,
                                      filterKey: filter.trim(),
                                    );
                              } else {
                                ref
                                    .read(liveStackingProvider.notifier)
                                    .startFromFile(img.filePath!);
                              }
                            },
                          ),
                      ],
                    ),
            ),
          ),
        ),
      );
    }

    final activeKey =
        stack.selectedFilterKey ??
        stack.activeFilterStack?.filterKey ??
        kDefaultLiveStackFilterKey;
    final darkroomRender = darkroom.enabled && !darkroom.compareBeforeAfter
        ? darkroom.renderFor(activeKey)
        : null;

    Widget buildViewport(BuildContext context, ui.Image image) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          RepaintBoundary(
            child: PreviewViewport(
              image: image,
              zoomLevel: view.zoomLevel,
              panOffset: view.panOffset,
              onZoomIn: () => _zoom(ref, zoomStep),
              onZoomOut: () => _zoom(ref, 1 / zoomStep),
              // While the region tool owns the canvas a drag DRAWS. Left
              // enabled, the viewport's pan recogniser competes with the
              // layer's in the same gesture arena, and the rectangle ends
              // up starting wherever the arena happened to resolve rather
              // than where the operator pressed.
              onPanUpdate: ref.watch(depthLockRegionToolActiveProvider)
                  ? null
                  : (Offset delta) => ref
                          .read(stackCanvasViewProvider.notifier)
                          .state = view.copyWith(
                        panOffset: view.panOffset + delta,
                      ),
              overlays: <PreviewOverlayBuilder>[
                (BuildContext context, PreviewViewportGeometry geometry) {
                  return DepthLockRegionLayer(
                    zoomLevel: geometry.displayScale,
                    imageOffset: geometry.imageOffset,
                    imageSize: geometry.imageSize,
                    // The stack shares its reference sub's pixel grid, so
                    // the sub's astrometry is the stack's astrometry.
                    geometry:
                        ref.watch(depthLockStackSelectionProvider).geometry,
                  );
                },
              ],
            ),
          ),
          Positioned(
            top: SkotiqTokens.spaceMd,
            right: SkotiqTokens.spaceMd,
            child: _StackStatusGlass(
              stack: stack,
              filterKey: activeKey,
              darkroomActive: darkroom.enabled && !darkroom.compareBeforeAfter,
              comparingRaw: darkroom.enabled && darkroom.compareBeforeAfter,
              isRenderingDarkroom: darkroom.isRendering,
            ),
          ),
          Positioned(
            left: SkotiqTokens.spaceMd,
            bottom: SkotiqTokens.spaceMd,
            child: _StackReadoutsGlass(stack: stack, filterKey: activeKey),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _StackCanvasToolbar(
          onZoomIn: () => _zoom(ref, zoomStep),
          onZoomOut: () => _zoom(ref, 1 / zoomStep),
          onFit: () => ref.read(stackCanvasViewProvider.notifier).state =
              const StackCanvasView(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SkotiqTokens.spaceMd,
            SkotiqTokens.spaceSm,
            SkotiqTokens.spaceMd,
            0,
          ),
          child: DepthLockHint(
            onMarkRegion: () => ref
                .read(depthLockRegionToolActiveProvider.notifier)
                .state = true,
          ),
        ),
        Expanded(
          child: darkroomRender != null
              ? RgbaImageSource(
                  rgba: darkroomRender.rgba,
                  width: darkroomRender.width,
                  height: darkroomRender.height,
                  builder: buildViewport,
                  placeholder: Container(
                    color: colors.isRedNight
                        ? colors.background
                        : SkotiqColors.dark.background,
                  ),
                )
              : StackedImageSource(
                  data: stack.previewData!,
                  width: stack.previewWidth,
                  height: stack.previewHeight,
                  channels: _previewChannels(stack),
                  stretchAsync: ref.watch(stackedPreviewStretchAsyncProvider),
                  filterKey: activeKey,
                  revision:
                      stack.activeFilterStack?.revision ??
                      stack.stats.stackedFrameCount,
                  maxDimension: 2048,
                  colors: colors,
                  builder: buildViewport,
                ),
        ),
      ],
    );
  }

  void _zoom(WidgetRef ref, double factor) {
    final notifier = ref.read(stackCanvasViewProvider.notifier);
    final current = notifier.state;
    notifier.state = current.copyWith(
      zoomLevel: (current.zoomLevel * factor).clamp(minZoom, maxZoom),
    );
  }

  /// 3 for an interleaved RGB16 stack, 1 for a luminance plane.
  int _previewChannels(LiveStackingState stack) {
    final int pixels = stack.previewWidth * stack.previewHeight;
    if (pixels <= 0) return 1;
    return (stack.previewData?.length ?? 0) >= pixels * 3 ? 3 : 1;
  }
}

/// The canvas's own strip: filter switcher, Live Darkroom controls, DepthLock
/// region tool, and view zoom controls.
class _StackCanvasToolbar extends ConsumerStatefulWidget {
  const _StackCanvasToolbar({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;

  @override
  ConsumerState<_StackCanvasToolbar> createState() =>
      _StackCanvasToolbarState();
}

class _StackCanvasToolbarState extends ConsumerState<_StackCanvasToolbar> {
  bool _isPromoting = false;

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
    final filters = stack.availableFilters;
    final activeKey =
        stack.selectedFilterKey ??
        stack.activeFilterStack?.filterKey ??
        kDefaultLiveStackFilterKey;
    final darkroom = ref.watch(liveStackDarkroomProvider);
    final isRemoteClient = ref.watch(isRemoteClientProvider);
    final selection = ref.watch(depthLockStackSelectionProvider);
    final toolActive = ref.watch(depthLockRegionToolActiveProvider);
    final overlayVisible = ref.watch(depthLockGoalOverlayVisibleProvider);

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: filters.isNotEmpty
                ? LiveStackFilterPills(
                    filters: filters,
                    stacks: stack.filterStacks,
                    selectedFilter: activeKey,
                    compact: true,
                    onSelect: (key) =>
                        ref.read(liveStackingProvider.notifier).selectFilter(key),
                  )
                : Text(
                    selection.canSelect
                        ? 'Stacked image'
                        : selection.blocker ?? 'Stacked image',
                    style: SkotiqTypography.caption.copyWith(
                      color: selection.canSelect
                          ? colors.textMuted
                          : colors.textSecondary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          if (!isRemoteClient) ...<Widget>[
            SkotiqButton(
              key: const ValueKey('live_stack_toolbar_darkroom_toggle'),
              label: darkroom.enabled ? 'Darkroom on' : 'Live Darkroom',
              icon: SkotiqIcons.aperture,
              size: ButtonSize.small,
              variant: darkroom.enabled
                  ? ButtonVariant.secondary
                  : ButtonVariant.ghost,
              onPressed: () {
                ref
                    .read(selectedLiveStackPanelProvider.notifier)
                    .state = LiveStackSidePanel.darkroomSectionIndex;
                if (!darkroom.enabled) {
                  ref.read(liveStackDarkroomProvider.notifier).setEnabled(true);
                }
              },
            ),
            if (darkroom.enabled)
              SkotiqIconButton(
                icon: darkroom.compareBeforeAfter
                    ? SkotiqIcons.hidden
                    : SkotiqIcons.visible,
                tooltip: darkroom.compareBeforeAfter
                    ? 'Show Live Darkroom result'
                    : 'Peek raw auto-stretch',
                size: IconButtonSize.sm,
                selected: darkroom.compareBeforeAfter,
                onPressed: () => ref
                    .read(liveStackDarkroomProvider.notifier)
                    .toggleCompareBeforeAfter(),
              ),
            SkotiqIconButton(
              key: const ValueKey('live_stack_toolbar_open_darkroom'),
              icon: SkotiqIcons.externalLink,
              tooltip: 'Open this live stack in full Darkroom editor',
              size: IconButtonSize.sm,
              onPressed: _isPromoting ? null : () => _openInDarkroom(activeKey),
            ),
          ],
          Semantics(
            toggled: toolActive,
            child: SkotiqButton(
              label: toolActive ? 'Stop marking' : 'Mark region',
              // The same dashed selection box as the live view's Mark region.
              icon: LucideIcons.boxSelect,
              size: ButtonSize.small,
              variant: ButtonVariant.ghost,
              semanticsHint: selection.canSelect
                  ? 'Drag two boxes on the stacked image to define a '
                      'DepthLock goal'
                  : selection.blocker,
              onPressed: selection.canSelect
                  ? () {
                      if (toolActive) {
                        cancelDepthLockRegionTool(ref);
                      } else {
                        ref
                            .read(
                              depthLockRegionToolActiveProvider.notifier,
                            )
                            .state = true;
                      }
                    }
                  : null,
            ),
          ),
          SkotiqIconButton(
            icon: overlayVisible ? SkotiqIcons.visible : SkotiqIcons.hidden,
            tooltip: overlayVisible
                ? 'Hide saved goals on the stack'
                : 'Draw saved goals on the stack',
            size: IconButtonSize.sm,
            selected: overlayVisible,
            onPressed: () => ref
                .read(depthLockGoalOverlayVisibleProvider.notifier)
                .state = !overlayVisible,
          ),
          SkotiqIconButton(
            // The same three glyphs the live view's toolbar uses, so the two
            // canvases are driven by the same picture.
            icon: LucideIcons.zoomIn,
            tooltip: 'Zoom in',
            size: IconButtonSize.sm,
            onPressed: widget.onZoomIn,
          ),
          SkotiqIconButton(
            icon: LucideIcons.zoomOut,
            tooltip: 'Zoom out',
            size: IconButtonSize.sm,
            onPressed: widget.onZoomOut,
          ),
          SkotiqIconButton(
            icon: LucideIcons.scan,
            tooltip: 'Fit to window',
            size: IconButtonSize.sm,
            onPressed: widget.onFit,
          ),
        ],
      ),
    );
  }
}

/// Top-right glass HUD over the stacked sky frame.
class _StackStatusGlass extends StatelessWidget {
  const _StackStatusGlass({
    required this.stack,
    required this.filterKey,
    required this.darkroomActive,
    required this.comparingRaw,
    required this.isRenderingDarkroom,
  });

  final LiveStackingState stack;
  final String filterKey;
  final bool darkroomActive;
  final bool comparingRaw;
  final bool isRenderingDarkroom;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isRunning = stack.status == LiveStackingStatus.running;
    final frames = stack.stats.stackedFrameCount;
    final integration = formatLiveIntegration(stack.stats.totalIntegrationSecs);
    final filterText = liveStackFilterDisplayName(filterKey);

    return Glass(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd - 2,
        vertical: SkotiqTokens.spaceSm - 2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          StatusDot(color: colors.success, live: isRunning),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            '$filterText · $frames ${frames == 1 ? 'frame' : 'frames'}'
            '${integration != '—' ? ' · $integration' : ''}',
            style: SkotiqTypography.bodySm,
          ),
          if (darkroomActive || comparingRaw) ...<Widget>[
            const SizedBox(width: SkotiqTokens.spaceSm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: (comparingRaw ? colors.textMuted : colors.primary)
                    .withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              ),
              child: Text(
                isRenderingDarkroom
                    ? 'Darkroom…'
                    : comparingRaw
                        ? 'Raw STF'
                        : 'Darkroom',
                style: SkotiqTypography.monoCaption.copyWith(
                  color: comparingRaw ? colors.textSecondary : colors.primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Bottom-left glass readout HUD: loud tabular numbers, quiet labels.
class _StackReadoutsGlass extends StatelessWidget {
  const _StackReadoutsGlass({
    required this.stack,
    required this.filterKey,
  });

  final LiveStackingState stack;
  final String filterKey;

  @override
  Widget build(BuildContext context) {
    final stats = stack.stats;
    final hasAligned = stats.stackedFrameCount > 1;
    final integration = formatLiveIntegration(stats.totalIntegrationSecs);
    final rejPct = stack.lastFrameTotalPixels > 0
        ? (stack.lastFrameSigmaRejectionRate * 100).toStringAsFixed(1)
        : null;

    return Glass(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: ReadoutRow(
        gap: 18,
        children: <Readout>[
          Readout(
            value: '${stats.stackedFrameCount}',
            label: 'Frames',
          ),
          if (integration != '—')
            Readout(
              value: integration,
              label: 'Integration',
            ),
          Readout(
            value: hasAligned
                ? stats.avgAlignmentResidual.toStringAsFixed(2)
                : null,
            unit: 'px',
            label: 'Residual',
          ),
          Readout(
            value: hasAligned ? stats.avgMatchedPairs.toStringAsFixed(0) : null,
            label: 'Matched',
          ),
          if (rejPct != null)
            Readout(
              value: rejPct,
              unit: '%',
              label: 'Clip rej',
            ),
        ],
      ),
    );
  }
}

/// Turns the stacker's u16 buffer into a drawable image completely off the UI
/// thread (async Rust progressive EAA STF + parallel area downsampling + async
/// Skia RGBA decode) with coalesced updates so rapid frames never drop or pile
/// up.
class StackedImageSource extends StatefulWidget {
  const StackedImageSource({
    super.key,
    required this.data,
    required this.width,
    required this.height,
    required this.channels,
    this.stretch,
    this.stretchAsync,
    this.filterKey,
    this.revision = 0,
    this.maxDimension = 2048,
    required this.colors,
    required this.builder,
  }) : assert(
         stretch != null || stretchAsync != null,
         'Either stretch or stretchAsync must be provided',
       );

  final Uint16List data;
  final int width;
  final int height;
  final int channels;
  final StackedPreviewStretch? stretch;
  final StackedPreviewStretchAsync? stretchAsync;
  final String? filterKey;
  final int revision;
  final int maxDimension;
  final SkotiqColors colors;
  final Widget Function(BuildContext context, ui.Image image) builder;

  @override
  State<StackedImageSource> createState() => _StackedImageSourceState();
}

class _StackedImageSourceState extends State<StackedImageSource> {
  ui.Image? _image;
  bool _decoding = false;
  bool _pendingRebuild = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scheduleBuild();
  }

  @override
  void didUpdateWidget(StackedImageSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.data, oldWidget.data) ||
        widget.width != oldWidget.width ||
        widget.height != oldWidget.height ||
        widget.channels != oldWidget.channels ||
        widget.filterKey != oldWidget.filterKey ||
        widget.revision != oldWidget.revision ||
        widget.maxDimension != oldWidget.maxDimension ||
        widget.stretch != oldWidget.stretch ||
        widget.stretchAsync != oldWidget.stretchAsync) {
      _scheduleBuild();
    }
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  void _scheduleBuild() {
    _generation++;
    if (_decoding) {
      _pendingRebuild = true;
      return;
    }
    unawaited(_build());
  }

  Future<void> _build() async {
    _decoding = true;
    _pendingRebuild = false;
    final gen = _generation;

    final int w = widget.width;
    final int h = widget.height;
    final int pixels = w * h;
    final int samples = widget.channels == 3 ? 3 : 1;
    if (pixels <= 0 || widget.data.length < pixels * samples) {
      _decoding = false;
      return;
    }
    try {
      final StretchedPreviewFrame stretched;
      if (widget.stretchAsync != null) {
        stretched = await widget.stretchAsync!(
          width: w,
          height: h,
          data: widget.data,
          channels: samples,
          maxDimension: widget.maxDimension,
          filterKey: widget.filterKey,
        );
      } else {
        final rgba = widget.stretch!(
          width: w,
          height: h,
          data: widget.data,
          channels: samples,
        );
        stretched = StretchedPreviewFrame(
          width: w,
          height: h,
          channels: samples,
          rgba: rgba,
        );
      }

      if (!mounted || gen != _generation) return;

      final outW = stretched.width;
      final outH = stretched.height;
      final expectedBytes = outW * outH * 4;
      if (outW <= 0 || outH <= 0 || stretched.rgba.length < expectedBytes) {
        Log.warning(
          '[LiveStackCanvas] Stretched stack is ${stretched.rgba.length} '
          'bytes, expected $expectedBytes',
          source: 'LiveStackCanvas',
        );
        return;
      }

      final buffer = await ui.ImmutableBuffer.fromUint8List(stretched.rgba);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: outW,
        height: outH,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();

      if (!mounted || gen != _generation) {
        frame.image.dispose();
      } else {
        setState(() {
          _image?.dispose();
          _image = frame.image;
        });
      }
    } catch (error) {
      Log.warning(
        '[LiveStackCanvas] Error building the stacked image: $error',
        source: 'LiveStackCanvas',
        error: error,
      );
    } finally {
      _decoding = false;
      if (mounted && _pendingRebuild) {
        _pendingRebuild = false;
        unawaited(_build());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return Container(
        color: widget.colors.isRedNight
            ? widget.colors.background
            : SkotiqColors.dark.background,
        child: Center(
          child: SkotiqImageSurface(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 20),
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Builder(
                  builder: (BuildContext inner) => Text(
                    'Rendering the stack…',
                    style: SkotiqTypography.caption.copyWith(
                      color: inner.skotiqColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return widget.builder(context, image);
  }
}
