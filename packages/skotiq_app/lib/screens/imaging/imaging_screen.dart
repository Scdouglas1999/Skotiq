import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../services/manual_capture_controller.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/transient_bottom_inset.dart';
import 'widgets/fullscreen_image_viewer.dart';
import 'widgets/imaging_capture_bar.dart';
import 'widgets/imaging_preview_toolbar.dart';
import 'widgets/imaging_view_prefs.dart';
import 'widgets/imaging_session_frames.dart';
import 'widgets/depthlock/depthlock_commit_host.dart';
import 'widgets/depthlock/depthlock_hint.dart';
import 'widgets/depthlock/depthlock_selection.dart'
    show DepthLockCanvas, depthLockCanvasProvider;
import 'widgets/live_stack_canvas.dart';
import 'widgets/depthlock/depthlock_region_layer.dart'
    show depthLockRegionToolActiveProvider;
import 'widgets/imaging_side_panel.dart';
import 'widgets/imaging_status_strip.dart';
import 'widgets/live_preview_area.dart';
import 'widgets/meridian_flip_countdown_banner.dart';
import 'widgets/preview_display_scale.dart' show previewFitScaleProvider;
import 'widgets/stacking_panel.dart';
import '../../tours/tour_target.dart';

part 'imaging_screen/imaging_screen_actions.dart';

/// The Imaging screen's top-level tabs (06 §Imaging).
enum ImagingTab {
  /// The viewer: canvas, glass HUD, capture bar, side panel.
  liveView(label: 'Live view', icon: SkotiqIcons.image),

  /// The live stacker, promoted here from a side-panel tab.
  liveStack(label: 'Live stack', icon: SkotiqIcons.layers),

  /// Every frame this session has captured.
  sessionFrames(label: 'Session frames', icon: SkotiqIcons.history);

