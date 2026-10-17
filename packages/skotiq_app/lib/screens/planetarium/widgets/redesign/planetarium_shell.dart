part of '../../planetarium_screen.dart';

/// Adaptive "top command bar + dockable panels" planetarium layout.
///
/// ONE layout for desktop and phone. Structure:
///
/// ```
/// Column[
///   PlanetariumCommandBar,
///   Expanded[ Stack[
///     FullScreenSkyView (fills),
///     FovRingsOverlay / MultiFovOverlay,
///     CompassHud / SkyMinimap,
///     BottomInfoBar (bottom), TimeControlPanel (bottom-center),
///     right-docked Layers / Plan panels (desktop) ,
///     ObjectInfoPopup,
///   ] ]
/// ]
/// ```
///
/// On phone (`width < BreakpointTokens.breakpointPhone`) the right-docked panels
/// become bottom sheets and the command bar condenses (collapses the View
/// segment into Tools). The Plan/Object panel reuses the existing SidebarTabs
/// (Tonight/Catalog/Lists/Search/Info) + SearchHeader.
extension _PlanetariumShell on _PlanetariumScreenState {
  Widget _buildShell(BuildContext context, SkotiqColors colors,
      SelectedObjectState selectedObject) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isPhone = Responsive.isPhone(context) ||
            BreakpointTokens.isPhone(constraints.maxWidth);

        // Canvas width the right-docked panel takes away, 0 when none is open.
        //
        // Insetting the overlays by the drawer's width is what makes "docked"
        // true — the panel takes space rather than covering controls. Laid out
        // across the FULL stack the bottom chrome runs under the drawer, which
        // at 900 px puts it over the time transport: seconds hidden behind the
        // panel, fast-forward unclickable.
        final dockedWidth = !isPhone && (_layersPanelOpen || _planPanelOpen)
            ? _shellPanelWidth(constraints.maxWidth)
            : 0.0;

