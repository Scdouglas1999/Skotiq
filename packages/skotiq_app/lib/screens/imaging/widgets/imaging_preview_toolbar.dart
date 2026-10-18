import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/catalog_overlay_widget.dart'
    show CatalogOverlayPopover;
import '../../../widgets/tutorial_keys/imaging_keys.dart';
import 'annotation_panel.dart' show annotationPanelVisibleProvider;
import 'custom_annotation_drawing.dart'
    show customAnnotationDrawModeActiveProvider, toggleAnnotationDrawPalette;
import 'depthlock/depthlock_region_layer.dart'
    show
        cancelDepthLockRegionTool,
        depthLockGoalOverlayVisibleProvider,
        depthLockRegionToolActiveProvider;
import 'depthlock/depthlock_selection.dart' show depthLockSelectionProvider;
import 'live_preview_area.dart' show previewReadoutsVisibleProvider;
import 'meridian_flip_countdown_banner.dart' show MeridianFlipChip;
import 'preview_display_scale.dart' show previewDisplayScaleProvider;
import 'preview_histogram_visibility.dart';

/// The 44 px viewer toolbar above the canvas (06 §Imaging).
///
/// Left: the frame's mono meta line — size, binning, zoom and sky brightness,
/// values loud and their labels quiet — then the calm meridian-flip chip. Right: one [SkotiqToolbar] with the
/// named actions first (Overlays, Annotate) and the view glyphs after it.
///
/// Nothing here floats over the image. The canvas below runs edge to edge and
/// carries only glass.
class ImagingPreviewToolbar extends ConsumerStatefulWidget {
  const ImagingPreviewToolbar({
    super.key,
    required this.showCrosshair,
    required this.showStarOverlay,
    required this.isStoppingCapture,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFitToWindow,
    required this.onZoom1to1,
    required this.onAbortCapture,
    required this.onToggleCrosshair,
    required this.onToggleStarOverlay,
    this.onFullscreen,
  });

  final bool showCrosshair;
  final bool showStarOverlay;

  /// A manual capture abort is already in flight, so the abort control has
  /// nothing left to do — pressing it again would only re-issue a cancel for an
  /// exposure the app has already given up on.
  final bool isStoppingCapture;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFitToWindow;
  final VoidCallback onZoom1to1;
  final VoidCallback onAbortCapture;
  final VoidCallback onToggleCrosshair;
  final VoidCallback onToggleStarOverlay;

  /// Opens the frame in the fullscreen viewer. Null when there is no frame.
  final VoidCallback? onFullscreen;

  /// The bar's height (06 §Imaging: "A 44 px viewer toolbar on top").
  static const double height = 44;

  @override
  ConsumerState<ImagingPreviewToolbar> createState() =>
      _ImagingPreviewToolbarState();
}

class _ImagingPreviewToolbarState extends ConsumerState<ImagingPreviewToolbar> {
  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final currentImage = ref.watch(currentImageProvider);
    final exposureSettings = ref.watch(exposureSettingsProvider);
    final exposureProgress = ref.watch(exposureProgressProvider);
    final scienceSnapshot = ref.watch(currentScienceSnapshotProvider);
    final latestTransparency = scienceSnapshot.$2;
    final showAbort = !widget.isStoppingCapture &&
        exposureProgress.remaining > 0 &&
        !exposureProgress.isDownloading;

    final meta = _ViewerMeta(
      // Null renders "—", never "--- × ---" (02 rule 3).
      resolution: currentImage == null
          ? null
          : '${currentImage.width} × ${currentImage.height}',
      binning: exposureSettings.binning,
      // Screen px per image px, as measured by the preview itself. The viewer
      // state's zoom is a fit-relative multiplier, so printing it as a
      // percentage labelled a 4144 px frame letterboxed into ~990 px "100%".
      zoom: '${(ref.watch(previewDisplayScaleProvider) * 100).round()}%',
      sky: latestTransparency?.qualityBucket,
    );

