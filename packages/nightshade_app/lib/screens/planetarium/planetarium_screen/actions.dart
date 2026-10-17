part of '../planetarium_screen.dart';

extension _PlanetariumScreenActions on _PlanetariumScreenState {
  void _performInitialSync() {
    if (_initialSyncDone) return;
    _initialSyncDone = true;

    // Initial mount sync
    final mountState = ref.read(mountStateProvider);
    final mountNotifier = ref.read(mountPositionProvider.notifier);
    if (mountState.connectionState == DeviceConnectionState.connected) {
      MountTrackingStatus status;
      if (mountState.isSlewing) {
        status = MountTrackingStatus.slewing;
      } else if (mountState.isParked) {
        status = MountTrackingStatus.parked;
      } else if (mountState.isTracking) {
        status = MountTrackingStatus.tracking;
      } else {
        status = MountTrackingStatus.stopped;
      }
      mountNotifier.updatePosition(
        raHours: mountState.ra,
        decDegrees: mountState.dec,
        status: status,
        isConnected: true,
      );
    }

    // The rotator angle and the sensor geometry are seeded and kept current by
    // `equipmentFovBindingProvider` (watched in build), so there is nothing to
    // sync here — a second writer would race it.
  }

  /// Honour an inbound `/planetarium?ra=<hours>&dec=<deg>&name=<n>` hand-off.
  ///
  /// Mirrors [FramingView]'s `_applyQueryParamsTarget`. The route redirects onto
  /// the Plan Tonight host, which forwards the query, so this reads it from
  /// whichever router state is above us.
  ///
  /// Must be called from `didChangeDependencies`: reading `GoRouterState.of`
  /// there is what makes a later location change re-run this while the view
  /// stays mounted (Plan Tonight's IndexedStack keeps it built, so `initState`
  /// runs only once). The write itself is deferred to the next frame because
  /// Riverpod forbids mutating a provider inside a widget life-cycle.
  ///
  /// Idempotent per query, so panning away after arriving is not undone by an
  /// unrelated dependency change.
  void _applySkyTargetQuery() {
    if (!mounted) return;
    final Uri uri;
    try {
      uri = GoRouterState.of(context).uri;
    } on GoError {
      // Why: the planetarium is reachable outside the GoRouter tree (tests, the
      // mosaic/target pickers that embed the view directly).
      return;
    }

    final params = uri.queryParameters;
    final signature = '${params['ra']}|${params['dec']}|${params['name']}';
    if (signature == _appliedSkyTargetQuery) return;

    final coordinate = parseSkyTargetQuery(params);
    if (coordinate == null) return;

    _appliedSkyTargetQuery = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      focusSkyOn(ref, coordinate);
    });
  }

  /// [coordinates] is the catalog position of [object] when the tap hit one,
  /// and the tapped sky position only for empty sky — so slew mode aims at the
  /// object, not at the pixel the finger landed on.
  void _handleObjectTapped(CelestialObject? object,
      CelestialCoordinate coordinates, Offset screenPosition) {
    // If in slew mode, handle slew instead of normal tap behavior
    if (_slewMode) {
      _handleSlewToCoordinates(coordinates, objectName: object?.name);
      return;
    }

    // Update selected object provider
    if (object != null) {
      ref.read(selectedObjectProvider.notifier).selectObject(object);
    } else {
      ref.read(selectedObjectProvider.notifier).clearSelection();
    }

    // Only show popup if an object was found
    if (object != null) {
      final renderBox =
          _skyViewKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null) {
        // Convert to global position for proper popup placement
        final globalPosition = renderBox.localToGlobal(screenPosition);
        _update(() {
          _showPopup = true;
          _popupPosition = globalPosition;
          _popupObject = object;
        });
      }
    } else {
      _dismissPopup();
    }
  }

  void _dismissPopup() {
    if (_showPopup) {
      _update(() {
        _showPopup = false;
        _popupObject = null;
      });
    }
  }

  Future<void> _exportFinderChart(BuildContext _) async {
    if (_finderChartExportInFlight) return;
    _update(() => _finderChartExportInFlight = true);

    try {
      final viewState = ref.read(skyViewStateProvider);
      final renderConfig = ref.read(skyRenderConfigProvider);
      // A finder chart states a horizon: it prints the object's altitude and
      // the night's twilight for the observer it was made for. Without a site
      // there is no such observer, so the export is refused rather than
      // charted against 0/0.
      final site = ref.read(observerLocationProvider).site;
      if (site == null) {
        context.showWarningSnackBar(
          'Set your observing location in Settings to export a finder chart.',
        );
        return;
      }
      final time = ref.read(observationTimeProvider);
      final constellations = ref.read(constellationDataProvider);
      final selectedState = ref.read(selectedObjectProvider);
      final sunPos = ref.read(sunPositionProvider);
      final moonPos = ref.read(moonPositionProvider);
      final moonInfo = ref.read(moonInfoProvider);
      final planets = ref.read(planetPositionsProvider);
      final milkyWayPoints = ref.read(milkyWayPointsProvider);

      // Determine object info from popup or selection
      String? objectName;
      String? objectType;
      double? objectMagnitude;
      String? objectSize;
      final obj = _popupObject ?? selectedState.object;
      if (obj != null) {
        if (obj is DeepSkyObject) {
          final (displayName, _) = getDsoDisplayInfo(obj);
          objectName = displayName;
          objectType = obj.type.displayName;
          objectMagnitude = obj.magnitude;
          objectSize = obj.sizeString;
        } else {
          objectName = obj.name;
          objectMagnitude = obj.magnitude;
          if (obj is Star) {
            objectType = obj.spectralType != null
                ? 'Star (${obj.spectralType})'
                : 'Star';
          }
        }
      }

      // Centre the chart on the object it is named for; fall back to where the
      // view is actually pointing (never viewState.centerRA/Dec directly — in
      // alt/az mode those hold the stale inactive equatorial pose).
      final (region: chartRegion, pose: chartPose) = finderChartPose(
        viewState: viewState,
        viewCenter: ref.read(viewCenterEquatorialProvider),
        subject: obj?.coordinates ?? selectedState.coordinates,
      );
      final catalog = await ref.read(
        finderChartCatalogSnapshotProvider(chartRegion).future,
      );
      if (!mounted) return;
      final stars = catalog.stars;
      final dsos = catalog.dsos;

      final suggestedName = FinderChartService.suggestedFilename(
        objectName: objectName,
      );

      // Android/iOS have no save dialog — `getSavePath` throws
      // UnimplementedError there — so the chart goes to a sandbox path and
      // reaches the user through the share sheet below.
      final target = await chooseExportTarget(
        suggestedName: suggestedName,
        acceptedTypeGroups: [
          const XTypeGroup(label: 'PDF files', extensions: ['pdf']),
        ],
      );

      if (target == null) return;

      await FinderChartService.generateChart(
        outputPath: target.path,
        viewState: chartPose,
        renderConfig: renderConfig,
        stars: stars,
        dsos: dsos,
        constellations: constellations,
        observationTime: time.time,
        latitude: site.latitude,
        longitude: site.longitude,
        chartConfig: FinderChartConfig(
          printMode: false,
          chartResolution: 2048,
          objectName: objectName,
          objectType: objectType,
          objectMagnitude: objectMagnitude,
          objectSize: objectSize,
          includeDetailsPage: objectName != null,
        ),
        selectedObject: selectedState.coordinates,
        sunPosition: sunPos,
        moonPosition: (moonPos.$1, moonPos.$2, moonInfo.illumination),
        planets: planets,
        milkyWayPoints: milkyWayPoints,
      );

      if (mounted) {
        await revealExportedFile(
          context,
          target.path,
          subject: 'Finder chart',
          desktopMessage: 'Finder chart saved to ${target.path}',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to export chart: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: NightshadeColors.of(context).error,
          ),
        );
      }
    } finally {
      if (mounted) {
        _update(() => _finderChartExportInFlight = false);
      }
    }
  }

  void _sendToFraming() {
    if (_popupObject == null) return;

    final obj = _popupObject!;
    final coords = obj.coordinates;

    // Set the framing target
    ref.read(framingProvider.notifier).setTargetCoordinates(
          coords.ra,
          coords.dec,
          name: obj.name,
        );

    // Navigate to framing screen. The target coordinates are already set
    // above, so a failure here strands the user on the planetarium with the
    // framing target silently changed — log it rather than absorb it.
    try {
      context.goNamed('framing');
    } catch (e, stack) {
      developer.log(
        '[Planetarium] Could not open ${obj.name} in Framing: $e',
        name: 'Planetarium',
        level: 900,
        error: e,
        stackTrace: stack,
      );
    }

    _dismissPopup();
  }

  Future<void> _addToSequencer() async {
    if (_popupObject == null) return;

    final obj = _popupObject!;
    final coords = obj.coordinates;
    final meta = celestialObjectMetadata(obj);

    final target = await catalogTargetSuggestion(
      ref: ref,
      targetName: obj.name,
      raHours: coords.ra,
      decDegrees: coords.dec,
      catalogId: meta.catalogId,
      objectType: meta.objectType,
      magnitude: obj.magnitude,
      sizeArcmin: meta.sizeArcmin,
      constellation: meta.constellation,
    );

    if (!mounted) return;
    final added = await addPlanTonightTargetToSequencer(
      context: context,
      ref: ref,
      target: target,
    );

    if (added && mounted) {
      context.showSuccessSnackBar('Added ${obj.name} to sequence');
    }
    if (mounted) _dismissPopup();
  }

  /// Queue [object] as a wishlist target.
  ///
  /// [targetQueueProvider] is the planetarium→sequencer bridge: the sequencer
  /// Builder's Target Queue panel is a pure view over the same provider, so an
  /// object queued from the sky is immediately visible there and draggable onto
  /// the instruction tree. Unlike "Add to sequence" this writes no sequence
  /// nodes — the queue is a shortlist the user commits from later.
  void _addToTargetQueue(CelestialObject object) {
    final name = object.name.isNotEmpty ? object.name : object.id;
    final queue = ref.read(targetQueueProvider);
    final duplicate = queue.targets.any(
      (t) => t.displayName.toLowerCase() == name.toLowerCase(),
    );
    if (duplicate) {
      context.showInfoSnackBar('$name is already in the target queue');
      return;
    }

    ref.read(targetQueueProvider.notifier).addTarget(object);
    context.showSuccessSnackBar('Added $name to the target queue');
  }

  void _addPopupObjectToTargetQueue() {
    final object = _popupObject;
    if (object == null) return;
    _addToTargetQueue(object);
    _dismissPopup();
  }

  Future<void> _handleSlewToTarget() async {
    if (_popupObject == null) return;

    final obj = _popupObject!;
    final coords = obj.coordinates;

    final result = await ref
        .read(mountCommandServiceProvider)
        .slewTo(coords.ra, coords.dec);

    if (mounted) {
      context.showCommandActionResult(result);
    }

    _dismissPopup();
  }

  Future<void> _handleSlewAndCenter(
      CelestialCoordinate coords, String objectName) async {
    // First slew to approximate position
    final mountService = ref.read(mountCommandServiceProvider);
    final result =
        await mountService.slewTo(coords.ra, coords.dec, showFeedback: false);

    if (!result.isSuccess) {
      if (mounted) {
        context.showCommandActionResult(result);
      }
      return;
    }

    _dismissPopup();

    // Show centering dialog
    if (mounted) {
      await showCenteringDialog(
        context: context,
        targetRa: coords.ra,
        targetDec: coords.dec,
        targetName: objectName,
      );
    }
  }

  Future<void> _handleSlewCenterRotate(
      CelestialCoordinate coords, String objectName) async {
    // First slew to approximate position
    final mountService = ref.read(mountCommandServiceProvider);
    final slewResult =
        await mountService.slewTo(coords.ra, coords.dec, showFeedback: false);

    if (!slewResult.isSuccess) {
      if (mounted) {
        context.showCommandActionResult(slewResult);
      }
      return;
    }

    _dismissPopup();

    // Show centering dialog and wait for completion
    CenteringResult? centeringResult;
    if (mounted) {
      centeringResult = await showDialog<CenteringResult>(
        context: context,
        barrierDismissible: false,
        builder: (context) => CenteringDialog(
          targetRa: coords.ra,
          targetDec: coords.dec,
          targetName: objectName,
        ),
      );
    }

    // If centering failed or was cancelled, don't rotate
    if (centeringResult == null || !centeringResult.success) {
      if (mounted && centeringResult != null) {
        context.showWarningSnackBar('Centering failed - rotation skipped');
      }
      return;
    }

    // Rotate to the planned camera angle if a rotator is connected.
    final rotatorState = ref.read(rotatorStateProvider);
    if (rotatorState.connectionState == DeviceConnectionState.connected &&
        rotatorState.deviceId != null) {
      final targetRotation = ref.read(equipmentFOVProvider).rotation;
      try {
        await ref
            .read(deviceBackendProvider)
            .rotatorMoveTo(rotatorState.deviceId!, targetRotation);
        if (mounted) {
          context.showSuccessSnackBar(
              'Rotating to ${targetRotation.toStringAsFixed(1)}°');
        }
      } catch (e) {
        if (mounted) {
          context.showErrorSnackBar('Rotation failed: $e');
        }
      }
    } else if (mounted) {
      context.showInfoSnackBar('Centered on $objectName');
    }
  }

  Future<void> _handleSlewToCoordinates(CelestialCoordinate coords,
      {String? objectName}) async {
    final mountService = ref.read(mountCommandServiceProvider);
    if (!mountService.isConnected) {
      if (mounted) {
        context.showWarningSnackBar('Mount not connected');
      }
      return;
    }

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Slew'),
        content: Text(
          objectName != null
              ? 'Slew mount to $objectName?\n\nRA: ${coords.ra.toStringAsFixed(4)}h\nDec: ${coords.dec.toStringAsFixed(4)}\u00b0'
              : 'Slew mount to coordinates?\n\nRA: ${coords.ra.toStringAsFixed(4)}h\nDec: ${coords.dec.toStringAsFixed(4)}\u00b0',
        ),
        actions: [
          NightshadeButton(
            onPressed: () => Navigator.of(context).pop(false),
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
          NightshadeButton(
            label: 'Slew',
            variant: ButtonVariant.primary,
            size: ButtonSize.small,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await mountService.slewTo(coords.ra, coords.dec);
  }

  void _toggleSlewMode() {
    _update(() {
      _slewMode = !_slewMode;
    });
    if (_slewMode) {
      context.showInfoSnackBar('Slew mode enabled - tap on sky to slew mount');
    }
  }

  Future<void> _handleStopSlew() async {
    final mountState = ref.read(mountStateProvider);
    if (mountState.connectionState != DeviceConnectionState.connected) {
      if (mounted) {
        context.showWarningSnackBar('Mount not connected');
      }
      return;
    }

    if (!mountState.isSlewing) {
      if (mounted) {
        context.showInfoSnackBar('Mount is not slewing');
      }
      return;
    }

    final result = await ref.read(mountCommandServiceProvider).abortSlew();
    if (mounted) {
      context.showCommandActionResult(result);
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.keyK &&
        (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed)) {
      _openPlanPanelOnSearch(
        isPhone: Responsive.isPhone(context),
        colors: NightshadeColors.of(context),
      );
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      _panView(0, -1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _panView(0, 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _panView(-1, 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _panView(1, 0);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      _zoomIn();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _zoomOut();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyH || key == LogicalKeyboardKey.keyR) {
      _resetView();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyG) {
      ref.read(skyRenderConfigProvider.notifier).toggleGrid();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyC) {
      ref.read(skyRenderConfigProvider.notifier).toggleConstellationLines();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyE) {
      ref.read(skyRenderConfigProvider.notifier).toggleEcliptic();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyN) {
      ref.read(observationTimeProvider.notifier).setRealTime(true);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.space) {
      final timeState = ref.read(observationTimeProvider);
      if (timeState.isRealTime) {
        // Pause: switch to frozen time
        ref.read(observationTimeProvider.notifier).setSpeedMultiplier(0);
      } else if (timeState.speedMultiplier == 0) {
        // Resume: switch back to real-time
        ref.read(observationTimeProvider.notifier).setRealTime(true);
      } else {
        // Currently fast-forwarding: pause
        ref.read(observationTimeProvider.notifier).setSpeedMultiplier(0);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyM) {
      ref.read(showMinimapProvider.notifier).state =
          !ref.read(showMinimapProvider);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyF) {
      _update(() => _showFOV = !_showFOV);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (_showHelpOverlay) {
        _update(() => _showHelpOverlay = false);
        return KeyEventResult.handled;
      }
      _dismissPopup();
      ref.read(selectedObjectProvider.notifier).clearSelection();
      return KeyEventResult.handled;
    }

    if ((key == LogicalKeyboardKey.slash &&
            HardwareKeyboard.instance.logicalKeysPressed
                .contains(LogicalKeyboardKey.shiftLeft)) ||
        (key == LogicalKeyboardKey.slash &&
            HardwareKeyboard.instance.logicalKeysPressed
                .contains(LogicalKeyboardKey.shiftRight)) ||
        key == LogicalKeyboardKey.question) {
      _update(() => _showHelpOverlay = !_showHelpOverlay);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _panView(double dx, double dy) {
    final viewState = ref.read(skyViewStateProvider);
    final panAmount = viewState.fieldOfView / 20;
    ref.read(skyViewStateProvider.notifier).setCenter(
          viewState.centerRA + dx * panAmount / 15,
          (viewState.centerDec + dy * panAmount).clamp(-90.0, 90.0),
        );
  }

  void _zoomIn() {
    final viewState = ref.read(skyViewStateProvider);
    ref.read(skyViewStateProvider.notifier).setFieldOfView(
          (viewState.fieldOfView * 0.8).clamp(1.0, 120.0),
        );
  }

  void _zoomOut() {
    final viewState = ref.read(skyViewStateProvider);
    ref.read(skyViewStateProvider.notifier).setFieldOfView(
          (viewState.fieldOfView * 1.25).clamp(1.0, 120.0),
        );
  }

  void _resetView() {
    // Home is the observer's zenith in whichever frame is active, not the fixed
    // point RA 0h / Dec 0 — which at the audited site sat 14 deg BELOW the
    // horizon, so "reset view" pointed the map at the ground.
    final notifier = ref.read(skyViewStateProvider.notifier);
    // The zenith needs an observer. With no site on record only the horizontal
    // frame has a home, so the equatorial centre is left where it is.
    final home = ref.read(skyViewHomeCenterProvider);
    if (home != null) {
      notifier.setCenter(home.$1, home.$2);
    }
    notifier.setHorizontalCenter(0, 90);
    notifier.setFieldOfView(60);
  }
}