  const ImagingTab({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

class ImagingScreen extends ConsumerStatefulWidget {
  const ImagingScreen({super.key});

  @override
  ConsumerState<ImagingScreen> createState() => _ImagingScreenState();
}

class _ImagingScreenState extends ConsumerState<ImagingScreen> {
  ImagingTab _tab = ImagingTab.liveView;

  /// The page header's `panel-right` toggle.
  bool _sidePanelCollapsed = false;

  // Local snapshot state. The Loop is the host's (see
  // [manualCaptureControllerProvider]); every window reads it from
  // [manualLoopStatusProvider].
  bool _isSnapshotting = false;
  bool _singleCapturePreviewReady = false;
  bool _isStoppingSnapshot = false;
  ImagingService? _manualCaptureService;

  /// The controller of a loop this screen started, so leaving the screen
  /// stops it: a loop must not keep exposing after its Stop control goes.
  ManualCaptureController? _startedLoop;

  bool get _isLooping => ref.read(manualLoopStatusProvider).looping;

  /// A frame is being taken: this window's snapshot, or an exposure the
  /// other end of the link (or a sequence) is running.
  bool get _isSingleCapture =>
      _isSnapshotting ||
      (!_isLooping && ref.read(cameraStateProvider).isExposing);

  bool get _isStoppingCapture =>
      _isStoppingSnapshot || ref.read(manualLoopStatusProvider).stopping;

  /// Measured lift, in logical pixels, that a floating snackbar needs in order
  /// to clear the capture controls this layout is showing — the distance from
  /// their top edge to the bottom of the window, not their own height (the
  /// shell pins a status bar below this screen inside the same Scaffold). See
  /// [MeasuredBottomInsetReporter]. Zero until the first layout reports back.
  double _captureBarHeight = 0;

  void _setCaptureBarHeight(double height) {
    if (!mounted || _captureBarHeight == height) return;
    setState(() => _captureBarHeight = height);
  }

  void _update(VoidCallback callback) => setState(callback);

  @override
  void initState() {
    super.initState();
    // Initialize the annotation service to set up the image listener.
    // This must happen on first frame to have access to ref.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAnnotationService();
    });
  }

  @override
  void dispose() {
    if (_isSnapshotting && _manualCaptureService != null) {
      // A snapshot belongs to this screen. ImagingService targets the
      // backend/device admitted at start. ConsumerState.ref is already
      // invalid while Riverpod unmounts this element, so retain the service
      // admitted by the active action.
      _manualCaptureService!.cancelExposure();
    }
    // A Loop this screen started must not keep exposing after navigation
    // removes the Stop control the operator used to start it. Stopped after
    // the unmount, since stopping changes state this screen still watches.
    final startedLoop = _startedLoop;
    if (startedLoop != null) scheduleMicrotask(startedLoop.stop);
    super.dispose();
  }

  void _selectSection(int index) {
    if (index == ref.read(selectedImagingPanelProvider)) return;
    ref.read(selectedImagingPanelProvider.notifier).state = index;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(syncExposureFromProfileProvider);

    // The loop and any exposure in flight decide what Snapshot and Loop
    // offer, in this window and the one at the other end of the link.
    ref.watch(manualLoopStatusProvider);
    ref.watch(cameraStateProvider.select((s) => s.isExposing));

    final colors = context.skotiqColors;
    final selectedSection = ref.watch(selectedImagingPanelProvider);
    // The kept light frames: what Session frames shows as kept (flats and
    // darks of the night are not session frames).
    final frameCount = ref.watch(
      recentSessionFramesProvider.select(
        (frames) => frames
            .where((frame) => frame.settings.frameType == FrameType.light)
            .length,
      ),
    );
    final narrow = MediaQuery.sizeOf(context).width <
        ShellChromeMetrics.shellLayoutBreakpoint;

    // Snapshot / Loop / Exposure live in a bar pinned near the bottom of this
    // screen, and floating snackbars anchor to the same edge — so an error
    // toast drew an opaque bar across the lower half of the two most important
    // buttons on the screen. Declare the bar's measured height so every
    // snackbar raised from this subtree sits above it instead of on top of it.
    // Published through the notifier as well as the tree: this screen raises
    // its own "Capture failed: …" toast from `_ImagingScreenActions`, whose
    // context is the ImagingScreen element — an ANCESTOR of this widget — so an
    // inherited-only lookup returned null and the toast landed on top of
    // Snapshot / Loop, the exact defect this declaration exists to prevent.
    return DepthLockRegionCommitHost(
      child: TransientBottomInsetPublisher(
        inset: _captureBarHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            PageHeader(
              icon: SkotiqIcons.camera,
              title: 'Imaging',
              tabs: AdaptiveTabBar(
                key: TourTarget.imagingTabBar.key,
                horizontalPadding: 0,
                tabs: <AdaptiveTab>[
                  for (final ImagingTab tab in ImagingTab.values)
                    AdaptiveTab(
                      label: tab.label,
                      icon: tab.icon,
                      count: tab == ImagingTab.sessionFrames && frameCount > 0
                          ? '$frameCount'
                          : null,
                    ),
                ],
                selectedIndex: _tab.index,
                onSelected: (int index) {
                  final tab = ImagingTab.values[index];
                  setState(() => _tab = tab);
                  // A region belongs to the canvas it is drawn on, so the tab is
                  // what decides which frame DepthLock is talking about.
                  ref.read(depthLockCanvasProvider.notifier).state =
                      tab == ImagingTab.liveStack
                          ? DepthLockCanvas.liveStack
                          : DepthLockCanvas.liveView;
                },
              ),
              actions: <Widget>[
                SkotiqButton(
                  label: 'Immersive',
                  icon: SkotiqIcons.expand,
                  size: ButtonSize.small,
                  variant: ButtonVariant.ghost,
                  onPressed: _openImmersive,
                ),
                SkotiqIconButton(
                  icon: LucideIcons.panelRight,
                  tooltip: _sidePanelCollapsed
                      ? 'Show the controls panel'
                      : 'Hide the controls panel',
                  tooltipPosition: SkotiqTooltipPosition.bottom,
                  selected: !_sidePanelCollapsed,
                  onPressed: () => setState(
                    () => _sidePanelCollapsed = !_sidePanelCollapsed,
                  ),
                ),
              ],
              // Below the breakpoint there is no instrument bar (04 §5), so the
              // 28 px strip under the header is where the rig's state lives.
              bottom: narrow ? const ImagingStatusStrip() : null,
            ),

            // Meridian-flip banner, for a flip that needs attention only
            // (under ten minutes, or imminent). A calm countdown is the chip
            // in the viewer toolbar; with nothing urgent this is zero height
            // and never pushes the canvas down.
            const MeridianFlipCountdownBanner(),

            Expanded(
              child: switch (_tab) {
                ImagingTab.liveView =>
                  _liveView(colors, selectedSection, narrow),
                ImagingTab.liveStack => _liveStack(colors, narrow),
                ImagingTab.sessionFrames => const ImagingSessionFrames(),
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The Live stack tab: the stacked image on its own canvas, with the
  /// stacking controls beside it.
  ///
  /// The stack gets a canvas rather than a thumbnail because a region is
  /// marked ON it — the stacker registers every frame into the reference sub's
  /// pixel grid, so a box drawn here is a box in that sub's pixels, and a
  /// 180 px preview is not something anyone can mark a faint structure on.
  ///
  /// Narrow keeps the single scrolling column it has today, preview included:
  /// there is no room beside the controls for a canvas worth drawing on.
  Widget _liveStack(SkotiqColors colors, bool narrow) {
    if (narrow) return StackingPanel(colors: colors);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Expanded(child: LiveStackCanvas()),
        SizedBox(
          width: ShellChromeMetrics.sidePanelWidth,
          child: Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: colors.border)),
            ),
            padding: SidePanel.contentPadding,
            child: StackingPanel(colors: colors, showPreview: false),
          ),
        ),
      ],
    );
  }