    // No `overflow:` group. SkotiqToolbar's overflow fit lays out BOTH
    // candidate bars and paints one, so every labelled action appears twice in
    // the widget and semantics trees — two "Overlays" buttons to a screen
    // reader. This bar scrolls instead (below), which puts one node per
    // control on screen at every width.
    //
    // Deviation from `mockups/imaging.html`, recorded in notes.md: the mockup
    // draws five view glyphs; Skotiq also has 1:1 zoom and the catalog
    // overlay's magnitude settings, which exist today and have nowhere else to
    // live, so they ride in the same groups rather than being deleted.
    final toolbar = SkotiqToolbar(
      groups: <List<Widget>>[
        <Widget>[
          OverlaysMenuButton(
            showCrosshair: widget.showCrosshair,
            showStarOverlay: widget.showStarOverlay,
            onToggleCrosshair: widget.onToggleCrosshair,
            onToggleStarOverlay: widget.onToggleStarOverlay,
          ),
          _AnnotateButton(enabled: currentImage != null),
          const _DepthLockRegionButton(),
        ],
        <Widget>[
          SkotiqIconButton(
            icon: SkotiqIcons.crosshair,
            tooltip: 'Crosshair',
            size: IconButtonSize.sm,
            selected: widget.showCrosshair,
            onPressed: widget.onToggleCrosshair,
          ),
          SkotiqIconButton(
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
            icon: SkotiqIcons.collapse,
            tooltip: '1:1 zoom',
            size: IconButtonSize.sm,
            onPressed: widget.onZoom1to1,
          ),
          SkotiqIconButton(
            icon: LucideIcons.scan,
            tooltip: 'Fit to window',
            size: IconButtonSize.sm,
            onPressed: widget.onFitToWindow,
          ),
          SkotiqIconButton(
            icon: LucideIcons.maximize,
            tooltip: 'Fullscreen',
            size: IconButtonSize.sm,
            onPressed: widget.onFullscreen,
          ),
        ],
        <Widget>[
          const _CatalogOverlaySettingsButton(),
          if (showAbort)
            SkotiqIconButton(
              key: ImagingTutorialKeys.abortBtn,
              icon: SkotiqIcons.close,
              tooltip: 'Abort capture',
              size: IconButtonSize.sm,
              color: colors.error,
              onPressed: widget.onAbortCapture,
            ),
        ],
      ],
    );

    return Container(
      height: ImagingPreviewToolbar.height,
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
      ),
      // ONE layout, and no width threshold — because no constant can be right
      // here. Every child except the meta line is intrinsically sized, so
      // whether they fit depends on runtime content: the frame's dimensions,
      // the sky reading, the locale, the user's text scale. IntrinsicWidth
      // asks the layout what it actually needs; ConstrainedBox(minWidth)
      // lets the bar fill the viewport when there IS slack so the actions stay
      // pinned trailing; and when the natural width exceeds the viewport it
      // scrolls. Nothing is ever clipped, at any width.
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: IntrinsicWidth(
                child: Row(
                  key: ImagingTutorialKeys.zoomControls,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    meta,
                    // The calm meridian-flip countdown lives here, in the
                    // toolbar row, instead of a full-width banner over the
                    // canvas. Self-hides while no flip is armed or while the
                    // flip needs attention (the banner takes over then).
                    const MeridianFlipChip(),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    const Spacer(),
                    toolbar,
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// `6248 × 4176 · Bin 1×1 · Zoom 55% · Sky 19.8 mag/"2` — mono 12, values in
/// `textPrimary`, their qualifiers in `textSecondary`, 14 px apart.
class _ViewerMeta extends StatelessWidget {
  const _ViewerMeta({
    required this.resolution,
    required this.binning,
    required this.zoom,
    required this.sky,
  });

  final String? resolution;
  final String binning;
  final String zoom;
  final String? sky;

  /// Gap between the segments (`observatory.css` `.vtool .meta`).
  static const double segmentGap = 14;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final label = SkotiqTypography.monoCaption.copyWith(
      color: colors.textSecondary,
    );
    final value = SkotiqTypography.monoCaption.copyWith(
      color: colors.textPrimary,
      fontWeight: FontWeight.w500,
    );
    final muted = SkotiqTypography.monoCaption.copyWith(
      color: colors.textMuted,
    );

    // Plain `Text` per part rather than one `Text.rich`: a rich span carries no
    // `data`, so the zoom readout — the one thing on this bar a test and a
    // screen reader both go looking for by its value — became unfindable.
    Widget segment(String? prefix, String? text, [String? suffix]) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (prefix != null) ...<Widget>[
            Text(prefix, style: label, maxLines: 1, softWrap: false),
            const SizedBox(width: SkotiqTokens.spaceXs),
          ],
          Text(
            text ?? '\u2014',
            style: text == null ? muted : value,
            maxLines: 1,
            softWrap: false,
          ),
          if (suffix != null) ...<Widget>[
            const SizedBox(width: SkotiqTokens.spaceXs),
            Text(suffix, style: label, maxLines: 1, softWrap: false),
          ],
        ],
      );
    }

