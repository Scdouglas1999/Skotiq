// ignore_for_file: invalid_use_of_protected_member
// Checkpoint probing, panel geometry, time estimates, sequence/project creation and validation dialogs.
part of '../mosaic_wizard_dialog.dart';

extension _MosaicWizardLogic on _MosaicWizardDialogState {
  Future<void> _probeForInterruptedMosaic() async {
    final authority = ref.read(backendProvider);
    final generation = _authorityGeneration;
    try {
      final backend = ref.read(sequencerBackendProvider);
      final hasCheckpoint = await backend.hasCheckpoint();
      if (!_isCurrentAuthority(authority, generation)) return;
      if (!hasCheckpoint) return;
      final info = await backend.getCheckpointInfo();
      if (!_isCurrentAuthority(authority, generation)) return;
      final isMosaic = info != null &&
          info.canResume &&
          info.sequenceName.startsWith('Mosaic ');
      if (isMosaic) {
        setState(() => _resumableMosaicCheckpoint = info);
      }
    } catch (e) {
      if (mounted && _isCurrentAuthority(authority, generation)) {
        context.showErrorSnackBar(
          'Could not check for interrupted mosaic: $e',
        );
      }
    }
  }

  Future<void> _resumeInterruptedMosaic() async {
    if (_checkpointAction != null) return;
    setState(() => _checkpointAction = 'resume');
    try {
      // Restore through the SequenceExecutor so the editor, progress and
      // native tree agree; the mosaic continues when the operator presses
      // Start.
      await ref.read(sequenceExecutorProvider).restoreFromCheckpoint();
      if (mounted) {
        setState(() => _checkpointAction = null);
        Navigator.of(context).pop();
        context.showSuccessSnackBar(
          'Mosaic restored from its checkpoint. Press Start to continue.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checkpointAction = null);
        context.showErrorSnackBar('Failed to resume mosaic: $e');
      }
    }
  }

  Future<void> _discardMosaicCheckpoint() async {
    if (_checkpointAction != null) return;
    setState(() => _checkpointAction = 'discard');
    final backend = ref.read(sequencerBackendProvider);
    try {
      await backend.discardCheckpoint();
      if (mounted) {
        setState(() {
          _checkpointAction = null;
          _resumableMosaicCheckpoint = null;
        });
        context.showSuccessSnackBar('Mosaic checkpoint discarded.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checkpointAction = null);
        context.showErrorSnackBar('Failed to discard checkpoint: $e');
      }
    }
  }

  /// Compute panel positions for the visual planner.
  ///
  /// Delegates to the planetarium's `MosaicPlanner.generateRectangularMosaic`
  /// for the actual spherical geometry — that ensures the on-screen
  /// preview matches the framing-view's mosaic overlay (the
  /// planetarium uses the same planner to render its own mosaic
  /// preview). The wizard then maps those panels into the local
  /// `_PanelPosition` shape and overlays the user's enable/disable
  /// toggles.
  ///
  /// The geometry is memoised on its inputs; the disabled-state overlay is a
  /// cheap per-call post-map (it can change every tap without recomputing the
  /// trig) so it stays outside the cache.
  List<_PanelPosition> _calculatePanels() {
    final key = '$_centerRa|$_centerDec|$_panelWidthArcmin|'
        '$_panelHeightArcmin|$_overlapPercent|$_rotation|'
        '$_panelsVertical|$_panelsHorizontal';
    var geometry = _cachedGeometry;
    if (geometry == null || _cachedGeometryKey != key) {
      final overlapFraction = _overlapPercent / 100.0;
      final panelFovWidthDeg = _panelWidthArcmin / 60.0;
      final panelFovHeightDeg = _panelHeightArcmin / 60.0;

      final plan = planetarium.MosaicPlanner.generateRectangularMosaic(
        center: planetarium.CelestialCoordinate(
          ra: _centerRa,
          dec: _centerDec,
        ),
        rows: _panelsVertical,
        columns: _panelsHorizontal,
        panelFovWidth: panelFovWidthDeg,
        panelFovHeight: panelFovHeightDeg,
        overlap: planetarium.MosaicOverlap(
          horizontal: overlapFraction,
          vertical: overlapFraction,
        ),
        rotation: _rotation,
      );
      geometry = plan.panels
          .map((p) => _PanelPosition(
                ra: p.center.ra,
                dec: p.center.dec,
                index: p.index,
                row: p.row,
                col: p.column,
                enabled: true,
              ))
          .toList();
      _cachedGeometry = geometry;
      _cachedGeometryKey = key;
    }

    // Cheap disabled overlay — recomputed each call without touching the trig.
    return geometry
        .map((p) => _PanelPosition(
              ra: p.ra,
              dec: p.dec,
              index: p.index,
              row: p.row,
              col: p.col,
              enabled: !_disabledPanels.contains((row: p.row, col: p.col)),
            ))
        .toList();
  }

  /// Number of panels that will actually be captured (grid minus disabled
  /// cells that still exist in the current grid).
  int get _activePanelCount =>
      _panelsHorizontal * _panelsVertical - _disabledPanels.length;

  /// Lazily seed [_filterRows] the first time the user switches to the
  /// multi-filter path, so they start from the rig's actual filters (or a
  /// single "Light" row when no filter wheel is configured) instead of an
  /// empty list. The seed exposure/count come from the same Smart-Night
  /// recommendation the simple path already uses, so flipping the switch never
  /// silently changes the plan until the user edits a row.
  void _seedFilterRowsIfNeeded() {
    if (_filterRows.isNotEmpty) return;
    final exposure = mosaicWizardExposureSettingsForContext(
      ref.read(smartNightExposureContextProvider).valueOrNull,
    );
    final filters = ref.read(profileFiltersProvider);
    if (filters.isEmpty) {
      _filterRows.add(_MosaicFilterRow(
        filterName: exposure.filterName ?? 'Light',
        exposureSeconds: exposure.exposureSeconds,
        count: exposure.exposuresPerPanel,
      ));
    } else {
      for (final name in filters) {
        _filterRows.add(_MosaicFilterRow(
          filterName: name,
          exposureSeconds: exposure.exposureSeconds,
          count: exposure.exposuresPerPanel,
        ));
      }
    }
  }

  /// The exposure plan the built sequence and previews use.
  ///
  /// Returns the legacy single-filter Smart-Night settings on the simple path,
  /// or a [MosaicExposureSettings.multiFilter] plan built from [_filterRows]
  /// (filtered to enabled rows) when the multi-filter path is active. Falls
  /// back to the single-filter settings if multi-filter is on but no row is
  /// enabled, so callers always get a usable plan.
  MosaicExposureSettings _effectiveExposure(MosaicExposureSettings single) {
    if (!_multiFilterEnabled) return single;
    final enabled = _filterRows.where((r) => r.enabled).toList();
    if (enabled.isEmpty) return single;
    return MosaicExposureSettings.multiFilter(
      filters: enabled
          .map((r) => MosaicFilterExposure(
                exposureSeconds: r.exposureSeconds,
                exposuresPerPanel: r.count,
                filterName: r.filterName,
              ))
          .toList(),
    );
  }

  /// Total exposure seconds imaged per panel across every resolved filter.
  double _exposureSecsPerPanel(MosaicExposureSettings exposure) {
    var total = 0.0;
    for (final f in exposure.resolvedFilters) {
      total += f.exposureSeconds * f.exposuresPerPanel;
    }
    return total;
  }

  /// Total subs captured per panel across every resolved filter.
  int _exposuresPerPanel(MosaicExposureSettings exposure) {
    var total = 0;
    for (final f in exposure.resolvedFilters) {
      total += f.exposuresPerPanel;
    }
    return total;
  }

  // Per-panel overhead model. These reflect the [MosaicSequenceOptions] the
  // generator actually emits in [_createSequence] (centerAfterSlew: true,
  // autofocusPerPanel: false) so the preview's estimate agrees with the built
  // sequence instead of using one opaque 60 s lump.
  static const double _slewSecsPerPanel = 30.0;
  static const double _centerSecsPerPanel = 30.0; // plate-solve + recenter
  static const double _autofocusSecsPerPanel = 60.0;

  double _perPanelOverheadSecs({
    required bool centerAfterSlew,
    required bool autofocusPerPanel,
  }) {
    var overhead = _slewSecsPerPanel;
    if (centerAfterSlew) overhead += _centerSecsPerPanel;
    if (autofocusPerPanel) overhead += _autofocusSecsPerPanel;
    return overhead;
  }

  double _calculateTotalTime(double exposureSecsPerPanel) {
    // Mirror the options used by _createSequence so preview == built sequence.
    final overheadPerPanel = _perPanelOverheadSecs(
      centerAfterSlew: true,
      autofocusPerPanel: false,
    );
    return _activePanelCount * (exposureSecsPerPanel + overheadPerPanel);
  }

  void _generateMosaic() {
    // A click that produces "no snackbar, no inline error, no new node in the
    // tree, no new log line" is indistinguishable from a disabled button, a
    // swallowed tap, and a stale binary. One line at entry (and one at each
    // early return) settles which of those happened.
    _logWizardAction('load-into-sequencer requested');
    const mosaicService = MosaicService();

    final config = MosaicConfig(
      centerRa: _centerRa,
      centerDec: _centerDec,
      panelWidthArcmin: _panelWidthArcmin,
      panelHeightArcmin: _panelHeightArcmin,
      overlapPercent: _overlapPercent,
      rotation: _rotation,
      panelsHorizontal: _panelsHorizontal,
      panelsVertical: _panelsVertical,
    );

    final validation = mosaicService.validateMosaic(config);
    if (!validation.isValid) {
      _logWizardAction('load-into-sequencer refused: invalid grid');
      _showValidationDialog(validation);
      return;
    }

    if (validation.hasWarnings) {
      _logWizardAction('load-into-sequencer paused on warnings');
      _showWarningsDialog(validation, () {
        _createSequence(mosaicService, config);
      });
      return;
    }

    _createSequence(mosaicService, config);
  }

  void _createSequence(MosaicService mosaicService, MosaicConfig config) {
    final exposure = _effectiveExposure(
      mosaicWizardExposureSettingsForContext(
        ref.read(smartNightExposureContextProvider).valueOrNull,
      ),
    );

    final options = MosaicSequenceOptions(
      serpentineOrdering: true,
      centerAfterSlew: true,
      autofocusPerPanel: false,
      // W1 altitude gate: default each panel's minAltitude to the Smart Night
      // floor so every panel TargetHeader carries a `start_when AltitudeAbove`
      // wait (serialized as `min_altitude`) — matching the headless mosaic
      // path. STRENGTHENS the no-daylight/altitude gate for wizard-built
      // mosaics; never weakens the existing Dart Sun gate (W1) or W5.
      minAltitude: const SmartNightSettings().minAltitudeDeg,
    );

    final nodes = mosaicService.createMosaicSequence(
      mosaicName:
          'Mosaic ${_centerRa.toStringAsFixed(2)}h ${_centerDec.toStringAsFixed(1)}°',
      config: config,
      exposure: exposure,
      options: options,
    );

    final sequenceNotifier = ref.read(currentSequenceProvider.notifier);

    final rootNode = nodes.values.firstWhere(
      (node) => node is InstructionSetNode && node.parentId == null,
    );

    final disabledChildIds = _disabledTargetSubtreeIds(nodes, rootNode);
    final enabledNodes = Map<String, SequenceNode>.fromEntries(
      nodes.entries.where((entry) => !disabledChildIds.contains(entry.key)),
    );

    try {
      if (ref.read(currentSequenceProvider) == null) {
        sequenceNotifier.createSequence(name: 'New Mosaic Sequence');
      }
      final currentRootId = ref.read(currentSequenceProvider)?.rootNodeId;
      if (currentRootId == null) {
        throw StateError('The current sequence has no root node');
      }

      // MosaicService emits a complete graph whose descendants are inserted
      // before their parents in map order. Merge the graph atomically instead
      // of replaying addNode in that order (which attached children to the
      // current root and duplicated panel headers).
      sequenceNotifier.mergeTemplateNodes(
        templateNodes: enabledNodes,
        templateRootId: rootNode.id,
        targetId: currentRootId,
      );
    } on SequenceLockedException catch (error) {
      context.showErrorSnackBar(error.message);
      return;
    } catch (error) {
      context.showErrorSnackBar('Could not load mosaic: $error');
      return;
    }

    Navigator.of(context).pop();

    if (mounted) {
      context.showSuccessSnackBar(
          'Generated mosaic with $_activePanelCount panels');
    }
  }

  /// The mosaic's display name, shared by the "load into sequencer" path and
  /// the durable-project path so a saved project and its capture sequence line
  /// up by name.
  String get _mosaicName =>
      'Mosaic ${_centerRa.toStringAsFixed(2)}h ${_centerDec.toStringAsFixed(1)}°';

  /// Snapshot the wizard's current on-screen design into the value object the
  /// persist controller consumes. Nothing is recomputed — these are the same
  /// centre/grid/overlap/rotation/FOV the visual planner is drawing right now.
  MosaicProjectDesign _currentDesign() => MosaicProjectDesign(
        name: _mosaicName,
        centerRaHours: _centerRa,
        centerDecDegrees: _centerDec,
        rows: _panelsVertical,
        cols: _panelsHorizontal,
        overlapPercent: _overlapPercent,
        positionAngleDeg: _rotation,
        panelWidthArcmin: _panelWidthArcmin,
        panelHeightArcmin: _panelHeightArcmin,
        disabledCells: {..._disabledPanels},
      );

  /// Persist the current design as a durable [MosaicProject] and route to the
  /// project screen (`/mosaic/:id`).
  ///
  /// This is the primary "Create mosaic project" action: it validates the grid
  /// the same way the "Generate Mosaic" (load-into-sequencer) path does, then
  /// hands the design to [MosaicProjectCreationController] (which forwards it to
  /// the committed `mosaicProjectServiceProvider.createProject`). The
  /// load-into-sequencer path is untouched and still available.
  Future<void> _createMosaicProject() async {
    _logWizardAction('create-project requested');
    final backend = ref.read(backendProvider);
    if (backend is NetworkBackend || backend is DisconnectedBackend) {
      _logWizardAction('create-project refused: not the imaging host');
      _showMosaicProjectHostOnlyMessage();
      return;
    }
    const mosaicService = MosaicService();
    final config = MosaicConfig(
      centerRa: _centerRa,
      centerDec: _centerDec,
      panelWidthArcmin: _panelWidthArcmin,
      panelHeightArcmin: _panelHeightArcmin,
      overlapPercent: _overlapPercent,
      rotation: _rotation,
      panelsHorizontal: _panelsHorizontal,
      panelsVertical: _panelsVertical,
    );

    final validation = mosaicService.validateMosaic(config);
    if (!validation.isValid) {
      _logWizardAction('create-project refused: invalid grid');
      _showValidationDialog(validation);
      return;
    }
    if (validation.hasWarnings) {
      _logWizardAction('create-project paused on warnings');
      _showWarningsDialog(validation, () => unawaited(_persistProject()));
      return;
    }
    await _persistProject();
  }

  Future<void> _persistProject() async {
    if (_isCreatingProject) return;
    final authority = ref.read(backendProvider);
    if (authority is NetworkBackend || authority is DisconnectedBackend) {
      _showMosaicProjectHostOnlyMessage();
      return;
    }
    setState(() => _isCreatingProject = true);
    final controller = MosaicProjectCreationController(
      ref.read(mosaicProjectServiceProvider),
    );
    try {
      final projectId = await controller.createProject(_currentDesign());
      if (!mounted) return;
      if (!identical(ref.read(backendProvider), authority)) {
        setState(() => _isCreatingProject = false);
        return;
      }
      setState(() => _isCreatingProject = false);
      Navigator.of(context).pop();
      unawaited(context.push('/mosaic/$projectId'));
    } catch (e) {
      if (mounted) {
        setState(() => _isCreatingProject = false);
        context.showErrorSnackBar('Could not create mosaic project: $e');
      }
    }
  }

  /// One log line per wizard action, so a click that "did nothing" can be told
  /// apart from a click that never arrived. `panelSize=` records the state the
  /// gating decision is made from — the field that decides whether the buttons
  /// are enabled at all.
  void _logWizardAction(String message) {
    developer.log(
      '[MosaicWizard] $message (panelSize='
      '${_panelSizeKnown ? '${_panelWidthArcmin.toStringAsFixed(1)}x'
          '${_panelHeightArcmin.toStringAsFixed(1)} arcmin' : 'unknown'})',
      name: 'MosaicWizardDialog',
    );
  }