  /// The viewer tab: toolbar, edge-to-edge canvas with its glass HUD, and the
  /// controls — a side panel on the right when there is room, a bottom sheet
  /// under the canvas when there is not.
  ///
  /// "When there is not" is a question about HEIGHT as well as width. A phone
  /// held in landscape reports a tablet-ish width (932) and a very short height
  /// (430, less again with a keyboard up), and the 44 px section strip is 318
  /// px of buttons that cannot fold. The decision is made on this pane's OWN
  /// constraints so an embedded or remote layout reflows too.
  Widget _liveView(SkotiqColors colors, int selectedSection, bool narrow) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final short = constraints.maxHeight.isFinite &&
            constraints.maxHeight < _shortViewportHeight;
        return _liveViewFor(
          colors,
          selectedSection,
          narrow || short,
          short: short,
        );
      },
    );
  }

  /// Below this the side-panel strip cannot fit, so the controls become a
  /// sheet (matching the rule the pre-Observatory layout used).
  static const double _shortViewportHeight = 500;

  Widget _liveViewFor(
    SkotiqColors colors,
    int selectedSection,
    bool narrow, {
    required bool short,
  }) {
    final viewer = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Below the shell breakpoint there is no viewer toolbar at all
        // (`mockups/png/narrow.png`): the canvas starts under the status strip
        // and a tap on the frame opens the fullscreen viewer. Forty-four pixels
        // of overlay toggles on a 390 px phone is chrome competing with the
        // photons for a screen that has none to spare.
        if (!narrow)
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // The shared shell can leave this pane shorter than the toolbar
              // while a route field owns the keyboard. In that state the
              // toolbar is not actionable; give its height to the canvas
              // instead of letting a fixed row overflow over the focused
              // controls pane.
              if (constraints.maxHeight < 96) return const SizedBox.shrink();
              ref.watch(imagingViewPrefsBinderProvider);
              return ImagingPreviewToolbar(
                showCrosshair:
                    ref.watch(imagingViewerStateProvider).showCrosshair,
                showStarOverlay:
                    ref.watch(imagingViewerStateProvider).showStarOverlay,
                isStoppingCapture: _isStoppingCapture,
                onZoomIn: _zoomIn,
                onZoomOut: _zoomOut,
                onFitToWindow: _fitToWindow,
                onZoom1to1: _zoom1to1,
                onAbortCapture: _abortCapture,
                onToggleCrosshair: _viewer.toggleCrosshair,
                onToggleStarOverlay: _viewer.toggleStarOverlay,
                onFullscreen: _openImmersive,
              );
            },
          ),
        // The one-time introduction, between the toolbar and the frame. It
        // takes no height once dismissed, and it is only offered while a
        // solved sub is up and no goal exists yet — see
        // `depthLockHintVisibleProvider`.
        if (!narrow)
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
        Expanded(child: _canvas(colors, narrow)),
      ],
    );

    if (narrow) {
      // Narrow: the canvas keeps the top of the screen and the controls become
      // a sheet with a horizontal section strip and two full-width buttons.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 3:2 on a tall phone — the sky keeps the larger share. On a SHORT
          // viewport (a phone in landscape, or any window with the keyboard
          // up) it is 1:1, because a 150 px sheet cannot show a form row and
          // the operator is looking at the controls, not the sky. Either way
          // the sheet is BOUNDED, so it shrinks its scrolling body instead of
          // overflowing the column.
          Expanded(flex: short ? 1 : 3, child: viewer),
          Flexible(
            flex: short ? 1 : 2,
            child: MeasuredBottomInsetReporter(
              onHeight: _setCaptureBarHeight,
              child: _ControlsSheet(
                colors: colors,
                selectedSection: selectedSection,
                onSectionSelected: _selectSection,
                isLooping: _isLooping,
                isSingleCapture: _isSingleCapture,
                isSavingCapture: _singleCapturePreviewReady,
                isStoppingCapture: _isStoppingCapture,
                onSnapshot: _takeSnapshot,
                onToggleLoop: _toggleLoop,
              ),
            ),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: viewer),
        ImagingSidePanel(
          colors: colors,
          selectedSection: selectedSection,
          onSectionSelected: _selectSection,
          collapsed: _sidePanelCollapsed,
        ),
      ],
    );
  }

  /// The canvas and everything that floats over it.
  Widget _canvas(SkotiqColors colors, bool narrow) {
    final viewerState = ref.watch(imagingViewerStateProvider);
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: LivePreviewArea(
            key: TourTarget.imagingPreviewArea.key,
            colors: colors,
            zoomLevel: viewerState.zoomLevel,
            panOffset: viewerState.panOffset,
            showCrosshair: viewerState.showCrosshair,
            showStarOverlay: viewerState.showStarOverlay,
            isStoppingCapture: _isStoppingCapture,
            onZoomIn: _zoomIn,
            onZoomOut: _zoomOut,
            onPanUpdate: _panPreview,
            // Zero on narrow: this layout draws no capture bar, so nothing
            // competes with the histogram for the bottom-right corner.
            captureBarWidth: narrow ? 0 : ref.watch(captureBarWidthProvider),
          ),
        ),
        // The capture bar is glass over the frame, bottom-centre (05 §14). On
        // narrow the sheet below carries Snapshot / Loop instead, so the bar
        // is not drawn twice.
        if (!narrow)
          Positioned(
            left: 0,
            right: 0,
            bottom: SkotiqTokens.spaceLg,
            child: Align(
              child: MeasuredBottomInsetReporter(
                onHeight: _setCaptureBarHeight,
                child: ImagingCaptureBar(
                  isLooping: _isLooping,
                  isSingleCapture: _isSingleCapture,
                  isSavingCapture: _singleCapturePreviewReady,
                  isStoppingCapture: _isStoppingCapture,
                  onSnapshot: _takeSnapshot,
                  onToggleLoop: _toggleLoop,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Opens the current frame in the fullscreen viewer — the screen's
  /// "Immersive" action. No frame, nothing to immerse in.
  void _openImmersive() {
    final image = ref.read(currentImageProvider);
    if (image == null) {
      context.showInfoSnackBar('Take a frame first, then view it full screen.');
      return;
    }
    FullscreenImageViewer.show(context, image);
  }
}

/// The narrow-layout controls sheet: a horizontal chip strip for the sections,
/// the selected section's body, and the two capture buttons full width.
class _ControlsSheet extends StatelessWidget {
  const _ControlsSheet({
    required this.colors,
    required this.selectedSection,
    required this.onSectionSelected,
    required this.isLooping,
    required this.isSingleCapture,
    required this.isSavingCapture,
    required this.isStoppingCapture,
    required this.onSnapshot,
    required this.onToggleLoop,
  });

  final SkotiqColors colors;
  final int selectedSection;
  final ValueChanged<int> onSectionSelected;
  final bool isLooping;
  final bool isSingleCapture;
  final bool isSavingCapture;
  final bool isStoppingCapture;
  final VoidCallback onSnapshot;
  final VoidCallback onToggleLoop;

  /// Below this the section chip strip stands down: 40 px of navigation in a
  /// sheet this short is 40 px the field being typed into does not have.
  static const double _stripFloor = 140;

  /// Below this even the two capture buttons stand down. The only thing that
  /// squeezes a sheet this far is a keyboard, and an operator with a keyboard
  /// up is typing a number, not firing the shutter; both come back the moment
  /// it closes.
  static const double _buttonsFloor = 96;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final height = constraints.maxHeight;
            final showStrip = !height.isFinite || height >= _stripFloor;
            final showButtons = !height.isFinite || height >= _buttonsFloor;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (showStrip)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(
                      SkotiqTokens.spaceSm,
                      SkotiqTokens.spaceSm,
                      SkotiqTokens.spaceSm,
                      0,
                    ),
                    child: Row(
                      children: <Widget>[
                        for (var i = 0;
                            i < ImagingSidePanel.sections.length;
                            i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: SkotiqChip(
                              key: ImagingSidePanel.sections[i].buttonKey,
                              label: ImagingSidePanel.sections[i].tooltip,
                              icon: ImagingSidePanel.sections[i].icon,
                              selected: i == selectedSection,
                              onTap: () => onSectionSelected(i),
                            ),
                          ),
                      ],
                    ),
                  ),
                // The section body takes whatever the sheet has left after the
                // chip strip and the two buttons — never a fraction of the
                // WINDOW, which is a different number the moment a keyboard is
                // up. Each section scrolls internally, so this can shrink to
                // nothing without overflowing.
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SkotiqTokens.spaceLg,
                      vertical: SkotiqTokens.spaceSm,
                    ),
                    child: ImagingSectionBody(
                      colors: colors,
                      section: selectedSection,
                    ),
                  ),
                ),
                if (showButtons)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      SkotiqTokens.spaceLg,
                      0,
                      SkotiqTokens.spaceLg,
                      SkotiqTokens.spaceMd,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: _SheetLoopButton(
                            isLooping: isLooping,
                            isSingleCapture: isSingleCapture,
                            isStoppingCapture: isStoppingCapture,
                            onToggleLoop: onToggleLoop,
                          ),
                        ),
                        const SizedBox(width: SkotiqTokens.spaceSm),
                        Expanded(
                          child: _SheetSnapshotButton(
                            isLooping: isLooping,
                            isSingleCapture: isSingleCapture,
                            isSavingCapture: isSavingCapture,
                            isStoppingCapture: isStoppingCapture,
                            onSnapshot: onSnapshot,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The sheet's Snapshot button — the page's single primary in this layout.
class _SheetSnapshotButton extends ConsumerWidget {
  const _SheetSnapshotButton({
    required this.isLooping,
    required this.isSingleCapture,
    required this.isSavingCapture,
    required this.isStoppingCapture,
    required this.onSnapshot,
  });

  final bool isLooping;
  final bool isSingleCapture;
  final bool isSavingCapture;
  final bool isStoppingCapture;
  final VoidCallback onSnapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(cameraStateProvider).connectionState ==
        DeviceConnectionState.connected;
    final enabled = connected && !isSingleCapture && !isLooping;
    return SkotiqButton(
      key: TourTarget.imagingSnapshotButton.key,
      label: isSingleCapture
          ? (isStoppingCapture
              ? 'Stopping…'
              : isSavingCapture
                  ? 'Saving…'
                  : 'Taking…')
          : 'Snapshot',
      icon: isSingleCapture ? SkotiqIcons.loading : SkotiqIcons.camera,
      size: ButtonSize.large,
      isLoading: isSingleCapture,
      semanticsHint: connected ? null : 'Connect a camera in Equipment first',
      onPressed: enabled ? onSnapshot : null,
    );
  }
}

class _SheetLoopButton extends ConsumerWidget {
  const _SheetLoopButton({
    required this.isLooping,
    required this.isSingleCapture,
    required this.isStoppingCapture,
    required this.onToggleLoop,
  });

  final bool isLooping;
  final bool isSingleCapture;
  final bool isStoppingCapture;
  final VoidCallback onToggleLoop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(cameraStateProvider).connectionState ==
        DeviceConnectionState.connected;
    final enabled = connected && !isSingleCapture && !isStoppingCapture;
    return SkotiqButton(
      key: TourTarget.imagingLoopButton.key,
      label: isStoppingCapture
          ? 'Stopping…'
          : isLooping
              ? 'Stop'
              : 'Loop',
      icon: isStoppingCapture
          ? SkotiqIcons.loading
          : isLooping
              ? SkotiqIcons.stop
              : SkotiqIcons.repeat,
      size: ButtonSize.large,
      variant: isLooping ? ButtonVariant.destructive : ButtonVariant.secondary,
      semanticsHint: connected ? null : 'Connect a camera in Equipment first',
      onPressed: enabled ? onToggleLoop : null,
    );
  }
}