        return Column(
          children: [
            PlanetariumCommandBar(
              compact: isPhone,
              layersOpen: !isPhone && _layersPanelOpen,
              panelOpen: !isPhone && _planPanelOpen,
              showFov: _showFOV,
              onToggleLayers: () => _toggleShellPanel(_ShellPanel.layers,
                  isPhone: isPhone, colors: colors),
              onTogglePanel: () => _toggleShellPanel(_ShellPanel.plan,
                  isPhone: isPhone, colors: colors),
              onOpenSearch: () =>
                  _openPlanPanelOnSearch(isPhone: isPhone, colors: colors),
              onToggleFov: () => _update(() => _showFOV = !_showFOV),
              onResetView: _resetView,
              onExportChart: () => _exportFinderChart(context),
            ),
            Expanded(
              child: Stack(
                key: _skyViewKey,
                children: [
                  // Sky canvas (fills)
                  Positioned.fill(
                    child: GestureDetector(
                      onSecondaryTapUp: (details) =>
                          _showContextMenu(context, details.globalPosition),
                      child: Consumer(
                        builder: (context, ref, _) {
                          final observedIds = ref
                                  .watch(observedCatalogIdsProvider)
                                  .valueOrNull ??
                              {};
                          final listedIds =
                              ref.watch(listedCatalogIdsProvider).valueOrNull ??
                                  {};
                          // Targets of tonight's sequence get their own
                          // marker on the sky, so the plan is visible where the
                          // user is choosing what to shoot.
                          final sequencedIds = ref.watch(
                            sequencedObjectIdsProvider,
                          );
                          final bortleClass = ref.watch(bortleClassProvider);
                          final horizonProfile =
                              ref.watch(horizonProfileProvider);
                          // Sky-survey imagery behind the chart, for the narrow
                          // fields where the star catalogue runs out (~3 stars
                          // per square degree). Off unless the user turns it on
                          // AND the view is zoomed in past the threshold, so
                          // the common case allocates nothing. `occludes` is
                          // false until tiles are actually on screen, which is
                          // what keeps the view from ever going blank while
                          // imagery loads — or forever, offline.
                          final imageryActive =
                              ref.watch(planetariumSkyImageryActiveProvider);
                          return FullScreenSkyView(
                            key: PlanetariumTutorialKeys.skyView,
                            showFOV: _showFOV,
                            onObjectTapped: _handleObjectTapped,
                            observedObjectIds: observedIds,
                            listedObjectIds: listedIds,
                            sequencedObjectIds: sequencedIds,
                            bortleClass: bortleClass,
                            measurementMode: ref.watch(measurementModeProvider),
                            backgroundLayer: imageryActive
                                ? SkyBackgroundLayer(
                                    child: const PlanetariumSkyImageryLayer(),
                                    occludesSkyGradient: ref.watch(
                                      planetariumSkyImageryVisibleProvider,
                                    ),
                                  )
                                : null,
                            horizonAltitudes: horizonProfile.isFlat
                                ? null
                                : List<double>.generate(
                                    360,
                                    (az) => horizonProfile
                                        .altitudeAtAzimuth(az.toDouble())),
                          );
                        },
                      ),
                    ),
                  ),

                  // FOV reference rings
                  Positioned.fill(
                    child: Consumer(
                      builder: (context, ref, _) {
                        if (!ref.watch(showFovRingsProvider)) {
                          return const SizedBox.shrink();
                        }
                        final viewState = ref.watch(skyViewStateProvider);
                        return IgnorePointer(
                          child: FovRingsOverlay(
                            fieldOfView: viewState.fieldOfView,
                            centerRA: viewState.centerRA,
                            centerDec: viewState.centerDec,
                          ),
                        );
                      },
                    ),
                  ),

                  // Multi-rig FOV framing presets (interactive)
                  if (_showFOV)
                    Positioned.fill(
                      child: Consumer(
                        builder: (context, ref, _) {
                          final viewState = ref.watch(skyViewStateProvider);
                          return MultiFovOverlay(
                            centerRaHours: viewState.centerRA,
                            centerDecDeg: viewState.centerDec,
                            fieldOfViewDeg: viewState.fieldOfView,
                            viewRotationDeg: viewState.rotation,
                          );
                        },
                      ),
                    ),

                  // Star catalog fallback warning + depth notice
                  // Mutually exclusive by construction (the depth notice stands
                  // down while the fallback is up), so they share one slot.
                  Positioned(
                    top: 12,
                    left: 12,
                    width: _fallbackBannerWidth(
                      constraints.maxWidth - dockedWidth,
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StarCatalogFallbackBanner(),
                        StarChartDepthNotice(),
                      ],
                    ),
                  ),

                  // Sky-survey imagery credit
                  // A licence obligation, not chrome: CDS and the survey
                  // publishers require the credit whenever their imagery is on
                  // screen. Top-centre is the one free band (the fallback
                  // banner is top-left, the perf HUD top-right, and the compass
                  // / minimap / time control / info bar own the bottom edge).
                  // Only the pill itself is hit-testable, so the Align over
                  // empty space does not steal the sky's pan gestures.
                  const Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: PlanetariumSkyImageryAttribution(),
                    ),
                  ),

                  // Performance HUD (debug / opt-in)
                  if (kDebugMode || ref.watch(showPerfHudProvider))
                    Positioned(
                      top: 12,
                      right: 12,
                      child: _PerfHud(colors: colors),
                    ),

                  // Compass HUD
                  Positioned(
                    left: AdaptiveSizing.of(context).edgePadding,
                    bottom: 56,
                    child: Consumer(
                      builder: (context, ref, _) {
                        if (!ref.watch(showCompassHudProvider)) {
                          return const SizedBox.shrink();
                        }
                        final sizing = AdaptiveSizing.of(context);
                        // Alt/az is a reading against a horizon, so the HUD has
                        // nothing to show until a site is on record.
                        final altAz = ref.watch(viewCenterAltAzProvider);
                        if (altAz == null) return const SizedBox.shrink();
                        return CompassHud(
                          azimuth: altAz.$1,
                          altitude: altAz.$2,
                          size: sizing.compassSize,
                          showAltitude: !sizing.useCondensedHud,
                        );
                      },
                    ),
                  ),

                  // Mini-map
                  Positioned(
                    right: AdaptiveSizing.of(context).edgePadding + dockedWidth,
                    bottom: 56,
                    child: Consumer(
                      builder: (context, ref, _) {
                        if (!ref.watch(showMinimapProvider)) {
                          return const SizedBox.shrink();
                        }
                        final sizing = AdaptiveSizing.of(context);
                        // The minimap plots the view against the horizon, which
                        // needs a site.
                        final altAz = ref.watch(viewCenterAltAzProvider);
                        if (altAz == null) return const SizedBox.shrink();
                        final viewState = ref.watch(skyViewStateProvider);
                        return SkyMinimap(
                          azimuth: altAz.$1,
                          altitude: altAz.$2,
                          fieldOfView: viewState.fieldOfView,
                          rotation: viewState.rotation,
                          size: sizing.minimapSize,
                          onTap: (tapAz, tapAlt) {
                            // Unreachable without a site — the minimap above
                            // returns early — but the conversion needs one.
                            final site =
                                ref.read(observerLocationProvider).site;
                            if (site == null) return;
                            final time = ref.read(observationTimeProvider);
                            final lst = AstronomyCalculations.localSiderealTime(
                                time.time, site.longitude);
                            final (ra, dec) =
                                AstronomyCalculations.horizontalToEquatorial(
                              altDeg: tapAlt,
                              azDeg: tapAz,
                              latitudeDeg: site.latitude,
                              lstHours: lst,
                            );
                            ref
                                .read(skyViewStateProvider.notifier)
                                .setCenter(ra / 15, dec);
                          },
                        );
                      },
                    ),
                  ),

                  // Time-travel panel (bottom-center)
                  PlanetariumTransportSlot(
                    colors: colors,
                    compact: isPhone,
                    dockedWidth: dockedWidth,
                    stackWidth: constraints.maxWidth,
                  ),

                  // Info bar (slim, bottom)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: dockedWidth,
                    child: BottomInfoBar(colors: colors),
                  ),

                  // Right-docked panels (desktop only)
                  if (!isPhone && _layersPanelOpen)
                    Positioned(
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: _DockedPanel(
                        colors: colors,
                        width: _shellPanelWidth(constraints.maxWidth),
                        child: LayersPanel(
                          showFov: _showFOV,
                          onToggleFov: () =>
                              _update(() => _showFOV = !_showFOV),
                          onClose: () =>
                              _update(() => _layersPanelOpen = false),
                        ),
                      ),
                    ),
                  if (!isPhone && _planPanelOpen)
                    Positioned(
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: _DockedPanel(
                        colors: colors,
                        width: _shellPanelWidth(constraints.maxWidth),
                        child: _buildPlanPanelContent(
                          colors,
                          selectedObject,
                          onClose: () => _update(() => _planPanelOpen = false),
                        ),
                      ),
                    ),

                  // Object info popup (on selection)
                  if (_showPopup && _popupObject != null)
                    ObjectInfoPopup(
                      colors: colors,
                      object: _popupObject!,
                      coordinates: _popupObject!.coordinates,
                      position: _popupPosition,
                      onDismiss: _dismissPopup,
                      onSendToFraming: _sendToFraming,
                      onAddToSequencer: _addToSequencer,
                      onAddToQueue: _addPopupObjectToTargetQueue,
                      onSlewToTarget: _handleSlewToTarget,
                      onSlewAndCenter: () => _handleSlewAndCenter(
                        _popupObject!.coordinates,
                        _popupObject!.name,
                      ),
                      onSlewCenterRotate: () => _handleSlewCenterRotate(
                        _popupObject!.coordinates,
                        _popupObject!.name,
                      ),
                      onExportChart: () => _exportFinderChart(context),
                      hasRotator:
                          ref.watch(rotatorStateProvider).connectionState ==
                              DeviceConnectionState.connected,
                    ),

                  if (_showHelpOverlay)
                    _KeyboardShortcutsOverlay(
                      onDismiss: () => _update(() => _showHelpOverlay = false),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  double _shellPanelWidth(double maxWidth) {
    return clampPanelWidth(maxWidth, fraction: 0.30, min: 280, max: 380);
  }

  /// Width of the catalog-fallback warning: clear of the perf HUD on the right
  /// on desktop, near full-bleed on a phone.
  double _fallbackBannerWidth(double maxWidth) {
    return (maxWidth - 24).clamp(0.0, 460.0);
  }

  /// Plan/object panel content — reuses the exact desktop composition:
  /// [SearchHeader] + DefaultTabController(5) hosting [SidebarTabs] and the five
  /// tab bodies.
  Widget _buildPlanPanelContent(
    SkotiqColors colors,
    SelectedObjectState selectedObject, {
    VoidCallback? onClose,
  }) {
    return Column(
      children: [
        if (onClose != null)
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              icon: Icon(SkotiqIcons.close,
                  size: 18, color: colors.textSecondary),
              tooltip: 'Close',
              onPressed: onClose,
            ),
          ),
        SearchHeader(
          colors: colors,
          controller: _searchController,
          focusNode: _searchFocusNode,
          // The Search tab below renders these results already.
          showResultSuggestions: false,
          onSearch: (query) {
            ref.read(objectSearchProvider.notifier).search(query);
          },
        ),
        Expanded(
          child: DefaultTabController(
            length: 5,
            child: _SearchCommandTarget(
              token: _searchFocusToken,
              tabIndex: _searchTabIndex,
              focusNode: _searchFocusNode,
              child: Column(
                children: [
                  SidebarTabs(colors: colors),
                  Expanded(
                    child: TabBarView(
                      children: [
                        TonightTab(colors: colors),
                        CatalogTab(colors: colors),
                        ListsTab(colors: colors),
                        SearchResultsTab(colors: colors),
                        Consumer(
                          builder: (context, ref, _) => InfoTab(
                            colors: colors,
                            selectedObject: ref.watch(selectedObjectProvider),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Toggle a docked panel. On desktop the panels are mutually exclusive (only
  /// one docks at a time). On phone they open as bottom sheets.
  void _toggleShellPanel(_ShellPanel panel,
      {required bool isPhone, required SkotiqColors colors}) {
    if (isPhone) {
      switch (panel) {
        case _ShellPanel.layers:
          _showLayersSheet(context, colors);
          break;
        case _ShellPanel.plan:
          _showSidebarPanelSheet(context, colors);
          break;
      }
      return;
    }
    _update(() {
      switch (panel) {
        case _ShellPanel.layers:
          _layersPanelOpen = !_layersPanelOpen;
          if (_layersPanelOpen) _planPanelOpen = false;
          break;
        case _ShellPanel.plan:
          _planPanelOpen = !_planPanelOpen;
          if (_planPanelOpen) _layersPanelOpen = false;
          break;
      }
    });
  }

  /// Command-bar "Search ⌘K" (and the Ctrl/Cmd+K shortcut).
  ///
  /// The shortcut opens the panel AND focuses the field: bumping
  /// [_searchFocusToken] is what makes the panel select the Search tab and put
  /// the caret in it, so the keystrokes after the shortcut land somewhere. The
  /// phone sheet autofocuses its own field.
  void _openPlanPanelOnSearch(
      {required bool isPhone, required SkotiqColors colors}) {
    if (isPhone) {
      _showMobileSearchDialog(context, colors);
      return;
    }
    _update(() {
      _planPanelOpen = true;
      _layersPanelOpen = false;
      _searchFocusToken++;
    });
  }

  /// Layers panel as a phone bottom sheet (full-width slide-up).
  void _showLayersSheet(BuildContext context, SkotiqColors colors) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(SkotiqTokens.radiusInline8)),
            border: Border.all(color: colors.border),
          ),
          child: SafeArea(
            top: false,
            child: LayersPanel(
              showFov: _showFOV,
              onToggleFov: () {
                _update(() => _showFOV = !_showFOV);
                Navigator.of(sheetContext).pop();
              },
              onClose: () => Navigator.of(sheetContext).pop(),
            ),
          ),
        ),
      ),
    );
  }
}

enum _ShellPanel { layers, plan }

/// Index of the Search tab inside the plan panel's five-tab controller
/// (Tonight, Catalog, Lists, Search, Info).
const int _searchTabIndex = 3;

/// Turns a Search command into what the user asked for: the Search tab
/// selected and the caret in the search field.
///
/// Must sit INSIDE the panel's [DefaultTabController] — that is the only place
/// the tab controller can be reached — while the field it focuses lives above
/// it in the panel, hence the shared [focusNode] rather than a callback.
class _SearchCommandTarget extends StatefulWidget {
  const _SearchCommandTarget({
    required this.token,
    required this.tabIndex,
    required this.focusNode,
    required this.child,
  });

  /// Monotonic counter; every change is one Search command.
  final int token;
  final int tabIndex;
  final FocusNode focusNode;
  final Widget child;

  @override
  State<_SearchCommandTarget> createState() => _SearchCommandTargetState();
}

class _SearchCommandTargetState extends State<_SearchCommandTarget> {
  @override
  void initState() {
    super.initState();
    // Token 0 is "the panel was opened some other way" — do not steal focus.
    if (widget.token > 0) _apply();
  }

  @override
  void didUpdateWidget(_SearchCommandTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.token != oldWidget.token) _apply();
  }

  void _apply() {
    // Deferred: on the frame the panel first mounts, the TabController and the
    // field's render object do not exist yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = DefaultTabController.maybeOf(context);
      if (controller != null && controller.index != widget.tabIndex) {
        controller.animateTo(widget.tabIndex);
      }
      widget.focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Where the time transport sits in the bottom band of the sky stack.
///
/// The bottom band holds four things: the compass HUD (left), the horizon
/// minimap (right, inset by any docked panel), the info bar (full width) and
/// the transport, centred. Insetting the transport by the docked panel's width
/// alone — the D-4 fix — moved it INTO the two instruments at 900 px: the
/// transport spanned x 283–555 across a compass at 240–315 and a minimap at
/// 500–620, hiding the compass's `S` label, the altitude ticks and the
/// minimap's `W`. One overlap had simply replaced another.
///
/// So the band the transport may centre in excludes whatever instrument is on
/// screen; and when what remains is too narrow to hold the panel, the transport
/// moves UP over the sky instead of being squeezed into them. Pure so the two
/// live geometries (900 px with a drawer, 1600 px with a drawer) are pinned by
/// arithmetic rather than by a screenshot.
@visibleForTesting
({double left, double right, double bottom}) planetariumTransportBand({
  required double stackWidth,
  required double dockedWidth,
  required double edgePadding,
  required double compassExtent,
  required double minimapExtent,
  required double instrumentBottom,
  required double transportMinWidth,
  double baseBottom = 44,
  double gap = 8,
}) {
  final left = compassExtent > 0 ? edgePadding + compassExtent + gap : 0.0;
  final right = dockedWidth +
      (minimapExtent > 0 ? edgePadding + minimapExtent + gap : 0.0);
  final band = stackWidth - left - right;
  if (band >= transportMinWidth) {
    return (left: left, right: right, bottom: baseBottom);
  }
  // Not enough sky between the instruments: clear them vertically instead. The
  // instruments are square-ish, so their own extent is their height.
  final instrumentHeight =
      compassExtent > minimapExtent ? compassExtent : minimapExtent;
  return (
    left: 0.0,
    right: dockedWidth,
    bottom: instrumentBottom + instrumentHeight + gap,
  );
}

/// The time transport, centred over the sky the user can actually see.
///
/// [dockedWidth] is how much of the stack's right edge a docked panel owns. It
/// is not decoration: laid out across the FULL stack (dockedWidth ignored) the
/// transport slid under an open Layers drawer at 900 px — the clock rendered as
/// `18:46:` with the seconds behind the panel, and the fast-forward button was
/// unreachable because the drawer took the clicks.
class PlanetariumTransportSlot extends ConsumerWidget {
  const PlanetariumTransportSlot({
    super.key,
    required this.colors,
    required this.compact,
    required this.dockedWidth,
    this.stackWidth,
  });

  final SkotiqColors colors;
  final bool compact;
  final double dockedWidth;

  /// Width of the sky stack this transport is positioned in. Null keeps the
  /// pre-instrument behaviour (centre in everything left of the docked panel),
  /// which is what the standalone widget tests pump.
  final double? stackWidth;

  /// Narrowest the full transport lays out at, measured on the running app
  /// (272 px), rounded up so a font change does not silently re-introduce the
  /// squeeze.
  static const double minWidth = 280;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = Center(
      child: TimeControlPanel(
        backgroundColor: colors.surface.withValues(alpha: 0.9),
        textColor: colors.textPrimary,
        accentColor: colors.accent,
        compact: compact,
      ),
    );

    final width = stackWidth;
    if (width == null) {
      return Positioned(bottom: 44, left: 0, right: dockedWidth, child: panel);
    }

    final sizing = AdaptiveSizing.of(context);
    final showCompass = ref.watch(showCompassHudProvider);
    final showMinimap = ref.watch(showMinimapProvider);
    final band = planetariumTransportBand(
      stackWidth: width,
      dockedWidth: dockedWidth,
      edgePadding: sizing.edgePadding,
      // The compass carries the altitude bar beside the dial when the HUD is
      // not condensed — `CompassHud` is `size + 40` wide in that mode, which is
      // exactly the strip the transport was covering.
      compassExtent: showCompass
          ? sizing.compassSize + (sizing.useCondensedHud ? 0 : 40)
          : 0,
      minimapExtent: showMinimap ? sizing.minimapSize : 0,
      instrumentBottom: 56,
      transportMinWidth: minWidth,
    );

    return Positioned(
      bottom: band.bottom,
      left: band.left,
      right: band.right,
      child: panel,
    );
  }
}

/// Right-docked panel container with an animated entrance.
class _DockedPanel extends StatelessWidget {
  const _DockedPanel({
    required this.colors,
    required this.width,
    required this.child,
  });

  final SkotiqColors colors;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: SkotiqTokens.durationNormal,
      curve: SkotiqTokens.curveSnappy,
      builder: (context, t, child) => Transform.translate(
        offset: Offset(width * (1 - t), 0),
        child: Opacity(opacity: t, child: child),
      ),
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(left: BorderSide(color: colors.border)),
        ),
        child: child,
      ),
    );
  }
}

/// Compact perf overlay (FPS / UI / GPU).
class _PerfHud extends ConsumerWidget {
  const _PerfHud({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final monitor = ref.watch(performanceMonitorProvider);
    final refreshRate = ref.watch(displayRefreshRateProvider);
    // Null until the first frame timing lands, so the HUD reads "--" rather
    // than a nominal rate the monitor has not measured.
    final fps = monitor.estimatedFps;
    final cappedFps =
        fps == null ? null : (fps > refreshRate ? refreshRate : fps);
    final buildMs = monitor.averageBuildTime;
    final rasterMs = monitor.averageRasterTime;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: DefaultTextStyle(
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: SkotiqTypography.fontSize12,
            fontWeight: FontWeight.w600,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'FPS ${cappedFps?.toStringAsFixed(1) ?? '--'}'
                ' / ${refreshRate.toStringAsFixed(0)}Hz',
              ),
              const SizedBox(height: 2),
              Text(
                'UI ${buildMs.toStringAsFixed(1)}ms  GPU ${rasterMs.toStringAsFixed(1)}ms',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: SkotiqTypography.fontSize11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