    // A segment with no value drops out rather than saying "Sky —": the sky
    // reading only exists once a frame has been photometrically calibrated,
    // which most frames never are, so a permanent slot for it was a permanent
    // dash. The frame size and the zoom drop out with no frame on the canvas
    // for the same reason.
    final parts = <Widget>[
      if (resolution != null) segment(null, resolution),
      segment('Bin', binning),
      if (resolution != null) segment('Zoom', zoom),
      // ASCII quote, not U+2033: the bundled fonts have no prime glyph and
      // an arcsecond mark rendered as a tofu box on the toolbar.
      if (sky != null) segment('Sky', sky, 'mag/sq"'),
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < parts.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: segmentGap),
          parts[i],
        ],
      ],
    );
  }
}

/// The "Annotate" toggle. Flips [customAnnotationDrawModeActiveProvider] via
/// [toggleAnnotationDrawPalette] so the docked drawing palette appears at the
/// bottom of the canvas only while drawing is active.
class _AnnotateButton extends ConsumerWidget {
  const _AnnotateButton({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(customAnnotationDrawModeActiveProvider);
    // A ghost button has no on-state in the sheet, so the toggle publishes it
    // as semantics; on screen the docked drawing palette IS the on-state.
    return Semantics(
      toggled: active,
      child: SkotiqButton(
        label: 'Annotate',
        icon: SkotiqIcons.tag,
        size: ButtonSize.small,
        variant: ButtonVariant.ghost,
        semanticsHint: enabled ? null : 'Available once a frame is on screen',
        onPressed: enabled
            ? () {
                // The DepthLock region tool captures the same drag, so only
                // one of the two may own the canvas at a time.
                cancelDepthLockRegionTool(ref);
                toggleAnnotationDrawPalette(ref);
              }
            : null,
      ),
    );
  }
}

/// Enters and leaves the DepthLock region tool.
///
/// It sits beside Annotate because it is the same kind of thing — a mode in
/// which a drag on the canvas draws rather than pans — and because the two
/// must be mutually exclusive: entering one leaves the other, so a drag can
/// only ever mean one thing.
class _DepthLockRegionButton extends ConsumerWidget {
  const _DepthLockRegionButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(depthLockRegionToolActiveProvider);
    // The same answer the DepthLock panel gives, so the button is never live
    // over a frame that cannot anchor a region — and when it is not, it says
    // why in the hint rather than doing nothing.
    final selection = ref.watch(depthLockSelectionProvider);
    final enabled = selection.canSelect;
    return Semantics(
      toggled: active,
      child: SkotiqButton(
        label: 'Mark region',
        icon: SkotiqIcons.crosshair,
        size: ButtonSize.small,
        variant: ButtonVariant.ghost,
        semanticsHint: enabled
            ? 'Drag two boxes on the frame to define a DepthLock goal'
            : selection.blocker,
        onPressed: enabled
            ? () {
                if (active) {
                  cancelDepthLockRegionTool(ref);
                  return;
                }
                // Leave any annotation tool first: two layers capturing the
                // same drag would each draw half a shape.
                if (ref.read(customAnnotationDrawModeActiveProvider)) {
                  toggleAnnotationDrawPalette(ref);
                }
                ref.read(depthLockRegionToolActiveProvider.notifier).state =
                    true;
              }
            : null,
      ),
    );
  }
}