  /// Why "Create mosaic project" is unavailable right now, in the operator's
  /// terms, or null when it can run. Shown in the footer beside the button.
  String? _actionBlockedReason({
    required bool isRemote,
    required bool isDisconnected,
  }) {
    if (_isBusy) return null;
    if (isRemote) {
      return 'Durable mosaic projects are created on the imaging host, not '
          'from a remote client. "Load into Sequencer" still works from here.';
    }
    if (isDisconnected) {
      return 'Connect to an imaging host before creating a durable project.';
    }
    if (!_panelSizeKnown) {
      return 'Panel size unknown, so there is nothing to lay a grid out from. '
          'Set a focal length in Settings and connect the camera, or type the '
          'panel width and height under Advanced (numerical).';
    }
    return null;
  }

  void _showMosaicProjectHostOnlyMessage() {
    context.showInfoSnackBar(
      'Create durable mosaic projects on the imaging host. You can still load '
      'this mosaic into the host sequencer from here.',
    );
  }

  /// Find the set of node IDs that correspond to user-disabled panels
  /// in the visual planner. MosaicService labels its per-panel
  /// TargetHeaders with MosaicPanelInfo carrying row/column, so we walk the
  /// generated node map and match disabled cells by (row, col) — the same
  /// position key the visual planner uses — so a grid resize can never
  /// re-point a stale flat index at the wrong physical panel.
  Set<String> _disabledTargetSubtreeIds(
    Map<String, SequenceNode> nodes,
    SequenceNode rootNode,
  ) {
    if (_disabledPanels.isEmpty) return const {};

    final disabled = <String>{};
    for (final node in nodes.values) {
      if (node is TargetHeaderNode) {
        final panel = node.mosaicPanel;
        if (panel != null &&
            _disabledPanels.contains((row: panel.row, col: panel.column))) {
          disabled.add(node.id);
          _collectDescendants(nodes, node.id, disabled);
        }
      }
    }
    return disabled;
  }

