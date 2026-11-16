// The saved-frame viewer: a gallery's frame on the whole window at full
// resolution, with the previous and next frames a key away. The frame is drawn
// by SavedFrameView, the same view Tonight's stage shows a strip frame in.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';
import '../image_preview/frame_overlay_controls.dart';
import '../image_preview/preview_display_scale.dart';
import 'saved_frame_view.dart';

/// One frame of a gallery, as the viewer names it.
@immutable
class SavedFrameEntry {
  const SavedFrameEntry({
    required this.frame,
    required this.title,
    this.time,
    this.status,
    this.accepted,
    this.onDetails,
  });

  final SavedFrameRef frame;

  /// "#43 · L 30 s", or the file name.
  final String title;
  final String? time;

  /// "Kept · HFR 1.86 · 45 stars".
  final String? status;

  /// True kept, false rejected, null never graded.
  final bool? accepted;

  /// Opens the gallery's own details of the frame, when it has them.
  final VoidCallback? onDetails;
}

class SavedFrameViewer extends ConsumerStatefulWidget {
  const SavedFrameViewer({
    super.key,
    required this.frames,
    required this.initialIndex,
  });

  final List<SavedFrameEntry> frames;
  final int initialIndex;

  /// Shows [frames] over the whole window, starting at [initialIndex].
  static Future<void> show(
    BuildContext context, {
    required List<SavedFrameEntry> frames,
    required int initialIndex,
  }) {
    return Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: SkotiqTokens.durationFast,
        pageBuilder: (_, __, ___) =>
            SavedFrameViewer(frames: frames, initialIndex: initialIndex),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  ConsumerState<SavedFrameViewer> createState() => _SavedFrameViewerState();
}

class _SavedFrameViewerState extends ConsumerState<SavedFrameViewer> {
  static const double _inset = 10;

  late int _index = widget.initialIndex.clamp(0, widget.frames.length - 1);

  /// The viewer's own zoom, pan and star overlay, apart from Imaging's.
  final ImagingViewerStateNotifier _view = ImagingViewerStateNotifier();
  ImagingViewerState _viewState = const ImagingViewerState();
  late final void Function() _unlisten;

  @override
  void initState() {
    super.initState();
    _unlisten = _view.addListener(
      (state) => setState(() => _viewState = state),
      fireImmediately: false,
    );
  }

  @override
  void dispose() {
    _unlisten();
    _view.dispose();
    super.dispose();
  }