/// The single labelled "Overlays" entry point. Tapping opens a compact popover
/// of labelled checkbox rows, one per overlay.
class OverlaysMenuButton extends ConsumerStatefulWidget {
  const OverlaysMenuButton({
    super.key,
    required this.showCrosshair,
    required this.showStarOverlay,
    required this.onToggleCrosshair,
    required this.onToggleStarOverlay,
  });

  final bool showCrosshair;
  final bool showStarOverlay;
  final VoidCallback onToggleCrosshair;
  final VoidCallback onToggleStarOverlay;

  @override
  ConsumerState<OverlaysMenuButton> createState() => _OverlaysMenuButtonState();
}

class _OverlaysMenuButtonState extends ConsumerState<OverlaysMenuButton> {
  /// Opens the menu from the button's own `onPressed`, so the control the
  /// operator sees is the control that acts. The button used to be wrapped in
  /// an `IgnorePointer` with an empty callback, leaving `PopupMenuButton`'s
  /// own detector to catch the tap — a button that, read on its own, did
  /// nothing. Per-instance rather than static: two toolbars alive at once (a
  /// route transition) would otherwise share one key, and a release build
  /// silently drops the second widget claiming it.
  final GlobalKey<PopupMenuButtonState<int>> _menuKey =
      GlobalKey<PopupMenuButtonState<int>>();

  bool get showCrosshair => widget.showCrosshair;
  bool get showStarOverlay => widget.showStarOverlay;
  VoidCallback get onToggleCrosshair => widget.onToggleCrosshair;
  VoidCallback get onToggleStarOverlay => widget.onToggleStarOverlay;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final annotationSettings =
        ref.watch(annotationSettingsProvider).valueOrNull;
    final gridType = annotationSettings?.gridType ?? GridType.none;
    final annotationPanelVisible = ref.watch(annotationPanelVisibleProvider);
    final catalogEnabled = ref.watch(catalogOverlayEnabledProvider);
    final scienceMode = ref.watch(scienceModeStateProvider);
    final scienceHudVisible = scienceMode.scienceHudVisible;
    final readoutsVisible = ref.watch(previewReadoutsVisibleProvider);
    final histogramVisible = ref.watch(previewHistogramVisibleProvider);
    final depthLockGoalsVisible =
        ref.watch(depthLockGoalOverlayVisibleProvider);

