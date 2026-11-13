import 'dart:developer' as developer;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import '../../accessible_dropdown.dart';
import '../../stack_result/recent_stacks_panel.dart';
import '../../stack_result/stack_and_share_dialog.dart';
import 'osc_stacking_controls.dart';
import 'panel_widgets.dart';
import 'session_stack_plan.dart';

part 'stacking_panel/stack_and_share_entry.dart';
part 'stacking_panel/status_widgets.dart';
part 'stacking_panel/stacked_preview.dart';
part 'stacking_panel/osc_stacking_section.dart';

typedef StackingReferencePicker = Future<XFile?> Function();

Future<XFile?> _pickStackingReference() {
  const typeGroup = XTypeGroup(
    label: 'Image files',
    extensions: [...FrameFiles.all, 'tif', 'tiff', 'png'],
  );
  return openFile(acceptedTypeGroups: [typeGroup]);
}

final stackingReferencePickerProvider =
    Provider<StackingReferencePicker>((ref) => _pickStackingReference);

/// Picks the destination for a stacked master, returning null when the
/// operator cancels.
typedef StackingMasterDestinationPicker = Future<String?> Function(
    String suggestedName);

Future<String?> _pickStackingMasterDestination(String suggestedName) async {
  // Named for what is actually written: a FITS master of the integration, or
  // a PNG of the render for anyone who wants the picture. The chooser cannot
  // stop an operator typing a third extension, so
  // `LiveStackingService.saveMaster` refuses it rather than renaming the file
  // behind their back.
  const typeGroup = XTypeGroup(
    label: 'Stacked master (FITS, or PNG render)',
    extensions: ['fits', 'fit', 'fts', 'png'],
  );
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: [typeGroup],
  );
  return location == null ? null : collapseDoubledExtension(location.path);
}

final stackingMasterDestinationPickerProvider =
    Provider<StackingMasterDestinationPicker>(
        (ref) => _pickStackingMasterDestination);

/// What the operator chose when asked to end a session that has stacked
/// frames in it.
enum _StopDecision { saveMaster, discard, cancel }

class StackingPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  /// Whether the panel draws the stacked image itself.
  ///
  /// False when the Live stack tab is showing the stack on its own canvas —
  /// the picture belongs there, at a size worth looking at, and repeating it
  /// as a thumbnail beside the controls is the same frame twice. The narrow
  /// layout, which has no canvas beside the controls, keeps it.
  final bool showPreview;

  const StackingPanel({
    super.key,
    required this.colors,
    this.showPreview = true,
  });

  @override
  ConsumerState<StackingPanel> createState() => _StackingPanelState();
}

class _StackingPanelState extends ConsumerState<StackingPanel> {
  bool _isStarting = false;
  bool _isStopping = false;
  bool _isResetting = false;

  /// True from the moment Stop is pressed on a stack that has frames in it
  /// until the save/discard decision is resolved.
  bool _isEndingStack = false;

  /// Start, stop and reset sent to the host, each superseding its own
  /// earlier press; a host change drops them all.
  late final _operations = ref.backendScopes(alive: () => mounted);

  /// Whether the OSC config has already been seeded from the connected camera's
  /// capabilities. Guards the one-time camera-aware defaulting so a user who
  /// turns the colour switch back OFF is not overridden on the next rebuild.
  bool _oscDefaultsSeeded = false;