  void _step(int by) {
    final next = _index + by;
    if (next < 0 || next >= widget.frames.length) return;
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final entry = widget.frames[_index];
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: colors.isRedNight
              ? colors.background
              : SkotiqColors.dark.background,
          body: SafeArea(
            child: SkotiqImageSurface(
              child: ClipRect(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final viewport = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return Stack(
                      children: <Widget>[
                        Positioned.fill(
                          child: SavedFrameView(
                            frame: entry.frame,
                            viewport: viewport,
                            zoomLevel: _viewState.zoomLevel,
                            panOffset: _viewState.panOffset,
                            onPan: _view.pan,
                            showStars: _viewState.showStarOverlay,
                            showCatalog: ref.watch(
                              catalogOverlayEnabledProvider,
                            ),
                            semanticsLabel: context.l10n.text(
                              'nightCtrPreviewSemantics',
                              params: <String, String>{'frame': entry.title},
                            ),
                          ),
                        ),
                        Positioned(
                          left: _inset,
                          right: _inset,
                          top: _inset,
                          child: _TopBar(
                            entry: entry,
                            position: _index + 1,
                            count: widget.frames.length,
                          ),
                        ),
                        Positioned(
                          left: _inset,
                          right: _inset,
                          bottom: _inset,
                          child: _BottomBar(
                            entry: entry,
                            viewport: viewport,
                            view: _view,
                            viewState: _viewState,
                            onPrevious: _index > 0 ? () => _step(-1) : null,
                            onNext: _index < widget.frames.length - 1
                                ? () => _step(1)
                                : null,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.entry,
    required this.position,
    required this.count,
  });

  final SavedFrameEntry entry;
  final int position;
  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accepted = entry.accepted;
    final details = entry.onDetails;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Flexible(
          child: Align(
            alignment: Alignment.topLeft,
            child: FramePill(
              text: FramePillText(
                title: entry.title,
                time: entry.time,
                status: entry.status,
                statusTone: switch (accepted) {
                  true => FramePillTone.good,
                  false => FramePillTone.bad,
                  null => FramePillTone.neutral,
                },
                dot: switch (accepted) {
                  true => FramePillTone.good,
                  false => FramePillTone.bad,
                  null => FramePillTone.muted,
                },
              ),
            ),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        if (count > 1) ...<Widget>[
          FramePill(
            text: FramePillText(
              title: l10n.text(
                'savedFramePosition',
                params: <String, String>{
                  'position': '$position',
                  'count': '$count',
                },
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
        ],
        if (details != null) ...<Widget>[
          FrameViewButton(
            label: l10n.text('savedFrameDetails'),
            icon: LucideIcons.info,
            onPressed: details,
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
        ],
        FrameViewButton(
          label: l10n.text('savedFrameClose'),
          tooltip: l10n.text('savedFrameCloseTip'),
          icon: LucideIcons.x,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}

class _BottomBar extends ConsumerWidget {
  const _BottomBar({
    required this.entry,
    required this.viewport,
    required this.view,
    required this.viewState,
    required this.onPrevious,
    required this.onNext,
  });

  final SavedFrameEntry entry;
  final Size viewport;
  final ImagingViewerStateNotifier view;
  final ImagingViewerState viewState;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final load = ref.watch(savedFrameProvider(entry.frame));
    final image = load is SavedFrameReady ? load.image : null;
    final status = load is SavedFrameReady && viewState.showStarOverlay
        ? starOverlayPill(
            l10n,
            ref.watch(savedFrameStarsProvider(load.localPath)),
          )
        : savedFrameLoadPill(l10n, load);
    final annotate = ref.watch(catalogOverlayEnabledProvider);
    final previous = onPrevious;
    final next = onNext;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        if (previous != null || next != null) ...<Widget>[
          FrameViewButton(
            label: l10n.text('savedFramePrevious'),
            tooltip: l10n.text('savedFramePreviousTip'),
            icon: LucideIcons.chevronLeft,
            onPressed: previous,
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
          FrameViewButton(
            label: l10n.text('savedFrameNext'),
            tooltip: l10n.text('savedFrameNextTip'),
            icon: LucideIcons.chevronRight,
            onPressed: next,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
        ],
        Flexible(
          child: Align(
            alignment: Alignment.bottomLeft,
            child: FramePill(text: status, liveRegion: true),
          ),
        ),
        if (image != null) ...<Widget>[
          const SizedBox(width: SkotiqTokens.spaceSm),
          Wrap(
            spacing: SkotiqTokens.spaceXs,
            children: <Widget>[
              FrameViewButton(
                label: l10n.text('nightCtrViewStars'),
                tooltip: l10n.text('nightCtrViewStarsTip'),
                selected: viewState.showStarOverlay,
                onPressed: view.toggleStarOverlay,
              ),
              FrameViewButton(
                label: l10n.text('nightCtrViewAnnotate'),
                tooltip: l10n.text('nightCtrViewAnnotateTip'),
                selected: annotate,
                onPressed: () => ref
                    .read(catalogOverlayEnabledProvider.notifier)
                    .state = !annotate,
              ),
              _ZoomButton(
                image: Size(image.width.toDouble(), image.height.toDouble()),
                viewport: viewport,
                view: view,
                viewState: viewState,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.image,
    required this.viewport,
    required this.view,
    required this.viewState,
  });

  final Size image;
  final Size viewport;
  final ImagingViewerStateNotifier view;
  final ImagingViewerState viewState;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final fitScale = previewFitScale(viewportSize: viewport, imageSize: image);
    final native = (fitScale * viewState.zoomLevel - 1).abs() < 0.001 &&
        viewState.zoomLevel != 1.0;
    return FrameViewButton(
      label: l10n.text(native ? 'nightCtrViewFit' : 'nightCtrViewZoom'),
      tooltip: l10n.text(native ? 'nightCtrViewFitTip' : 'nightCtrViewZoomTip'),
      onPressed:
          native ? view.fitToWindow : () => view.zoom1to1(fitScale: fitScale),
    );
  }
}