    // Undeclared, this publishes as `panel: Overlays [DISABLED]` — a live popup
    // trigger announced as an inert panel — because PopupMenuButton's InkWell
    // contributes a tap action but no button role or enabled state, and the
    // label inside contributes a second, separate named node. One control, one
    // node, with the role and the state it actually has.
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: true,
        label: 'Overlays',
        child: PopupMenuButton<int>(
          key: _menuKey,
          // Stays enabled: `enabled: false` publishes the node as
          // `panel: Overlays [DISABLED]`, and the a11y contract for this
          // control is an enabled button. The button below wins the gesture
          // arena against this widget's own InkWell and opens the menu through
          // the key, so only one menu can open from one tap either way.
          tooltip: 'Overlays',
          position: PopupMenuPosition.under,
          offset: const Offset(0, SkotiqTokens.spaceXs),
          color: colors.surfaceElevated,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          constraints: const BoxConstraints(minWidth: 248, maxWidth: 296),
          shape: RoundedRectangleBorder(
            borderRadius: SkotiqTokens.borderRadiusXl,
            side: BorderSide(color: colors.border),
          ),
          itemBuilder: (BuildContext context) {
            return <PopupMenuEntry<int>>[
              _overlayItem(
                colors: colors,
                value: 0,
                icon: SkotiqIcons.crosshair,
                label: 'Crosshair',
                active: showCrosshair,
                onTap: onToggleCrosshair,
              ),
              _overlayItem(
                colors: colors,
                value: 1,
                icon: gridType == GridType.celestial
                    ? SkotiqIcons.globe
                    : SkotiqIcons.grid,
                label: 'Grid',
                subtitle: switch (gridType) {
                  GridType.none =>
                    annotationSettings == null ? 'Settings unavailable' : 'Off',
                  GridType.pixel => 'Pixel',
                  GridType.celestial => 'RA / Dec',
                },
                active: gridType != GridType.none,
                onTap: annotationSettings == null
                    ? null
                    : () => ref
                        .read(annotationSettingsProvider.notifier)
                        .cycleGridType(),
              ),
              _overlayItem(
                colors: colors,
                value: 2,
                icon: SkotiqIcons.sparkle,
                label: 'Star detection',
                active: showStarOverlay,
                onTap: onToggleStarOverlay,
              ),
              _overlayItem(
                colors: colors,
                value: 3,
                icon: SkotiqIcons.list,
                label: 'Object annotations',
                active: annotationPanelVisible,
                onTap: () => ref
                    .read(annotationPanelVisibleProvider.notifier)
                    .state = !annotationPanelVisible,
              ),
              _overlayItem(
                colors: colors,
                value: 4,
                icon: SkotiqIcons.target,
                label: 'Catalog overlay',
                active: catalogEnabled,
                onTap: () => ref
                    .read(catalogOverlayEnabledProvider.notifier)
                    .state = !catalogEnabled,
              ),
              _overlayItem(
                colors: colors,
                value: 5,
                icon: SkotiqIcons.science,
                label: 'Science HUD',
                active: scienceHudVisible,
                onTap: () => ref.read(scienceModeStateProvider.notifier).state =
                    scienceMode.copyWith(
                  scienceHudVisible: !scienceHudVisible,
                ),
              ),
              _overlayItem(
                colors: colors,
                value: 6,
                icon: SkotiqIcons.target,
                label: 'DepthLock goals',
                subtitle: 'Marked regions and their state',
                active: depthLockGoalsVisible,
                onTap: () => ref
                    .read(depthLockGoalOverlayVisibleProvider.notifier)
                    .state = !depthLockGoalsVisible,
              ),
              // The frame readouts are explicit and default ON — nothing on
              // the canvas hides itself on a timer. This row is how the
              // clean-frame view is asked for.
              _overlayItem(
                colors: colors,
                value: 7,
                icon: SkotiqIcons.activity,
                label: 'Readouts',
                subtitle: 'Frame info, HFR and stars',
                active: readoutsVisible,
                onTap: () => ref
                    .read(previewReadoutsVisibleProvider.notifier)
                    .state = !readoutsVisible,
              ),
              // Opt-in and remembered: the histogram is a setup reading, so
              // it stays off the frame until asked for.
              _overlayItem(
                colors: colors,
                value: 8,
                icon: LucideIcons.barChart3,
                label: 'Histogram',
                active: histogramVisible,
                onTap: () => ref
                    .read(previewHistogramVisibleProvider.notifier)
                    .setVisible(!histogramVisible),
              ),
            ];
          },
          // Excluded so the label does not publish a SECOND "Overlays" node
          // beside the one the Semantics wrapper above owns.
          child: ExcludeSemantics(
            child: SkotiqButton(
              label: 'Overlays',
              icon: SkotiqIcons.layers,
              size: ButtonSize.small,
              variant: ButtonVariant.ghost,
              onPressed: () => _menuKey.currentState?.showButtonMenu(),
            ),
          ),
        ),
      ),
    );
  }

  PopupMenuItem<int> _overlayItem({
    required SkotiqColors colors,
    required int value,
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback? onTap,
    String? subtitle,
  }) {
    return PopupMenuItem<int>(
      value: value,
      enabled: onTap != null,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: 2,
      ),
      child: _OverlayMenuRow(
        colors: colors,
        icon: icon,
        label: label,
        subtitle: subtitle,
        active: active,
      ),
    );
  }
}