  void _collectDescendants(
    Map<String, SequenceNode> nodes,
    String parentId,
    Set<String> sink,
  ) {
    final parent = nodes[parentId];
    if (parent == null) return;
    for (final childId in parent.childIds) {
      if (sink.add(childId)) {
        _collectDescendants(nodes, childId, sink);
      }
    }
  }

  void _showValidationDialog(MosaicValidation validation) {
    showDialog(
      context: context,
      builder: (context) {
        final colors = SkotiqColors.of(context);
        return AlertDialog(
          title: const Text('Invalid Mosaic Configuration'),
          content: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              context,
              designMaxWidth: 480,
              designMaxHeight: 400,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Please fix the following errors:'),
                  const SizedBox(height: 8),
                  ...validation.errors.map((error) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(SkotiqIcons.error,
                                color: colors.error, size: 20),
                            const SizedBox(width: 8),
                            Expanded(child: Text(error)),
                          ],
                        ),
                      )),
                ],
              ),
            ),
          ),
          actions: [
            SkotiqButton(
              onPressed: () => Navigator.of(context).pop(),
              label: 'OK',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
          ],
        );
      },
    );
  }

  void _showWarningsDialog(
      MosaicValidation validation, VoidCallback onProceed) {
    showDialog(
      context: context,
      builder: (context) {
        final colors = SkotiqColors.of(context);
        return SkotiqDialog(
          title: 'Mosaic warnings',
          icon: SkotiqIcons.warning,
          width: 480,
          actions: [
            SkotiqButton(
              onPressed: () => Navigator.of(context).pop(),
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
            SkotiqButton(
              onPressed: () {
                Navigator.of(context).pop();
                onProceed();
              },
              label: 'Proceed',
              variant: ButtonVariant.primary,
              size: ButtonSize.small,
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('The following warnings were found:'),
              const SizedBox(height: 8),
              ...validation.warnings.map((warning) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(SkotiqIcons.warning,
                            color: colors.warning, size: 20),
                        const SizedBox(width: 8),
                        Expanded(child: Text(warning)),
                      ],
                    ),
                  )),
              const SizedBox(height: 16),
              const Text('Do you want to proceed anyway?'),
            ],
          ),
        );
      },
    );
  }
}