  /// Seed the OSC config once from a connected colour camera.
  ///
  /// When the camera reports a Bayer CFA and the colour config is still at its
  /// pristine mono default (the user has not touched it), default the colour
  /// mode to `auto` and preselect the camera's detected pattern. Runs at most
  /// once per panel lifetime and only while live stacking is idle (so it never
  /// rewrites the config of a session already in flight). The state mutation is
  /// deferred out of the build phase via a post-frame callback.
  void _maybeSeedOscDefaultsFromCamera(LiveStackingConfig config) {
    if (_oscDefaultsSeeded) return;

    // Only seed a pristine config: respect any explicit user choice.
    final isPristine = config.sensorMode.toLowerCase() == 'mono' &&
        config.bayerPattern == null;
    if (!isPristine) {
      _oscDefaultsSeeded = true;
      return;
    }

    if (ref.read(liveStackingProvider).status == LiveStackingStatus.running) {
      return; // Defer until the in-flight session ends.
    }

    final caps = _connectedCameraCapabilities();
    if (caps == null) {
      return; // No camera-derived hint yet; try again next build.
    }
    if (!caps.isColor) {
      // A mono camera is a definitive "no colour default" signal — stop trying.
      _oscDefaultsSeeded = true;
      return;
    }

    // Enable the colour path in `auto` mode and leave the Bayer override unset:
    // `auto` honours the pattern the reference frame declares via its FITS
    // BAYERPAT geometry (which the camera's reported pattern should agree with),
    // and the Bayer dropdown's Auto entry surfaces the detected pattern in its
    // label. Pinning an explicit override here would silently override the
    // frame's own geometry — the operator can still do so manually.
    _oscDefaultsSeeded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Re-check the live config: if the user toggled something between the
      // build and this callback, do not clobber their choice.
      final current = ref.read(liveStackingProvider).config;
      if (current.sensorMode.toLowerCase() != 'mono' ||
          current.bayerPattern != null) {
        return;
      }
      ref.read(liveStackingProvider.notifier).updateConfig(
            current.copyWith(sensorMode: 'auto'),
          );
    });
  }

  /// Stacks tonight's frames: the sharpest is the reference, the rest join in
  /// order, and every frame captured afterwards is added as it lands.
  Future<void> _stackSessionFrames(SessionStackPlan plan) => _start(
        (_) => ref.read(liveStackingProvider.notifier).startFromFrames(
              plan.referencePath,
              plan.framePaths,
              config: ref.read(liveStackingProvider).config,
            ),
      );

  /// Starts from a reference sub the operator picks on disk.
  Future<void> _stackFromChosenFile() => _start((stillCurrent) async {
        // The selection belongs to the backend that opened the native dialog;
        // reconnecting while it is open must never send that local path to
        // the new host.
        final file = await ref.read(stackingReferencePickerProvider)();
        if (file == null || !stillCurrent()) return;
        await ref.read(liveStackingProvider.notifier).startFromFile(
              file.path,
              config: ref.read(liveStackingProvider).config,
            );
      });

  /// Arms the host's stacker: there is no local reference file on a linked
  /// client, so the host's next captured frame becomes the reference and the
  /// frames after it are fed automatically.
  Future<void> _armHostStack() => _start(
        (_) => ref.read(liveStackingProvider.notifier).startRemote(
              config: ref.read(liveStackingProvider).config,
            ),
      );

  Future<void> _start(
    Future<void> Function(bool Function() stillCurrent) operation,
  ) async {
    if (_isStarting) return;
    final start = _operations.beginLatest(#start);
    setState(() => _isStarting = true);
    try {
      await operation(() => start.isCurrent);
    } catch (error) {
      if (!mounted || start.isStale) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not start live stacking: ${userFacingError(error)}',
          ),
        ),
      );
    } finally {
      if (start.isCurrent) setState(() => _isStarting = false);
    }
  }

  /// Ends the session. Stopping releases the native stacker and with it every
  /// stacked pixel, so a session that has frames in it is never released
  /// silently: the operator is asked, and can write the master out first.
  Future<void> _stopStacking() async {
    if (_isStopping || _isEndingStack) return;
    final frames = ref.read(liveStackingProvider).stats.stackedFrameCount;
    if (frames <= 0) {
      await _releaseStack();
      return;
    }

    setState(() => _isEndingStack = true);
    try {
      final decision = await _askBeforeDiscardingStack(frames);
      if (!mounted || decision != _StopDecision.saveMaster) {
        if (decision == _StopDecision.discard) await _releaseStack();
        return;
      }
      // Keep the stack running until the master is safely on disk: a cancelled
      // picker or a failed write must not cost the operator the integration.
      if (!await _saveStackedMaster(frames)) return;
      if (!mounted) return;
      await _releaseStack();
    } finally {
      if (mounted) setState(() => _isEndingStack = false);
    }
  }

  /// Confirmation shown before Stop releases a stack that has frames in it.
  Future<_StopDecision> _askBeforeDiscardingStack(int frames) async {
    final colors = widget.colors;
    final decision = await showDialog<_StopDecision>(
      context: context,
      builder: (dialogContext) => SkotiqDialog(
        title: 'Keep this stack?',
        icon: SkotiqIcons.layers,
        width: 460,
        actions: [
          SmallButton(
            label: 'Cancel',
            icon: SkotiqIcons.close,
            isOutline: true,
            colors: colors,
            onTap: () => Navigator.of(dialogContext).pop(_StopDecision.cancel),
          ),
          const SizedBox(width: 8),
          SmallButton(
            label: 'Discard',
            icon: SkotiqIcons.delete,
            isOutline: true,
            colors: colors,
            onTap: () => Navigator.of(dialogContext).pop(_StopDecision.discard),
          ),
          const SizedBox(width: 8),
          SmallButton(
            label: 'Save master',
            icon: SkotiqIcons.save,
            colors: colors,
            onTap: () =>
                Navigator.of(dialogContext).pop(_StopDecision.saveMaster),
          ),
        ],
        child: Text(
          'Stopping releases the stacker, and the '
          '${frames == 1 ? '1 stacked frame' : '$frames stacked frames'} '
          'accumulated so far cannot be recovered afterwards. Save the '
          'stacked master first — a FITS master carrying the integration time '
          'and frame count — or discard it and stop.',
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        ),
      ),
    );
    return decision ?? _StopDecision.cancel;
  }

  /// Writes the accumulated master out. Returns true only when a file was
  /// actually written (so the caller knows it is safe to release the stack).
  Future<bool> _saveStackedMaster(int frames) async {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final destination = await ref.read(
      stackingMasterDestinationPickerProvider,
    )('live_stack_${stamp}Z_${frames}frames.fits');
    if (!mounted || destination == null || destination.trim().isEmpty) {
      return false;
    }

    try {
      // A FITS master is registered in the master library as it is written,
      // so the Darkroom lists it under its target and opens it in the editor.
      final library = await ref.read(liveStackMasterLibraryProvider).save(
            destination,
            sourceFramePath: ref.read(liveStackingProvider).referenceImagePath,
          );
      final saved = library.saved;
      if (!mounted) return true;
      final integration = saved.totalIntegrationSecs;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Stacked master (${saved.stackedFrameCount} frames'
            '${integration != null && integration > 0 ? ', '
                '${integration.toStringAsFixed(0)} s integration' : ''}) '
            'saved to ${saved.filePath}'
            '${library.masterId == null ? '' : ' and added to the Darkroom'}',
          ),
        ),
      );
      return true;
    } on LiveStackingMasterFormatUnsupported catch (error) {
      // The operator typed a name in a format this stacker cannot write. Say
      // which one and why, instead of writing other bytes under their name and
      // letting them find out later.
      if (!mounted) return false;
      await ErrorDialog.show(
        context,
        title: 'That master cannot be written here',
        message: 'A "${error.requestedExtension}" master cannot be written: '
            '${error.reason}. The stack is still running and was not '
            'discarded.',
        technicalDetails: error.toString(),
      );
      return false;
    } catch (error) {
      if (!mounted) return false;
      await ErrorDialog.show(
        context,
        title: 'Could not save the stacked master',
        message: 'The stack is still running and was not discarded. Try a '
            'different destination, or discard the stack deliberately.',
        technicalDetails: error.toString(),
      );
      return false;
    }
  }

  Future<void> _releaseStack() async {
    if (_isStopping) return;
    final stop = _operations.beginLatest(#stop);
    setState(() => _isStopping = true);
    try {
      await ref.read(liveStackingProvider.notifier).stop();
    } catch (error) {
      if (!mounted || stop.isStale) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not stop live stacking: ${userFacingError(error)}')),
      );
    } finally {
      if (stop.isCurrent) setState(() => _isStopping = false);
    }
  }

  Future<void> _resetStack() async {
    if (_isResetting) return;
    final reset = _operations.beginLatest(#reset);
    setState(() => _isResetting = true);
    try {
      await ref.read(liveStackingProvider.notifier).reset();
    } catch (error) {
      if (!mounted || reset.isStale) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not reset live stacking: ${userFacingError(error)}')),
      );
    } finally {
      if (reset.isCurrent) setState(() => _isResetting = false);
    }
  }

  /// True while the Stack-and-Share selection preview is being computed (between
  /// the button press and the launcher dialog opening). Guards against a second
  /// concurrent press while the DB query is in flight.
  bool _isOpeningStackAndShare = false;

  /// The Stack & Share preview being prepared; a host change or a new imaging
  /// session drops it.
  late final _stackAndShareOpenings = ref.backendScopes(alive: () => mounted);

  /// The session the operator picked to stack when no run is imaging; null
  /// for the newest one.
  int? _pickedStackSessionId;

  /// The sessions Stack & Share can pick from when no run is imaging: those
  /// that took frames, newest first. A run's own session is the only choice
  /// while it images, and a linked client cannot run Stack & Share at all.
  List<ImagingSession> _pickableStackSessions() {
    if (ref.read(isRemoteModeProvider)) return const [];
    if (ref.read(sessionStateProvider).dbSessionId != null) return const [];
    final sessions = ref.read(allSessionsProvider).valueOrNull ?? const [];
    return [
      for (final session in sessions)
        if (session.totalExposures > 0) session,
    ];
  }

  /// The session Stack & Share stacks now: the imaging run's, else the one
  /// picked, else the newest that took frames.
  int? _stackSessionId() {
    final active = ref.read(sessionStateProvider).dbSessionId;
    if (active != null) return active;
    final pickable = _pickableStackSessions();
    for (final session in pickable) {
      if (session.id == _pickedStackSessionId) return session.id;
    }
    return pickable.isEmpty ? null : pickable.first.id;
  }

  /// Entry point for the **Stack-and-Share Loop** (component C10).
  ///
  /// Resolves the selection summary for [sessionId] up front so the launcher
  /// dialog can render the per-filter / integration preview the operator
  /// confirms, then opens [StackAndShareDialog]. Selection runs against the
  /// shared Drift instance via [stackLightSelectorProvider]; the dialog's own
  /// orchestrator re-selects internally when the run starts.
  ///
  /// Errors are surfaced, never swallowed: a session with no qualifying lights
  /// ([NoLightsToStackException]) or any other selection failure is shown via an
  /// [ErrorDialog] rather than silently opening an empty launcher.
  Future<void> _openStackAndShare(int sessionId) async {
    if (_isOpeningStackAndShare) return;
    if (ref.read(isRemoteModeProvider)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Stack & Share must be run on the imaging host in this release.',
          ),
        ),
      );
      return;
    }
    final opening = _stackAndShareOpenings.beginLatest();
    setState(() => _isOpeningStackAndShare = true);

    StackSelectionSummary? selection;
    Object? selectionError;
    try {
      selection = await ref.read(stackLightSelectorProvider).selectForSession(
            sessionId: sessionId,
            config: StackAndShareConfig.defaults,
          );
    } catch (e) {
      // Captured (not rethrown) so we can tear down the loading state in the
      // `finally` before presenting; the type is discriminated below to give the
      // "no lights" case its own actionable message.
      selectionError = e;
    } finally {
      if (_isCurrentStackAndShare(opening, sessionId)) {
        setState(() => _isOpeningStackAndShare = false);
      }
    }

    if (!mounted || !_isCurrentStackAndShare(opening, sessionId)) return;

    if (selectionError is NoLightsToStackException) {
      await ErrorDialog.show(
        context,
        title: 'Nothing to stack',
        message: 'No light frames in this session qualify for stacking. '
            'Capture some lights (and pass any quality gates) before running '
            'Stack & Share.',
        technicalDetails: selectionError.toString(),
      );
      return;
    }
    if (selectionError != null) {
      await ErrorDialog.show(
        context,
        title: 'Could not prepare stack',
        message: 'Selecting the light frames for this session failed.',
        technicalDetails: selectionError.toString(),
      );
      return;
    }

    if (!mounted || selection == null) return;
    await StackAndShareDialog.show(
      context,
      sessionId: sessionId,
      selection: selection,
    );
  }

  bool _isCurrentStackAndShare(
    AsyncScope<SkotiqBackend> opening,
    int sessionId,
  ) =>
      opening.isCurrent && _stackSessionId() == sessionId;

  String _startLabel(bool isRemoteMode, SessionStackPlan? plan) {
    if (isRemoteMode) return _isStarting ? 'Starting...' : 'Start stacking';
    if (plan == null) {
      return _isStarting ? 'Starting...' : 'Start from a file…';
    }
    return _isStarting ? 'Adding tonight\'s frames…' : 'Stack tonight\'s frames';
  }

  static String _sessionStackLine(SessionStackPlan? plan) {
    if (plan == null) {
      return 'No light frames from tonight on this computer yet. Start from '
          'a reference sub on disk, or take frames first.';
    }
    final count = plan.frameCount;
    final filter = plan.filter;
    final frames = [
      '$count',
      if (filter != null && filter.isNotEmpty) filter,
      count == 1 ? 'frame' : 'frames',
    ].join(' ');
    final hfr = plan.referenceHfr;
    final reference = hfr == null
        ? 'The newest is the reference'
        : 'The sharpest (HFR ${hfr.toStringAsFixed(2)}) is the reference';
    return '$frames from tonight. $reference, and new frames join as they '
        'land.';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null || identical(previous, next)) return;
      final hadPendingOperation = _isStarting ||
          _isStopping ||
          _isResetting ||
          _isEndingStack ||
          _isOpeningStackAndShare;
      if (!hadPendingOperation) return;
      _operations.cancelAll();
      _stackAndShareOpenings.cancelAll();
      setState(() {
        _isStarting = false;
        _isStopping = false;
        _isResetting = false;
        _isEndingStack = false;
        _isOpeningStackAndShare = false;
      });
    });
    ref.listen<int?>(
      sessionStateProvider.select((state) => state.dbSessionId),
      (previous, next) {
        if (!_isOpeningStackAndShare || previous == next) return;
        _stackAndShareOpenings.cancelAll();
        setState(() => _isOpeningStackAndShare = false);
      },
    );
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    final plan = ref.watch(sessionStackPlanProvider);
    final stackState = ref.watch(liveStackingProvider);
    final isRunning = stackState.status == LiveStackingStatus.running;
    final isError = stackState.status == LiveStackingStatus.error;
    final stats = stackState.stats;
    final config = stackState.config;

    // `avgMatchedPairs` / `avgAlignmentResidual` are per-ALIGNED-frame metrics:
    // the stacker (imaging/src/stacking.rs) averages them over
    // `stacked_frame_count - 1`, because the reference frame is not matched
    // against itself and has zero residual by construction. So with no stack
    // running, or with only the reference frame in, both fields still hold
    // their 0.0 initialiser — and "Average alignment residual 0.00 px" reads as
    // sub-pixel-perfect registration rather than "nothing measured yet".
    final hasAlignedFrames = stats.stackedFrameCount > 1;

    // Seed the OSC defaults from a connected colour camera: when the camera
    // reports a Bayer mosaic and the user has not yet touched the colour config,
    // default the colour mode ON and preselect the detected pattern. Wired here
    // (not in the OSC section's build) so the seeding never mutates state during
    // a descendant's build.
    _maybeSeedOscDefaultsFromCamera(config);

    ref.watch(sessionStateProvider.select((state) => state.dbSessionId));
    ref.watch(allSessionsProvider);
    final stackSessionId = _stackSessionId();

    return SingleChildScrollView(
      padding: SkotiqTokens.paddingLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: SkotiqTokens.spaceLg,
            runSpacing: SkotiqTokens.spaceSm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Live stack',
                  style: SkotiqTypography.sectionTitle
                      .copyWith(color: widget.colors.textPrimary)),
              _StackAndShareEntry(
                sessionId: stackSessionId,
                pickable: _pickableStackSessions(),
                liveStackingActive: isRunning,
                isBusy: _isOpeningStackAndShare,
                isRemoteMode: isRemoteMode,
                onSessionPicked: (id) =>
                    setState(() => _pickedStackSessionId = id),
                onPressed: stackSessionId == null || isRemoteMode
                    ? null
                    : () => _openStackAndShare(stackSessionId),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),

          if (stackState.errorMessage != null)
            _ErrorBanner(
              message: stackState.errorMessage!,
              colors: widget.colors,
              onRetry: isRemoteMode && isRunning
                  ? () => ref
                      .read(liveStackingProvider.notifier)
                      .retryRemotePolling()
                  : null,
            ),

          SkotiqPanel(
            head: PanelHead(label: 'Live stacking'),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Status',
                        style: SkotiqTypography.caption
                            .copyWith(color: widget.colors.textSecondary)),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: isRunning
                                ? widget.colors.success
                                : isError
                                    ? widget.colors.error
                                    : widget.colors.textMuted,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isRunning
                              ? stats.filter == null
                                  ? 'Stacking'
                                  : 'Stacking ${stats.filter}'
                              : isError
                                  ? 'Error'
                                  : 'Idle',
                          style: SkotiqTypography.labelSm.copyWith(
                              color: isRunning
                                  ? widget.colors.success
                                  : isError
                                      ? widget.colors.error
                                      : widget.colors.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                if (isRemoteMode || !isRunning)
                  Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    isRemoteMode
                        ? 'Stacking runs on the imaging host. Press Start to '
                            'arm it — the next captured frame becomes the '
                            'reference and every frame after is stacked '
                            'automatically, even while this device is asleep.'
                        : _sessionStackLine(plan),
                    style: SkotiqTypography.caption
                        .copyWith(color: widget.colors.textMuted),
                  ),
                ),

                Wrap(
                  spacing: SkotiqTokens.spaceSm,
                  runSpacing: SkotiqTokens.spaceSm,
                  // Idle offers the ways to start; a running stack offers the
                  // ways to end or restart it.
                  children: [
                    if (!isRunning)
                      SkotiqButton(
                        label: _startLabel(isRemoteMode, plan),
                        icon: SkotiqIcons.layers,
                        isLoading: _isStarting,
                        onPressed: _isStarting
                            ? null
                            : isRemoteMode
                                ? _armHostStack
                                : plan != null
                                    ? () => _stackSessionFrames(plan)
                                    : _stackFromChosenFile,
                      ),
                    if (!isRemoteMode && plan != null && !isRunning)
                      SkotiqButton(
                        label: 'Choose a file…',
                        icon: SkotiqIcons.folderOpen,
                        variant: ButtonVariant.ghost,
                        onPressed: _isStarting ? null : _stackFromChosenFile,
                      ),
                    if (isRunning)
                      SkotiqButton(
                        label: _isStopping ? 'Stopping...' : 'Stop',
                        icon: SkotiqIcons.stop,
                        variant: ButtonVariant.secondary,
                        onPressed: !_isStopping && !_isEndingStack
                            ? _stopStacking
                            : null,
                      ),
                    if (isRunning)
                      SkotiqButton(
                        label: _isResetting ? 'Resetting...' : 'Reset stack',
                        icon: SkotiqIcons.refresh,
                        variant: ButtonVariant.ghost,
                        onPressed: !_isResetting ? _resetStack : null,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          if (isRunning && stats.otherFilterNote != null)
            Padding(
              padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
              child: SkotiqBanner(
                title: stats.otherFilterFrames == 1
                    ? '1 frame left out'
                    : '${stats.otherFilterFrames} frames left out',
                message: stats.otherFilterNote!,
                tone: BannerTone.info,
              ),
            ),

          SkotiqPanel(
            head: PanelHead(label: 'Statistics'),
            child: Column(
              children: [
                ReadoutRow(
                  children: [
                    Readout(
                        value: _frames(stats.stackedFrameCount),
                        label: 'Stacked frames'),
                    Readout(
                        value: _frames(stats.totalFramesAttempted),
                        label: 'Total attempted'),
                    Readout(
                        value: _frames(stats.rejectedAlignmentFailures),
                        label: 'Rejected (alignment)',
                        valueColor: stats.rejectedAlignmentFailures > 0
                            ? widget.colors.warning
                            : null),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
                _StatRow(
                  label: 'Average matched pairs',
                  value: hasAlignedFrames
                      ? '${stats.avgMatchedPairs.toStringAsFixed(1)} stars'
                      : '—',
                  colors: widget.colors,
                ),
                const SizedBox(height: 8),
                _StatRow(
                  label: 'Average alignment residual',
                  value: hasAlignedFrames
                      ? '${stats.avgAlignmentResidual.toStringAsFixed(2)} px'
                      : '—',
                  colors: widget.colors,
                ),
                // The rows below count PIXELS, not frames. Without the break
                // and the units, "Sigma-Rejected 7.3M" under "Stacked Frames
                // 36" reads as 7.3 million discarded frames.
                _StatGroupHeader(
                  label: 'Pixels rejected by sigma clipping',
                  colors: widget.colors,
                ),
                _StatRow(
                  label: 'Sigma rejected (total)',
                  value: _pixels(stats.totalSigmaRejectedPixels),
                  colors: widget.colors,
                ),
                const SizedBox(height: 8),
                _StatRow(
                  label: 'Sigma rejected (last frame)',
                  value: _pixels(stackState.lastFrameSigmaRejectedPixels),
                  valueColor: _rejectionRateColor(
                      stackState.lastFrameSigmaRejectionRate, widget.colors),
                  colors: widget.colors,
                ),
                const SizedBox(height: 8),
                _StatRow(
                  label: 'Rejection rate (last frame)',
                  value: stackState.lastFrameTotalPixels > 0
                      ? '${(stackState.lastFrameSigmaRejectionRate * 100).toStringAsFixed(2)}%'
                      : '—',
                  valueColor: _rejectionRateColor(
                      stackState.lastFrameSigmaRejectionRate, widget.colors),
                  colors: widget.colors,
                ),
                if (stackState.lastFrameTotalPixels > 0 &&
                    stackState.lastFrameSigmaRejectionRate >
                        _rejectionWarningThreshold) ...[
                  const SizedBox(height: 10),
                  _RejectionWarning(
                    rate: stackState.lastFrameSigmaRejectionRate,
                    colors: widget.colors,
                  ),
                ],
                const SizedBox(height: 12),
                _AlignmentQualityBar(
                  stats: stats,
                  colors: widget.colors,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          if (widget.showPreview &&
              stackState.previewData != null &&
              stackState.previewWidth > 0 &&
              stackState.previewHeight > 0)
            SkotiqPanel(
              head: PanelHead(label: 'Stacked preview'),
              child: _StackedPreview(
                previewData: stackState.previewData!,
                width: stackState.previewWidth,
                height: stackState.previewHeight,
                channels: _previewChannels(stackState),
                stretch: ref.watch(stackedPreviewStretchProvider),
                colors: widget.colors,
              ),
            ),

          if (widget.showPreview && stackState.previewData != null)
            const SizedBox(height: 20),

          const RecentStacksPanel(),
          const SizedBox(height: 20),

          SkotiqPanel(
            head: PanelHead(label: 'Sigma clipping'),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Enabled',
                        style: SkotiqTypography.caption
                            .copyWith(color: widget.colors.textSecondary)),
                    SkotiqSwitch(
                      value: config.sigmaClipEnabled,
                      onChanged: (value) {
                        ref.read(liveStackingProvider.notifier).updateConfig(
                              config.copyWith(sigmaClipEnabled: value),
                            );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SliderRowInteractive(
                  label: 'Threshold',
                  value: config.sigmaClipThreshold,
                  min: 1.0,
                  max: 5.0,
                  suffix: '\u03c3',
                  colors: widget.colors,
                  onChanged: config.sigmaClipEnabled
                      ? (value) {
                          ref.read(liveStackingProvider.notifier).updateConfig(
                                config.copyWith(sigmaClipThreshold: value),
                              );
                        }
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Color (OSC) config — debayer Bayer CFA frames to RGB before
          // integrating. Defaults are camera-aware: a connected colour camera
          // pre-selects the switch ON and the detected Bayer pattern.
          _OscStackingSection(
            config: config,
            colors: widget.colors,
            cameraCapabilities: _connectedCameraCapabilities(),
            onConfigChanged: (next) =>
                ref.read(liveStackingProvider.notifier).updateConfig(next),
          ),
          const SizedBox(height: 20),

          SkotiqPanel(
            head: PanelHead(label: 'Star matching'),
            child: Column(
              children: [
                InputRowEditable(
                  label: 'Max stars',
                  value: config.maxMatchStars.toString(),
                  colors: widget.colors,
                  onChanged: (value) {
                    final parsed = int.tryParse(value);
                    if (parsed != null && parsed > 0) {
                      ref.read(liveStackingProvider.notifier).updateConfig(
                            config.copyWith(maxMatchStars: parsed),
                          );
                    }
                  },
                ),
                const SizedBox(height: 12),
                SliderRowInteractive(
                  label: 'Match radius',
                  value: config.matchRadiusPx,
                  min: 5.0,
                  max: 200.0,
                  suffix: 'px',
                  colors: widget.colors,
                  onChanged: (value) {
                    ref.read(liveStackingProvider.notifier).updateConfig(
                          config.copyWith(matchRadiusPx: value),
                        );
                  },
                ),
                const SizedBox(height: 12),
                SliderRowInteractive(
                  label: 'Flux tolerance',
                  value: config.matchFluxTolerance,
                  min: 0.1,
                  max: 1.0,
                  suffix: '',
                  colors: widget.colors,
                  onChanged: (value) {
                    ref.read(liveStackingProvider.notifier).updateConfig(
                          config.copyWith(matchFluxTolerance: value),
                        );
                  },
                ),
                const SizedBox(height: 12),
                InputRowEditable(
                  label: 'Min pairs',
                  value: config.minMatchedPairs.toString(),
                  colors: widget.colors,
                  onChanged: (value) {
                    final parsed = int.tryParse(value);
                    if (parsed != null && parsed > 0) {
                      ref.read(liveStackingProvider.notifier).updateConfig(
                            config.copyWith(minMatchedPairs: parsed),
                          );
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Channel layout of the current stacked preview, derived from the buffer
  /// length relative to the pixel count.
  ///
  /// The live stacker emits a single luminance plane (`width * height` u16
  /// samples) for a mono session and an interleaved RGB16 buffer
  /// (`width * height * 3`) for an OSC session. `LiveStackingState` does not
  /// carry the channel count separately, so we recover it from the geometry the
  /// same way the Stack-and-Share orchestrator validates it. Any length that is
  /// neither 1- nor 3-channel returns `1` so the grayscale path renders the
  /// luminance the engine actually produced rather than misreading bytes as RGB.
  int _previewChannels(LiveStackingState state) {
    final pixelCount = state.previewWidth * state.previewHeight;
    if (pixelCount <= 0) return 1;
    final data = state.previewData;
    if (data != null && data.length == pixelCount * 3) return 3;
    return 1;
  }

  /// Capabilities of the currently connected camera, or null when none is
  /// connected / the query is still in flight / the driver did not report.
  ///
  /// Used by the OSC section to default the colour switch ON for a colour
  /// camera and to pre-select its detected Bayer pattern. A null result simply
  /// means "no camera-derived default" — the controls fall back to the config's
  /// own (mono) defaults, never a guessed colour layout.
  CameraCapabilities? _connectedCameraCapabilities() {
    final deviceId = ref.watch(connectedCameraIdProvider);
    if (deviceId == null || deviceId.isEmpty) return null;
    final caps = ref.watch(equipmentCameraCapabilitiesProvider(deviceId));
    return caps.maybeWhen(
      data: (value) => value,
      orElse: () => null,
    );
  }

  String _formatLargeNumber(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    } else if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    return value.toString();
  }

  /// A frame count, carrying its unit so it cannot be read as pixels.
  String _frames(int value) => '$value frames';

  /// A pixel count, carrying its unit so it cannot be read as frames.
  String _pixels(int value) => '${_formatLargeNumber(value)} px';

  /// Resolve the value-color for a sigma-rejection rate based on the
  /// per-frame thresholds (`_rejectionWarningThreshold` /
  /// `_rejectionErrorThreshold`). Returns `null` for healthy rates so the
  /// stat row uses the default text color.
  Color? _rejectionRateColor(double rate, SkotiqColors colors) {
    if (rate >= _rejectionErrorThreshold) return colors.error;
    if (rate >= _rejectionWarningThreshold) return colors.warning;
    return null;
  }
}

/// Per-frame sigma-rejection rate at which we paint the stat in the warning
/// color. Above ~5% on a single frame usually indicates drift, a satellite
/// trail, clouds, or a tracking glitch -- worth flagging to the user.
const double _rejectionWarningThreshold = 0.05;

/// Per-frame sigma-rejection rate at which we escalate to the error color
/// and show the alert banner. Above ~15% the frame is contributing far more
/// noise than signal -- typically a stale or fundamentally unusable frame.
const double _rejectionErrorThreshold = 0.15;
