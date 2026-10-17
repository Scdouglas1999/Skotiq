part of '../planetarium_screen.dart';

extension _PlanetariumScreenLayouts on _PlanetariumScreenState {
  // Legacy phone/desktop layouts kept on disk for reference during the
  // adaptive-shell redesign (see planetarium_screen.dart): `_buildShell` is the
  // single mounted layout now, so these two are intentionally unmounted rather
  // than deleted. analyzer 10's UNUSED_ELEMENT (a warning the production gate
  // fails on) is suppressed here so the kept-on-purpose code does not break CI.
  // ignore: unused_element
  Widget _buildMobileLayout(BuildContext context, SkotiqColors colors,
      SelectedObjectState selectedObject) {
    // Orientation-aware overlay placement. Every floating overlay's rectangle
    // is recomputed from the live viewport + SafeArea (see
    // [MobileOverlaySlots]) so the controls/compass/minimap/time-panel never
    // overlap or clip when the phone rotates; fixed offsets tuned for portrait
    // break in landscape.
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final sizing = AdaptiveSizing.of(context);

        // FAB column height: panel + search + filter FABs (40 each) plus a tall
        // info FAB (56) when an object is selected, with 12 px gaps. Estimated
        // up front so the resolver can keep the mini-map clear of it.
        final hasInfoFab = selectedObject.object != null;
        final fabHeight = hasInfoFab
            ? (40 + 12 + 40 + 12 + 40 + 12 + 56)
            : (40 + 12 + 40 + 12 + 40);
        final slots = MobileOverlaySlots.resolve(
          viewport: viewport,
          safeArea: media.padding,
          edge: sizing.edgePadding,
          compassSize: sizing.compassSize,
          minimapSize: sizing.minimapSize,
          // TimeControlPanel(compact: true) is a small pill; the resolver only
          // needs an upper-bound box so it can stack the compass clear of it.
          timePanelSize: const Size(150, 40),
          fabColumnSize: Size(56, fabHeight.toDouble()),
        );

        return Stack(
          key: _skyViewKey,
          children: [
            Positioned.fill(
              child: GestureDetector(
                onSecondaryTapUp: (details) =>
                    _showContextMenu(context, details.globalPosition),
                child: Consumer(
                  builder: (context, ref, _) {
                    final observedIds =
                        ref.watch(observedCatalogIdsProvider).valueOrNull ?? {};
                    final listedIds =
                        ref.watch(listedCatalogIdsProvider).valueOrNull ?? {};
                    final bortleClass = ref.watch(bortleClassProvider);
                    final horizonProfile = ref.watch(horizonProfileProvider);
                    return FullScreenSkyView(
                      key: PlanetariumTutorialKeys.skyView,
                      showFOV: _showFOV,
                      onObjectTapped: _handleObjectTapped,
                      observedObjectIds: observedIds,
                      listedObjectIds: listedIds,
                      bortleClass: bortleClass,
                      measurementMode: ref.watch(measurementModeProvider),
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

            // FOV reference rings (Telrad / finder) — non-interactive angular
            // overlay centered on the view center. Scales with zoom.
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

            // Multi-rig FOV framing presets — interactive (drag / rotate).
            // Mounted only while the FOV layer is toggled on.
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

            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: MobileTopOverlay(colors: colors),
            ),

            // Left tool rail — view controls stacked above slew controls in a
            // single scrollable column bounded between the top and bottom bars.
            // Scrolling (rather than fixed offsets) is what keeps the rail from
            // colliding with the bottom panels when the height collapses in
            // landscape.
            Positioned.fromRect(
              rect: slots.leftRail,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MobileViewControls(
                      colors: colors,
                      showFOV: _showFOV,
                      onToggleFOV: () => _update(() => _showFOV = !_showFOV),
                    ),
                    const SizedBox(height: 8),
                    MobileSlewControls(
                      colors: colors,
                      slewMode: _slewMode,
                      onToggleSlewMode: _toggleSlewMode,
                      onStopSlew: _handleStopSlew,
                    ),
                  ],
                ),
              ),
            ),

            Positioned(
              left: slots.compass.left,
              top: slots.compass.top,
              child: Consumer(
                builder: (context, ref, _) {
                  final showCompass = ref.watch(showCompassHudProvider);
                  if (!showCompass) return const SizedBox.shrink();

                  // Alt/az is a reading against a horizon, so the HUD has
                  // nothing to show until a site is on record.
                  final altAz = ref.watch(viewCenterAltAzProvider);
                  if (altAz == null) return const SizedBox.shrink();
                  return CompassHud(
                    azimuth: altAz.$1,
                    altitude: altAz.$2,
                    size: sizing.compassSize,
                    showAltitude: false,
                  );
                },
              ),
            ),

            Positioned(
              left: slots.minimap.left,
              top: slots.minimap.top,
              child: Consumer(
                builder: (context, ref, _) {
                  final showMinimap = ref.watch(showMinimapProvider);
                  if (!showMinimap) return const SizedBox.shrink();

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
                      // Unreachable without a site — the minimap above returns
                      // early — but the conversion needs one, so it is read
                      // rather than assumed.
                      final site = ref.read(observerLocationProvider).site;
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

            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: MobileBottomInfoBar(colors: colors),
            ),

            Positioned(
              left: slots.timePanel.left,
              top: slots.timePanel.top,
              child: TimeControlPanel(
                backgroundColor: colors.surface.withValues(alpha: 0.9),
                textColor: colors.textPrimary,
                accentColor: colors.accent,
                compact: true,
              ),
            ),

            Positioned(
              left: slots.fabColumn.left,
              top: slots.fabColumn.top,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Opens the desktop side column (Tonight / Catalog / Lists /
                  // Search / Info) as a draggable sheet — otherwise unreachable
                  // on phones, which have no room for the always-on panel.
                  FloatingActionButton.small(
                    heroTag: 'panel_fab',
                    backgroundColor: colors.surface.withValues(alpha: 0.9),
                    onPressed: () => _showSidebarPanelSheet(context, colors),
                    child: Icon(SkotiqIcons.layers,
                        size: 20, color: colors.textPrimary),
                  ),
                  const SizedBox(height: 12),
                  FloatingActionButton.small(
                    key: PlanetariumTutorialKeys.search,
                    heroTag: 'search_fab',
                    backgroundColor: colors.surface.withValues(alpha: 0.9),
                    onPressed: () => _showMobileSearchDialog(context, colors),
                    child: Icon(SkotiqIcons.search,
                        size: 20, color: colors.textPrimary),
                  ),
                  const SizedBox(height: 12),
                  FloatingActionButton.small(
                    key: PlanetariumTutorialKeys.filterBtn,
                    heroTag: 'filter_fab',
                    backgroundColor: colors.surface.withValues(alpha: 0.9),
                    onPressed: () => _showFilterBottomSheet(context),
                    child: Icon(LucideIcons.slidersHorizontal,
                        size: 20, color: colors.textPrimary),
                  ),
                  const SizedBox(height: 12),
                  if (selectedObject.object != null)
                    FloatingActionButton(
                      heroTag: 'info_fab',
                      backgroundColor: colors.primary,
                      onPressed: () =>
                          _showObjectInfoBottomSheet(context, colors),
                      child: Icon(SkotiqIcons.info,
                          size: 24, color: colors.onPrimary),
                    ),
                ],
              ),
            ),

            // MobileSelectedObjectHud removed: the ObjectInfoPopup (shown on
            // click) provides the same information plus detailed coordinates,
            // alt/az, and multiple action buttons.

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
                hasRotator: ref.watch(rotatorStateProvider).connectionState ==
                    DeviceConnectionState.connected,
              ),

            if (_showHelpOverlay)
              _KeyboardShortcutsOverlay(
                onDismiss: () => _update(() => _showHelpOverlay = false),
              ),
          ],
        );
      },
    );
  }

  // ignore: unused_element
  Widget _buildDesktopLayout(BuildContext context, SkotiqColors colors,
      SelectedObjectState selectedObject) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelMax = clampPanelWidth(
          constraints.maxWidth,
          fraction: 0.38,
          min: 250,
          max: 500,
        );
        final panelInitial = clampPanelWidth(
          constraints.maxWidth,
          fraction: 0.28,
          min: 250,
          max: 340,
        );
        final panelMin = math.min(
          panelMax,
          clampPanelWidth(
            constraints.maxWidth,
            fraction: 0.22,
            min: 200,
            max: 280,
          ),
        );

        return Stack(
          children: [
            Row(
              children: [
                Expanded(
                  child: Stack(
                    key: _skyViewKey,
                    children: [
                      GestureDetector(
                        onSecondaryTapUp: (details) =>
                            _showContextMenu(context, details.globalPosition),
                        child: Consumer(
                          builder: (context, ref, _) {
                            final observedIds = ref
                                    .watch(observedCatalogIdsProvider)
                                    .valueOrNull ??
                                {};
                            final bortleClass = ref.watch(bortleClassProvider);
                            final horizonProfile =
                                ref.watch(horizonProfileProvider);
                            return FullScreenSkyView(
                              key: PlanetariumTutorialKeys.skyView,
                              showFOV: _showFOV,
                              onObjectTapped: _handleObjectTapped,
                              observedObjectIds: observedIds,
                              bortleClass: bortleClass,
                              measurementMode:
                                  ref.watch(measurementModeProvider),
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

                      // FOV reference rings (Telrad / finder) — non-interactive
                      // angular overlay centered on the view center. Scales with
                      // zoom via skyViewState FOV.
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

                      // Multi-rig FOV framing presets — interactive (drag to
                      // reposition, rotate handle to set position angle). Only
                      // mounted while the FOV layer is toggled on, so it never
                      // intercepts gestures otherwise.
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

                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: SizedBox(
                          width: double.infinity,
                          child: TopOverlay(colors: colors),
                        ),
                      ),

                      if (kDebugMode || ref.watch(showPerfHudProvider))
                        Positioned(
                          top: 60,
                          right: 16,
                          child: Consumer(
                            builder: (context, ref, _) {
                              final monitor =
                                  ref.watch(performanceMonitorProvider);
                              final refreshRate =
                                  ref.watch(displayRefreshRateProvider);
                              // Null until the first frame timing lands, so
                              // the HUD reads "--" rather than a nominal rate
                              // the monitor has not measured.
                              final fps = monitor.estimatedFps;
                              final cappedFps = fps == null
                                  ? null
                                  : (fps > refreshRate ? refreshRate : fps);
                              final buildMs = monitor.averageBuildTime;
                              final rasterMs = monitor.averageRasterTime;

                              return DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colors.surface.withValues(alpha: 0.8),
                                  borderRadius: BorderRadius.circular(
                                      SkotiqTokens.radiusInline8),
                                  border: Border.all(color: colors.border),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  child: DefaultTextStyle(
                                    style: TextStyle(
                                      color: colors.textPrimary,
                                      fontSize: SkotiqTypography.fontSize12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                            fontSize:
                                                SkotiqTypography.fontSize11,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),

                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: SizedBox(
                          width: double.infinity,
                          child: BottomInfoBar(colors: colors),
                        ),
                      ),

                      // Left tool rail — view controls stacked directly above
                      // the slew controls in a SINGLE scrollable column. As two
                      // independently-Positioned panels, ViewControls overruns
                      // the slew panel once it grows past ~160px tall. Binding
                      // the rail between top:60 and bottom:120 lets it scroll on
                      // short windows instead of colliding with the bottom
                      // panels.
                      Positioned(
                        top: 60,
                        left: 16,
                        bottom: 120,
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ViewControls(
                                colors: colors,
                                showFOV: _showFOV,
                                onToggleFOV: () =>
                                    _update(() => _showFOV = !_showFOV),
                              ),
                              const SizedBox(height: 8),
                              SlewControls(
                                colors: colors,
                                slewMode: _slewMode,
                                onToggleSlewMode: _toggleSlewMode,
                                onStopSlew: _handleStopSlew,
                              ),
                            ],
                          ),
                        ),
                      ),

                      // SelectedObjectHud removed: the ObjectInfoPopup (shown on click)
                      // provides the same information plus detailed coordinates, alt/az,
                      // and multiple action buttons. Having both caused duplicate cards.

                      Positioned(
                        left: AdaptiveSizing.of(context).edgePadding,
                        bottom: AdaptiveSizing.of(context).edgePadding,
                        child: Consumer(
                          builder: (context, ref, _) {
                            final showCompass =
                                ref.watch(showCompassHudProvider);
                            if (!showCompass) {
                              return const SizedBox.shrink();
                            }

                            final sizing = AdaptiveSizing.of(context);
                            // Alt/az is a reading against a horizon, so the
                            // HUD has nothing to show until a site is set.
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

                      Positioned(
                        right: AdaptiveSizing.of(context).edgePadding,
                        bottom: AdaptiveSizing.of(context).edgePadding,
                        child: Consumer(
                          builder: (context, ref, _) {
                            final showMinimap = ref.watch(showMinimapProvider);
                            if (!showMinimap) {
                              return const SizedBox.shrink();
                            }

                            final sizing = AdaptiveSizing.of(context);
                            // The minimap plots the view against the
                            // horizon, which needs a site.
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
                                // Unreachable without a site — the minimap
                                // above returns early — but the conversion
                                // needs one, so it is read rather than assumed.
                                final site =
                                    ref.read(observerLocationProvider).site;
                                if (site == null) return;
                                final time = ref.read(observationTimeProvider);
                                final lst =
                                    AstronomyCalculations.localSiderealTime(
                                        time.time, site.longitude);

                                final (ra, dec) = AstronomyCalculations
                                    .horizontalToEquatorial(
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

                      // Time-travel panel — centered along the bottom so it
                      // clears the compass HUD (bottom-left), the mini-map
                      // (bottom-right) and the full-width info bar (bottom:0).
                      Positioned(
                        bottom: 44,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: TimeControlPanel(
                            backgroundColor:
                                colors.surface.withValues(alpha: 0.9),
                            textColor: colors.textPrimary,
                            accentColor: colors.accent,
                            compact: false,
                          ),
                        ),
                      ),

                      Positioned(
                        top: 60,
                        right: 0,
                        bottom: 0,
                        child: FilterSidebar(
                          isExpanded: _filterSidebarExpanded,
                          onToggle: () => _update(() =>
                              _filterSidebarExpanded = !_filterSidebarExpanded),
                        ),
                      ),
                    ],
                  ),
                ),
                ResizablePanel(
                  initialWidth: panelInitial,
                  minWidth: panelMin,
                  maxWidth: panelMax,
                  side: ResizeSide.left,
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      border: Border(left: BorderSide(color: colors.border)),
                    ),
                    child: Column(
                      children: [
                        SearchHeader(
                          colors: colors,
                          controller: _searchController,
                          // The Search tab below renders these results already.
                          showResultSuggestions: false,
                          onSearch: (query) {
                            ref
                                .read(objectSearchProvider.notifier)
                                .search(query);
                          },
                        ),
                        Expanded(
                          child: DefaultTabController(
                            length: 5,
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
                                      InfoTab(
                                          colors: colors,
                                          selectedObject: selectedObject),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
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
                hasRotator: ref.watch(rotatorStateProvider).connectionState ==
                    DeviceConnectionState.connected,
              ),
            if (_showHelpOverlay)
              _KeyboardShortcutsOverlay(
                onDismiss: () => _update(() => _showHelpOverlay = false),
              ),
          ],
        );
      },
    );
  }
}