/// A single labelled checkbox row inside the Overlays popover.
class _OverlayMenuRow extends StatelessWidget {
  const _OverlayMenuRow({
    required this.colors,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.active,
  });

  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool active;

  @override
  Widget build(BuildContext context) {
    // The description stacks UNDER the label rather than sitting beside it.
    // Side by side, the description took its full intrinsic width first and
    // left the label a sliver, so "Readouts" rendered as "Rea" / "dou" broken
    // across two lines.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(
        children: <Widget>[
          // Check box — communicates on/off without button chrome.
          Icon(
            active ? LucideIcons.checkSquare : LucideIcons.square,
            size: SkotiqTokens.iconSm,
            color: active ? colors.primary : colors.textMuted,
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Icon(
            icon,
            size: SectionTitle.iconSize,
            color: active ? colors.primary : colors.textSecondary,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings-only catalog-overlay control: a glyph that opens the catalog
/// magnitude / kind popover. The overlay's on/off lives in the Overlays menu,
/// so this exposes *only* the deeper configuration.
class _CatalogOverlaySettingsButton extends ConsumerWidget {
  const _CatalogOverlaySettingsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final magnitudeLimit = ref.watch(catalogOverlayMagnitudeLimitProvider);
    return PopupMenuButton<String>(
      tooltip: 'Catalog overlay settings, magnitude '
          '${magnitudeLimit.toStringAsFixed(0)} and brighter',
      position: PopupMenuPosition.under,
      offset: const Offset(0, SkotiqTokens.spaceXs),
      color: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: SkotiqTokens.borderRadiusXl,
        side: BorderSide(color: colors.border),
      ),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        _CatalogOverlayPopoverEntry(
          child: CatalogOverlayPopover(colors: colors),
        ),
      ],
      icon: Icon(
        SkotiqIcons.target,
        color: colors.textMuted,
        size: SkotiqTokens.iconSm,
      ),
      splashRadius: SkotiqTokens.iconSm,
      padding: EdgeInsets.zero,
      // `PopupMenuButton.constraints` sizes the OPENED MENU, not this trigger —
      // a 28 px tight box there was what clipped the popover. The 28 px square
      // is set on the IconButton itself instead; `shrinkWrap` keeps Material's
      // padded touch target from re-inflating it on desktop.
      style: IconButton.styleFrom(
        minimumSize: const Size.square(SkotiqTokens.iconButtonSizeSm),
        fixedSize: const Size.square(SkotiqTokens.iconButtonSizeSm),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// Carries the live [CatalogOverlayPopover] inside the popup route.
///
/// A plain [PopupMenuItem] cannot host it: `enabled: false` halves the
/// opacity of every icon inside and merges the whole panel into a single
/// disabled `menuItem` semantics node — the switches and dropdown go dark and
/// lose their own accessible names — while `enabled: true` lets the item's
/// InkWell pop the route on any tap that misses a control. This entry hands
/// the child to the menu untouched, so its controls keep their own semantics
/// and the panel stays open while they are adjusted.
class _CatalogOverlayPopoverEntry extends PopupMenuEntry<String> {
  const _CatalogOverlayPopoverEntry({required this.child});

  final Widget child;

  /// Nominal only: the route measures every entry at layout time
  /// (`_PopupMenuRoute.itemSizes`), so no entry height is ever read here.
  @override
  double get height => 0;

  /// The panel returns no selectable value — it mutates providers directly.
  @override
  bool represents(String? value) => false;

  @override
  State<_CatalogOverlayPopoverEntry> createState() =>
      _CatalogOverlayPopoverEntryState();
}

class _CatalogOverlayPopoverEntryState
    extends State<_CatalogOverlayPopoverEntry> {
  @override
  Widget build(BuildContext context) {
    // `_PopupMenu` wraps its entries in `IntrinsicWidth(stepWidth: 56)`, so
    // every entry is tightened to the same 56-stepped width. The popover's
    // `clampPanelWidth` answer (200–240) is not a 56 multiple; aligning the
    // child inside the entry keeps the card at its designed width instead of
    // being stretched to the menu's.
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: widget.child,
    );
  }
}
