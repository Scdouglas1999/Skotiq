part of '../sequence_executor.dart';

extension _SequenceExecutorEventOperations on SequenceExecutor {
  void _handleSequencerEvent(SkotiqEvent raw) {
    // Rate-limited per event type, so a chatty type collapses while a rare one
    // is still traced the moment it arrives.
    final trace = _eventTraceLimiter.admit(
      '${raw.category.name}/${raw.eventType}',
      'Received event: type=${raw.eventType}, category=${raw.category}',
    );
    if (trace != null) {
      _logger.debug(trace, source: 'SequenceExecutor');
    }

    final event = SequencerRunEvent.fromSkotiqEvent(raw);
    if (event == null) return;

    // The one place a dither is counted: native reports each dither once,
    // whoever asked for it. It is a count, not node progress.
    if (event is DitherPerformed) {
      _stats.update((stats) => stats.recordDither());
      return;
    }

    applyRunEventToNodeExposureTally(
      _ref.read(nodeExposureTallyProvider.notifier),
      event,
    );
    // Authorship rows precede the cause-neutral cancel notice, so they are
    // folded as they arrive.
    recordRunEventStopEvidence(_ref.read, event);

    final progressNotifier = _ref.read(sequenceProgressProvider.notifier);
    switch (event) {
      case NodeStarted():
        _onNodeStarted(event, progressNotifier);
      case NodeCompleted():
        _onNodeCompleted(event, progressNotifier);
      case ExposureStarted():
        _onExposureStarted(event, progressNotifier);
      case ExposureCompleted():
        _onExposureCompleted(event, progressNotifier);
      case ExposureCountProgress(:final current, :final total):
        progressNotifier.updateProgress(
          completedExposures: current ?? 0,
          message: 'Progress: ${current ?? 0}/${total ?? 0} exposures',
        );
      case TargetChanged(:final targetName, :final ra, :final dec):
        progressNotifier.updateProgress(
          currentTarget: targetName,
          message: targetName != null ? 'Started target: $targetName' : null,
        );
        if (targetName != null && ra != null && dec != null) {
          _logger.debug(
            'Target changed: $targetName (RA=${ra.toStringAsFixed(4)}h, '
            'Dec=${dec.toStringAsFixed(4)}°)',
            source: 'SequenceExecutor',
          );
          _ref
              .read(sessionStateProvider.notifier)
              .updateTargetCoordinates(ra: ra, dec: dec);
        }
      case TargetCompleted(:final targetName):
        progressNotifier.updateProgress(
          message: 'Completed target: ${targetName ?? 'unknown'}',
        );
      case SequencerError():
        _onSequencerError(event, progressNotifier);
      case StructuredInstructionProgress():
        _onStructuredProgress(event, progressNotifier);
      case InstructionProgress():
        _onInstructionProgress(event, progressNotifier);
      case MeridianFlipOutcome():
        _handleMeridianFlipOutcome(event);
      case TriggerFired():
        _onTriggerFired(event, progressNotifier);
      case RunStarted():
        // A new run answers for itself: the previous run's stop cause must not
        // be read as this one's.
        _ref.read(sequenceStopEvidenceProvider.notifier).state = null;
        _setExecutionState(SequenceExecutionState.running);
      case RunPaused():
        _setExecutionState(SequenceExecutionState.paused);
      case RunResumed():
        _setExecutionState(SequenceExecutionState.running);
      case RunCompleted():
        _onTerminalEvent(SequenceExecutionState.completed, 'completed');
      case RunFailed(:final error):
        _onTerminalEvent(
          SequenceExecutionState.failed,
          'failed',
          error: error ?? 'Unknown error',
        );
      case RunStopped():
        _onNativeStopped();
      case FrameAccepted():
        _recordGradedFrame(event);
        _registerSequenceFrame(event, grade: 'pass');
        _maybeFeedLiveStacking(event);
      case FrameRejected(:final rejectPath):
        _recordGradedFrame(event);
        // The folder rejects pile up in is what an operator opens after a
        // reject storm, so the run record names the grader's own directory.
        final rejectFolder = rejectPath == null
            ? null
            : parentDirectoryOf(rejectPath);
        if (rejectFolder != null) {
          _stats.update((stats) => stats.recordRejectFolder(rejectFolder));
        }
        _registerSequenceFrame(event, grade: 'reject');
      case PluginNodeRequested():
        _dispatchPluginNode(event);
      case PluginNodeProgress(:final pluginId, :final nodeTypeId):
        _logger.debug(
          'PluginNodeProgress: ${pluginId ?? ''}/${nodeTypeId ?? ''} '
          '${event.detailJson ?? ''}',
          source: 'SequenceExecutor',
        );
      case DepthGoalCompleted():
        _persistDepthGoalDecision(event);
      case DecisionLogged():
        _persistReplayDecision(event);
      case DitherPerformed() || RunCancelled() || UnrecognizedSequencerEvent():
        break;
    }
  }

  void _onNodeStarted(
    NodeStarted event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final nodeId = event.nodeId;
    if (nodeId != null) {
      progressNotifier.updateProgress(
        currentNodeId: nodeId,
        currentNodeName: event.nodeType,
        currentNodeStatus: NodeStatus.running,
      );
      progressNotifier.updateNodeStatus(nodeId, NodeStatus.running);
    }
    // Frame indices restart at 1 for every node, so a verdict an aborted burst
    // never completed must not survive into this node's frame 1.
    _gradedFrames.clear();
  }

  void _onNodeCompleted(
    NodeCompleted event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final nodeId = event.nodeId;
    if (nodeId == null) return;
    final status = event.status ?? 'failed';
    final nodeStatus = event.nodeStatus ?? NodeStatus.failure;
    progressNotifier.updateNodeStatus(nodeId, nodeStatus);
    // An autofocus is counted by what the node did (its structured progress
    // was an Autofocus detail), never by its operator-editable name.
    if (nodeStatus == NodeStatus.success && _nodeRanAutofocus(nodeId)) {
      _stats.update((stats) => stats.recordAutofocus());
      _noteAutofocusOutcomeForBacklashOffer();
    }
    // A status Dart has not learned yet reads as a failure; carry the raw
    // string so the red node explains itself.
    if (!NodeCompleted.knownStatuses.contains(status)) {
      _logger.warning(
        'NodeCompleted with unknown status "$status" for node '
        '$nodeId; treating as failure.',
        source: 'SequenceExecutor',
      );
      progressNotifier.updateNodeProgress(
        nodeId,
        0.0,
        'Unknown node status: "$status"',
      );
    }
  }

  void _onExposureStarted(
    ExposureStarted event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final frame = event.frame ?? 0;
    final total = event.total ?? 0;
    final exposureDetail = formatExposureStartedDetail(
      frame,
      total,
      event.filter,
    );
    progressNotifier.updateProgress(
      message: 'Exposing $exposureDetail',
      currentFilter: event.filter,
    );
    final nodeId = _ref.read(sequenceProgressProvider).currentNodeId;
    if (nodeId != null && total > 0) {
      // frame - 1: this frame has only just started.
      progressNotifier.updateNodeProgress(
        nodeId,
        (frame - 1) / total * 100.0,
        exposureDetail,
      );
    }
  }

  void _onExposureCompleted(
    ExposureCompleted event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final frame = event.frame ?? 0;
    final total = event.total ?? 1;
    final durationSecs = event.durationSecs ?? 0.0;
    // A graded frame was already counted and shown when its verdict arrived
    // (see [_gradedFrames]); an ungraded one (no save path, so no grader) is
    // counted here as accepted.
    final graded = _gradedFrames.remove(frame);
    if (graded == null) {
      _recordRunFrame(
        exposureSecs: durationSecs,
        filter: event.filter,
        accepted: true,
      );
    }
    // The ETA is fed shutter-open time plus a fixed download overhead, not the
    // wall clock between frames, so autofocus and slew stalls do not skew it.
    if (durationSecs > 0) {
      final defaults = _ref.read(sequencerDefaultsProvider);
      _eta.recordFrame(durationSecs + defaults.frameDownloadOverheadSecs);
    }
    progressNotifier.updateProgress(completedExposures: frame);
    // Keyed on the originating event: the DeviceService pump sees the same
    // event, and only one of the two may add its shutter time.
    progressNotifier.recordCompletedFrameIntegration(
      eventKey: '${event.timestamp}:$frame',
      durationSecs: durationSecs,
    );
    final nodeId = _ref.read(sequenceProgressProvider).currentNodeId;
    if (nodeId != null) {
      progressNotifier.updateNodeProgress(
        nodeId,
        total > 0 ? (frame / total * 100.0) : 100.0,
        formatExposureCompletedDetail(frame, total),
      );
    }
    if (graded == null) {
      _fetchAndDisplaySequenceImage(
        _previewSettingsForFrame(null, durationSecs),
      );
    }
  }

  void _onSequencerError(
    SequencerError event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final message = event.message ?? 'Unknown error';
    // An advisory shares the Error payload; it is a warning on the run, never
    // a fault on a node.
    if (event.isAdvisory) {
      _surfaceRunWarning(message);
      progressNotifier.updateProgress(message: message);
      return;
    }
    // Older native executors acknowledged SkipToNode through Error. It is an
    // informational success.
    if (message.startsWith('SkipToNode request accepted:')) {
      progressNotifier.updateProgress(message: message);
      return;
    }
    // Every cancellation path emits the same notice, so it is a stop whose
    // cause comes from the run's authorship rows, not an error.
    if (isSequenceCancelledNotice(message)) {
      final stopped = sequenceStoppedMessage(
        _ref.read(sequenceStopEvidenceProvider),
      );
      _logger.info(
        '[$kStopClassificationLogTag] sequence_executor: cancellation '
        'notice treated as a stop, not an error ($stopped)',
        source: 'SequenceExecutor',
      );
      progressNotifier.updateProgress(message: stopped);
      return;
    }
    _recordRunError(message);
    progressNotifier.updateProgress(message: 'Error: $message');
    final nodeId = _ref.read(sequenceProgressProvider).currentNodeId;
    if (nodeId != null) {
      progressNotifier.updateNodeProgress(nodeId, 0.0, 'Error: $message');
    }
    _escalateRunningToRecovering();
  }

  /// A mid-run fault is not terminal (recovery may still salvage the run), but
  /// a healthy `running` would be a lie, so `running` alone moves to
  /// `recovering`; the terminal event settles it later.
  void _escalateRunningToRecovering() {
    if (_ref.read(sequenceExecutionStateProvider) ==
        SequenceExecutionState.running) {
      _setExecutionState(SequenceExecutionState.recovering);
    }
  }

  void _onStructuredProgress(
    StructuredInstructionProgress event,
    SequenceProgressNotifier progressNotifier,
  ) {
    // A Change Filter instruction is the only place the running filter is
    // named when the exposure node itself has none.
    final filterName = event.changedFilterName;
    if (filterName != null) {
      progressNotifier.updateProgress(currentFilter: filterName);
    }
    final nodeId =
        event.nodeId ?? _ref.read(sequenceProgressProvider).currentNodeId;
    if (nodeId != null) {
      progressNotifier.updateNodeStructuredProgress(
        nodeId,
        event.progressPercent ?? 0.0,
        event.detail,
      );
      progressNotifier.updateProgress(
        message: '${event.instruction ?? ''}: ${event.detailKind}',
      );
    }
  }

  void _onInstructionProgress(
    InstructionProgress event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final instruction = event.instruction ?? '';
    final percent = event.progressPercent ?? 0.0;
    final detail = event.detail ?? '';
    _logger.debug(
      'InstructionProgress: nodeId=${event.nodeId}, instruction=$instruction, '
      'progress=$percent%, detail=$detail',
      source: 'SequenceExecutor',
    );
    final nodeId =
        event.nodeId ?? _ref.read(sequenceProgressProvider).currentNodeId;
    _logger.debug(
      'Updating node progress for: $nodeId',
      source: 'SequenceExecutor',
    );
    if (nodeId != null) {
      progressNotifier.updateNodeProgress(nodeId, percent, detail);
      progressNotifier.updateProgress(message: '$instruction: $detail');
    }
  }

  void _onTriggerFired(
    TriggerFired event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final triggerName = event.triggerName ?? 'Unknown trigger';
    final action = event.action ?? '';
    _stats.update((stats) => stats.recordTriggerFire());
    // A target dropped by its own end_when costs the operator a whole target,
    // so it goes on the run record, not only into the trigger feed.
    if (isTargetEndWhenSkip(event.triggerId ?? '')) {
      final warning = targetEndWhenSkipWarning(triggerName);
      _logger.warning(warning, source: 'SequenceExecutor');
      _stats.update((stats) => stats.recordWarning(warning));
      progressNotifier.updateProgress(message: warning);
      return;
    }
    _logger.info(
      'Trigger fired: $triggerName -> $action',
      source: 'SequenceExecutor',
    );
    progressNotifier.updateProgress(
      message: 'Trigger "$triggerName" fired: $action',
    );
  }

  /// A native `Stopped` this executor did not command came from the native
  /// side (a trigger's park, a watchdog, a safety abort) and is filed
  /// `aborted`; only a stop the wire attributes to the operator stays
  /// `stopped`. The echo of this executor's own stop() is swallowed by the
  /// finalization it already claimed.
  void _onNativeStopped() {
    final stopEvidence = _ref.read(sequenceStopEvidenceProvider);
    final operatorStopped =
        stopEvidence?.author == SequenceStopAuthor.operatorPress;
    _onTerminalEvent(
      SequenceExecutionState.idle,
      operatorStopped ? 'stopped' : 'aborted',
      warning: operatorStopped || stopEvidence == null
          ? null
          : sequenceStoppedMessage(stopEvidence),
    );
  }

  /// Persist a `DepthGoalCompleted` payload as a `budget_met` decision row.
  ///
  /// `budget_met` rather than a category of its own: a depth goal IS the
  /// budget for a plan bound to one, and the replay feed already renders that
  /// bucket as "the plan stopped because it had enough". Fire-and-forget for
  /// the same reason as [_persistReplayDecision] — the executor's event loop
  /// must keep pumping.
  void _persistDepthGoalDecision(DepthGoalCompleted event) {
    final runId = _ref.read(currentRunIdProvider);
    if (runId == null) {
      _logger.debug(
        'DepthGoalCompleted dropped: no active sequence_run_id '
        '(goal ${event.goalId})',
        source: 'SequenceExecutor',
      );
      return;
    }
    final filterName = event.filterName ?? '';
    final score = event.score ?? 0;
    final threshold = event.threshold ?? 0;
    final evidenceFrames = event.evidenceFrames ?? 0;
    final confirmationFrames = event.confirmationFrames ?? 0;
    final summary = depthGoalCompletedDetail(
      filterName: filterName,
      score: score,
      threshold: threshold,
      evidenceFrames: evidenceFrames,
      confirmationFrames: confirmationFrames,
    );
    _logger.info(summary, source: 'SequenceExecutor');
    final service = _ref.read(replayDebugServiceProvider);
    unawaited(
      service
          .persistFromBridgeEvent(
            timestampIso: DateTime.fromMillisecondsSinceEpoch(
              event.timestamp,
            ).toUtc().toIso8601String(),
            categoryWireKey: DecisionCategory.budgetMet.wireKey,
            summary: summary,
            detailsJson: jsonEncode({
              'goal_id': event.goalId,
              'revision': event.revision,
              'filter_name': filterName,
              'score': score,
              'threshold': threshold,
              'evidence_frames': evidenceFrames,
              'confirmation_frames': confirmationFrames,
            }),
            nodeId: event.nodeId,
            sequenceRunId: runId,
          )
          .catchError((Object e, StackTrace st) {
            _logger.warning(
              'Failed to persist depth-goal decision ($summary): $e',
              source: 'SequenceExecutor',
            );
            return -1;
          }),
    );
  }

  /// Replay Debug — persist a `DecisionLogged` payload into
  /// the `sequence_decisions` table via the [ReplayDebugService].
  /// `unawaited` because the executor's event loop must keep pumping;
  /// the service handles its own change-notification, and a write
  /// failure is logged at warn-level (loud-fail policy without
  /// taking the executor down).
  void _persistReplayDecision(DecisionLogged event) {
    final timestampIso = event.timestampIso ?? '';
    final category = event.category ?? '';
    final summary = event.summary ?? '';
    final detailsJson = event.detailsJson ?? '{}';
    final nodeId = event.nodeId;
    final rustRunId = event.sequenceRunId;
    final effectiveRunId = rustRunId ?? _ref.read(currentRunIdProvider);
    if (effectiveRunId == null) {
      // No active run id — the very first lifecycle "Sequence started"
      // decision falls into this window before the Dart row insert
      // completes. We intentionally drop these so the replay log never
      // has dangling rows that can't be joined back to a run.
      _logger.debug(
        'DecisionLogged dropped: no active sequence_run_id '
        '($category: $summary)',
        source: 'SequenceExecutor',
      );
      return;
    }
    final service = _ref.read(replayDebugServiceProvider);
    unawaited(
      service
          .persistFromBridgeEvent(
            timestampIso: timestampIso,
            categoryWireKey: category,
            summary: summary,
            detailsJson: detailsJson,
            nodeId: nodeId,
            sequenceRunId: effectiveRunId,
          )
          .catchError((Object e, StackTrace st) {
            _logger.warning(
              'Failed to persist replay decision ($category: $summary): $e',
              source: 'SequenceExecutor',
            );
            return -1;
          }),
    );
  }

  /// Route a `PluginNodeRequested` event into the
  /// configured dispatcher and post the verdict back through the
  /// bridge.
  ///
  /// Implementation contract:
  ///   * The dispatcher MUST not throw. If it does (e.g. provider
  ///     overrides went wrong), we still post a failure verdict so
  ///     the executor unblocks instead of timing out at the 10-minute
  ///     default.
  ///   * The verdict is posted via
  ///     `backend.sequencerPluginNodeFinished` — same channel pattern
  ///     as every other sequencer command.
  ///   * We fire-and-forget; the caller (`_handleSequencerEvent`)
  ///     returns immediately so other events keep flowing.
  void _dispatchPluginNode(PluginNodeRequested event) {
    final nodeId = event.nodeId ?? '';
    final pluginId = event.pluginId ?? '';
    final nodeTypeId = event.nodeTypeId ?? '';
    final configJson = event.configJson ?? '';
    final displayName = event.displayName;
    final timeoutSecs = event.timeoutSecs ?? 600;

    if (nodeId.isEmpty) {
      _logger.warning(
        'PluginNodeRequested event missing node_id; cannot dispatch '
        '(plugin=$pluginId, node_type=$nodeTypeId)',
        source: 'SequenceExecutor',
      );
      return;
    }

    final backend = _backend;
    if (!backend.dispatchPluginNodesLocally) {
      _logger.debug(
        'PluginNodeRequested ignored locally because the backend '
        'delegates plugin dispatch to the remote host '
        '(plugin=$pluginId, node_type=$nodeTypeId, node_id=$nodeId)',
        source: 'SequenceExecutor',
      );
      return;
    }

    final coordinator = _ref.read(pluginNodeDispatchCoordinatorProvider);
    if (!coordinator.claim(nodeId)) {
      _logger.debug(
        'PluginNodeRequested ignored because another local listener is '
        'already dispatching node_id=$nodeId',
        source: 'SequenceExecutor',
      );
      return;
    }
    final dispatcher = _ref.read(pluginNodeDispatcherProvider);

    unawaited(() async {
      late PluginNodeDispatchResult result;
      try {
        result = await dispatcher(
          PluginNodeDispatchRequest(
            nodeId: nodeId,
            pluginId: pluginId,
            nodeTypeId: nodeTypeId,
            configJson: configJson,
            displayName: displayName,
            timeoutSecs: timeoutSecs,
          ),
        );
      } catch (e, st) {
        _logger.error(
          'Plugin node dispatcher threw for $pluginId/$nodeTypeId '
          '(node_id=$nodeId): $e\n$st',
          source: 'SequenceExecutor',
        );
        result = PluginNodeDispatchResult(
          success: false,
          message: 'dispatcher threw: $e',
        );
      }

      try {
        await backend.sequencerPluginNodeFinished(
          nodeId: nodeId,
          success: result.success,
          message: result.message,
          structuredDetailJson: result.structuredDetailJson,
        );
      } catch (e, st) {
        // The reply itself failed. The Rust executor will time out
        // the node at the configured timeout and surface its own
        // error — but we log loudly here so the operator sees the
        // cause-of-cause.
        _logger.error(
          'Failed to deliver plugin node verdict for $pluginId/$nodeTypeId '
          '(node_id=$nodeId): $e\n$st',
          source: 'SequenceExecutor',
        );
      } finally {
        coordinator.release(nodeId);
      }
    }());
  }

  /// Thumbnail — translate a typed FrameAccepted / FrameRejected
  /// event into a captured_images row tagged with the producing node id.
  /// Fire-and-forget; failures are logged so the strip can show them, but they
  /// never block the run.
  void _registerSequenceFrame(FrameGraded event, {required String grade}) {
    final isAccepted = event.accepted;
    final nodeId = event.nodeId;
    if (nodeId == null || nodeId.isEmpty) {
      // No producing node — typically a wizard-driven capture (flat
      // wizard, polar-align). Nothing for the sequence-tree strip to
      // hang the row off of, so we skip.
      return;
    }
    final hfr = event.hfr;
    final eccentricity = event.eccentricity;
    final starCount = event.starCount;
    // The frame event carries no background/noise, so the score is the
    // HFR + star-count components renormalised; NaN when the frame reported
    // neither, which stores as NULL and lets the assessment service's own
    // fallback apply to a frame that genuinely was not measured.
    final rawQualityScore = computeFrameQualityScore(
      hfr: hfr,
      starCount: starCount,
    );
    final qualityScore = rawQualityScore.isNaN ? null : rawQualityScore;
    // The capture truth the FITS writer used for THIS frame, carried on the
    // event. Reading it here — rather than re-deriving gain/offset/binning
    // from the sequence tree, and leaving temperature, pointing, focuser and
    // rotator simply absent — is what makes the row and the file agree. Adding
    // more fields to `resolveFrameAttribution` instead would have kept two
    // sources of truth for one exposure, which is the defect itself.
    final capture = event.capture;
    // Accepted frames now carry the on-disk save_path
    // alongside the existing rejected-frame reject_path. The thumbnail
    // strip uses whichever field is populated to load the inline
    // preview. `save_path` may legitimately be null on legacy emit
    // sites that did not thread the path through; defaulting to empty
    // string keeps the "no thumbnail yet" colour-bordered tile rather
    // than skipping the row entirely.
    final filePath = event.filePath ?? '';
    final fileName = filePath.isEmpty ? '' : p.basename(filePath);
    final rejectionReason = switch (event) {
      FrameRejected(:final reason) => reason,
      FrameAccepted() => null,
    };
    // One resolver, shared with the run-stats bucket — see
    // [_resolveActiveFilter] for why the two must not diverge. A frame
    // recorded with no filter is unusable for calibration matching later.
    final filter = _resolveActiveFilter();
    final runId = _ref.read(currentRunIdProvider);
    final runIdString = runId?.toString();
    // `dbSessionId` is 0/absent when no session row is open (a bare
    // start-without-session), in which case the column stays NULL rather than
    // pointing at a session that does not exist.
    final dbSessionId = _ref.read(sessionStateProvider).dbSessionId;
    final sessionId = (dbSessionId != null && dbSessionId > 0)
        ? dbSessionId
        : null;
    final dao = _ref.read(imagesDaoProvider);
    final sidecarService = _ref.read(thumbnailSidecarServiceProvider);

    // Attribute this frame to its catalog target row and real exposure length
    // by walking the loaded sequence tree from the producing node. Replaces
    // the former hardcoded target_id=NULL + exposureDuration=1.0, which broke
    // per-target integration-goal completion (the scheduler imaged one target
    // all night) and corrupted every integration-time total. Computed
    // synchronously here so it reflects the sequence as it was when the frame
    // was produced, not whatever is loaded by the time the async insert runs.
    //
    // Scope of the `capture.X ?? attribution.X` fallbacks below: they exist for
    // ONE case, a paired client talking to an appliance older than the frame
    // capture payload (a phone that auto-updated against a Pi that did not).
    // That host's frame event carries none of the capture keys, so the tree
    // walk is all there is.
    //
    // On the FFI path they are dead by construction and must stay that way.
    // Native fills `FrameContext.gain` from `image_data.gain.or(config.gain)`,
    // and `config.gain` IS the producing node's configured gain — the exact
    // value `resolveFrameAttribution` reads out of the tree. So a null capture
    // gain implies a null node gain, and the fallback has nothing to add. It is
    // also the WEAKER source: for a SmartExposure burst the tree walk picks a
    // plan by matching the filter name, which can select the wrong plan, while
    // the native value came off the exposure that actually ran.
    //
    // `targetId` is not one of these fallbacks. It is resolved Dart-side only
    // (see below), because it is a `targets.id` primary key; the event's own
    // `target_id` is the sequencer's TargetHeader NODE id, a different
    // identifier entirely.
    final loadedSequence = _ref.read(currentSequenceProvider);
    final attribution = loadedSequence == null
        ? const FrameAttribution()
        : resolveFrameAttribution(
            loadedSequence,
            nodeId,
            currentFilter: filter,
          );
    // `targets.id` this frame belongs to. `attribution` reads the node's own
    // `catalogTargetId`, which only sequences generated from a library target
    // carry; for a Target the operator typed into the builder the id comes
    // from the row bound at run start (see [_bindCatalogTargets]). Before that
    // binding existed every builder-authored night was persisted with
    // `target_id` NULL and reported as "Untargeted".
    final targetId =
        attribution.targetId ??
        (loadedSequence == null
            ? null
            : _runTargetIdFor(loadedSequence, nodeId));
    // The exposure the shutter actually ran for, as the camera reported it —
    // already bounded against the commanded duration native-side, so a driver
    // that misreports cannot inflate this column's integration totals.
    final exposureSecs = capture.exposureSecs ?? attribution.exposureSecs;
    if (exposureSecs == null) {
      _logger.warning(
        'Sequence frame from node $nodeId has no resolvable exposure duration '
        '(producing node is not an ExposureNode); recording 0s rather than a '
        'fabricated value.',
        source: 'SequenceExecutor',
      );
    }

    // Advance the imaging-session counters for this frame.
    //
    // Without this, a sequenced night wrote captured_images rows stamped with
    // `session_id` while the owning `imaging_sessions` row kept
    // totalExposures/successfulExposures/totalIntegrationSecs at 0 — the
    // session claiming nothing was captured while its own frames pointed back
    // at it. `recordExposureComplete` was only ever called from the ad-hoc
    // capture surfaces (imaging screen, dashboard quick actions), never from
    // the sequencer, so every unattended run reported an empty session.
    //
    // Recorded synchronously (not inside the persistence closure below)
    // because the frame really was captured — it is on disk — whether or not
    // our own DB insert then succeeds. `recordExposureComplete` fans out to
    // SessionService, which checkpoints the aggregate onto the session row;
    // it self-guards when no session is open, so a bare
    // start-without-session stays a no-op.
    //
    // A rejected frame still counts as a completed capture (the shutter did
    // open) but is kept out of the integration budget and the HFR average —
    // that accept/reject split is `recordExposureComplete`'s own contract.
    _ref
        .read(sessionStateProvider.notifier)
        .recordExposureComplete(
          exposureTime: exposureSecs ?? 0.0,
          hfr: hfr,
          accepted: isAccepted,
        );

    // Capture the logger NOW (it is a provider read): the persistence
    // future below outlives the event handler, and reading providers
    // through _ref after the container is disposed throws out of an
    // unhandled async error. Post-await provider reads inside the closure
    // are additionally guarded on _disposed (a captured logger stays
    // usable, but a DAO read is not).
    final logger = _logger;
    final registration = () async {
      try {
        final rowId = await dao.insertSequenceFrame(
          filePath: filePath,
          fileName: fileName,
          fileFormat: filePath.toLowerCase().endsWith('.xisf')
              ? 'xisf'
              : 'fits',
          // Real exposure length (see `exposureSecs` above; column is NOT
          // NULL).
          exposureDuration: exposureSecs ?? 0.0,
          targetId: targetId,
          capturedAt: DateTime.now(),
          isAccepted: isAccepted,
          producingNodeId: nodeId,
          producingRunId: runIdString,
          runtimeGrade: grade,
          rejectionReason: rejectionReason,
          filter: filter,
          // Frame type as captured (FITS `IMAGETYP`), lowercased to the images
          // DB's spelling. Falls back to the tree walk for a host that does
          // not send the capture payload.
          frameType: capture.frameType?.toLowerCase() ?? attribution.frameType,
          // Capture settings as the camera actually reported them for this
          // exposure — the same values stamped into the FITS header. The node
          // config only says what the sequence ASKED for, so a camera that
          // clamps or ignores a requested gain leaves the row and the file
          // disagreeing about the same frame.
          gain: capture.gain ?? attribution.gain,
          offset: capture.offset ?? attribution.offset,
          binX: capture.binX ?? attribution.binX,
          binY: capture.binY ?? attribution.binY,
          // Live equipment state at the moment of capture. These columns have
          // existed since v18 and no sequencer frame has ever populated one:
          // the row carried no temperature, no pointing, no focuser or rotator
          // position, while the FITS file written microseconds earlier from the
          // same exposure carried all of them.
          sensorTemp: capture.sensorTempC,
          coolerPower: capture.coolerPowerPercent,
          mountRa: capture.mountRaHours,
          mountDec: capture.mountDecDegrees,
          mountAltitude: capture.mountAltitudeDeg,
          mountAzimuth: capture.mountAzimuthDeg,
          pierSide: capture.pierSide,
          focuserPosition: capture.focuserPosition,
          focuserTemp: capture.focuserTemperatureC,
          rotatorAngle: capture.rotatorAngleDeg,
          // Tie the frame to the active imaging session, the same way the
          // ad-hoc capture path does (`persistence.dart` reads
          // `sessionState.dbSessionId`). Without it every session-scoped
          // query — session summary, post-session report — saw zero frames
          // for a sequenced night.
          sessionId: sessionId,
          hfr: hfr,
          starCount: starCount,
          eccentricity: eccentricity,
          // Stamp the composite score the gallery and every quality-ranked
          // consumer read. Without it the column stayed NULL for every
          // sequencer frame and `FrameQualityAssessmentService` assessed the
          // `?? 75.0` fallback instead of the frame — see
          // [computeFrameQualityScore] for what that cost.
          qualityScore: qualityScore,
          logger: logger,
          sidecarService: sidecarService,
        );
        // Surface the frame on the live session surfaces. On the host,
        // `recentSessionFramesProvider` is exactly the in-memory
        // `sessionImagesProvider` list, which only the ad-hoc capture loop was
        // appending to — so the Dashboard's Recent Frames tile read "No frames
        // captured this session yet" for an entire sequenced night while frames
        // were landing on disk and in the DB. Re-reading the row we just wrote
        // (rather than rebuilding a CapturedImage by hand) keeps the strip
        // showing exactly what was persisted.
        //
        // Accepted frames only: a rejected frame rendered in a plain "recent
        // frames" strip has no affordance marking it as rejected, so it would
        // read as a good frame. The sequencer's own thumbnail strip is the
        // surface that shows rejects, with a colour-coded border.
        if (isAccepted && !_disposed) {
          try {
            final row = await dao.getImageById(rowId);
            if (row != null && !_disposed) {
              _ref
                  .read(sessionImagesProvider.notifier)
                  .addImage(capturedImageFromDbRow(row));
            }
          } catch (e) {
            logger.warning(
              'Registered sequence frame $rowId but could not add it to the '
              'live session list: $e',
              source: 'SequenceExecutor',
            );
          }
        }
        // Phase B (v43) — ADDITIVE durable-campaign bookkeeping. When an
        // accepted light frame attributes to a catalog target and a filter,
        // credit one accepted frame to the durable NINA-style `campaigns`
        // counter and stamp its last-capture date. This is a denormalized
        // companion to the live `integration_goals` derivation the scheduler
        // reads — it never feeds the engine's goals-complete reject and never
        // touches frame attribution; rejected frames (`isAccepted == false`)
        // are skipped so the counter only advances on acceptance.
        if (isAccepted &&
            targetId != null &&
            filter != null &&
            filter.isNotEmpty) {
          if (_disposed) return;
          try {
            await _ref
                .read(campaignsDaoProvider)
                .recordAccepted(
                  targetId: targetId,
                  filter: filter,
                  capturedAt: DateTime.now(),
                );
          } catch (e) {
            logger.warning(
              'Phase B: failed to credit campaign for target '
              '$targetId filter $filter: $e',
              source: 'SequenceExecutor',
            );
          }
        }
      } catch (e) {
        logger.warning(
          'Thumbnail: failed to register sequence frame for '
          'node $nodeId ($grade): $e',
          source: 'SequenceExecutor',
        );
      }
    }();
    _inFlightFrameRegistrations.add(registration);
    unawaited(
      registration.whenComplete(
        () => _inFlightFrameRegistrations.remove(registration),
      ),
    );
  }

  /// Whether the node identified by [nodeId] ran an autofocus sweep, judged by
  /// its most recent structured progress payload.
  ///
  /// `ProgressDetail::Autofocus` reaches Dart as an
  /// [UnknownInstructionProgressDetail] with `kind == 'Autofocus'` (only
  /// `Exposure` has a typed Dart counterpart today), and it is emitted by the
  /// autofocus instruction alone — both for a tree `Autofocus` node and for a
  /// trigger-fired refocus, which the executor publishes under the synthetic
  /// node id `trigger:<id>:autofocus`.
  bool _nodeRanAutofocus(String nodeId) {
    final detail = _ref
        .read(sequenceProgressProvider)
        .nodeProgressStructuredDetail[nodeId];
    return detail is UnknownInstructionProgressDetail &&
        detail.kind == 'Autofocus';
  }

  /// The filter this run is exposing through, resolved once from the two
  /// sources that can know it.
  ///
  /// The progress provider learns the filter from the Change Filter
  /// instruction event; the wheel state learns it from the `FilterChanged`
  /// equipment event. Either alone leaves a hole — an operator who parks the
  /// wheel outside the sequence, or a frame that lands before the instruction
  /// event is processed.
  ///
  /// ONE filter resolution, shared with [_registerSequenceFrame]: registration
  /// and the run-stats bucket both persist the filter for the same frame, so a
  /// second resolution chain gives one frame two recorded answers.
  String? _resolveActiveFilter() =>
      _ref.read(sequenceProgressProvider).currentFilter ??
      _ref.read(filterWheelStateProvider).currentFilterName;

  /// The target the run is currently imaging, for the run-stats bucket.
  ///
  /// The progress provider only learns a target name from a native
  /// `TargetStarted` / `TargetChanged` event. A plain builder sequence never
  /// produces one, so this fell straight through to the SEQUENCE name and
  /// `stats_json.targetBreakdown` filed four frames of "New Target" under the
  /// key "New Sequence". The sequence tree knows the answer without any event:
  /// walk up from the node that is executing to its enclosing target header.
  String _resolveActiveTargetName() {
    final progress = _ref.read(sequenceProgressProvider);
    final fromEvent = progress.currentTarget;
    if (fromEvent != null && fromEvent.isNotEmpty) return fromEvent;

    final sequence = _ref.read(currentSequenceProvider);
    final nodeId = progress.currentNodeId;
    if (sequence != null && nodeId != null) {
      final header = enclosingTargetHeader(sequence, nodeId);
      final name = header?.targetName;
      if (name != null && name.isNotEmpty) return name;
    }
    // No target header at all (a bare calibration or quick-capture sequence):
    // the sequence's own name is the most specific true label left.
    return sequence?.name ?? 'Sequence';
  }

  /// Count a frame the grader ruled on into the run's vitals, and hold its
  /// verdict and capture truth until the `ExposureCompleted` for the same frame
  /// arrives. See [_gradedFrames] for why this — not `ExposureCompleted` — is
  /// where the counters move.
  ///
  /// The exposure length credited is the one the camera REPORTED for this frame,
  /// off the event's own capture payload: the same number the FITS header and
  /// the `captured_images` row were written from. `ExposureCompleted`'s
  /// `duration_secs` is the executor's restatement of it and does not reach
  /// every producer.
  ///
  /// The frame goes on screen here too. A Smart Exposure frame never gets an
  /// `ExposureCompleted`, and that was the only thing that fetched the preview,
  /// so the Imaging tab and Tonight kept showing an old frame for a whole run
  /// (rig, 2026-10-20).
  void _recordGradedFrame(FrameGraded event) {
    final capture = event.capture;
    _recordRunFrame(
      exposureSecs: capture.exposureSecs ?? 0.0,
      filter: event.filter,
      accepted: event.accepted,
    );
    // The saved file travels with the preview, so what is worked out from
    // the file (the background plate solve, the star overlay) can find it.
    final path = event.filePath;
    _fetchAndDisplaySequenceImage(
      _previewSettingsForFrame(capture, capture.exposureSecs ?? 0.0),
      filePath: path == null || path.isEmpty ? null : path,
    );
    final frame = event.frame;
    if (frame == null) return;
    _gradedFrames[frame] = (accepted: event.accepted, capture: capture);
  }

  /// The capture settings to stamp on the preview published for the frame that
  /// just completed.
  ///
  /// [capture] is the truth the camera reported for THIS exposure — the same
  /// values the FITS header and the `captured_images` row were written from —
  /// and the producing node's configuration is the fallback for a host that
  /// sends no capture payload. The preview is stamped with the values the FITS
  /// header and the DB row were written from — never with literals, which is
  /// how the Imaging tab comes to label a 300 s sub "2 s, gain 0, bin 1".
  ExposureSettings _previewSettingsForFrame(
    FrameCapture? capture,
    double durationSecs,
  ) {
    final filter = _resolveActiveFilter();
    final sequence = _ref.read(currentSequenceProvider);
    final nodeId = _ref.read(sequenceProgressProvider).currentNodeId;
    final attribution = (sequence == null || nodeId == null)
        ? const FrameAttribution()
        : resolveFrameAttribution(sequence, nodeId, currentFilter: filter);
    return ExposureSettings(
      exposureTime:
          capture?.exposureSecs ?? attribution.exposureSecs ?? durationSecs,
      gain: capture?.gain ?? attribution.gain ?? 0,
      offset: capture?.offset ?? attribution.offset ?? 0,
      binningX: capture?.binX ?? attribution.binX,
      binningY: capture?.binY ?? attribution.binY,
      filter: filter,
      frameType: switch (capture?.frameType?.toLowerCase() ??
          attribution.frameType) {
        'dark' => FrameType.dark,
        'flat' => FrameType.flat,
        'bias' => FrameType.bias,
        'darkflat' => FrameType.darkFlat,
        'snapshot' => FrameType.snapshot,
        _ => FrameType.light,
      },
    );
  }

  void _recordRunFrame({
    required double exposureSecs,
    required bool accepted,
    String? filter,
  }) {
    _stats.update((stats) {
      final resolvedFilter = (filter != null && filter.isNotEmpty)
          ? filter
          : _resolveActiveFilter();
      stats.recordFrame(
        target: _resolveActiveTargetName(),
        filter: (resolvedFilter != null && resolvedFilter.isNotEmpty)
            ? resolvedFilter
            : 'Unknown',
        exposureSecs: exposureSecs,
        accepted: accepted,
      );
    });
  }

  void _recordRunError(String message) {
    _stats.update((stats) => stats.recordError(message));
    _noteAutofocusOutcomeForBacklashOffer(failureMessage: message);
  }

  /// Feed an autofocus verdict to the backlash-calibration offer.
  ///
  /// This is the only place Dart sees a sequencer instruction's failure text,
  /// and the landing-verification failure — autofocus moved to the fitted
  /// position and the frame taken there disagreed — is the one that points at
  /// an uncalibrated gear train. The offer itself matches the message; every
  /// other error passes through it unchanged.
  void _noteAutofocusOutcomeForBacklashOffer({String? failureMessage}) {
    final focuserId = _ref.read(focuserStateProvider).deviceId;
    if (focuserId == null || focuserId.isEmpty) return;
    _ref
        .read(focuserBacklashOfferSessionProvider.notifier)
        .noteAutofocusOutcome(
          focuserId: focuserId,
          failureMessage: failureMessage,
        );
  }

  /// Record the reason carried by a terminal event. See
  /// [SequenceRunStats.recordTerminalError] for why this is not
  /// [_recordRunError]: the terminal reason is a restatement of the mid-run
  /// `Error` this same run already recorded.
  void _recordTerminalRunError(String message) {
    _stats.update((stats) => stats.recordTerminalError(message));
  }

  /// Record the verdict of a meridian flip into the live run stats.
  ///
  /// The flip is the most dangerous unattended operation the app performs, so
  /// the run record has to carry its verdict: unrecorded, a trigger-driven flip
  /// that slewed the mount across the pier finishes the night with
  /// `meridianFlips: 0`, and a flip whose post-flip recenter FAILED finishes
  /// with `errorMessages: []` on a run reported as `completed`.
  ///
  /// The three outcomes map to three different truths:
  ///  * clean success (one attempt, no failed steps) -> count it, nothing more;
  ///  * degraded success (the retry ladder ran but the flip eventually worked)
  ///    -> count it AND warn, because a recenter that needed retries means the
  ///    framing should be eyeballed before trusting the sub-frames;
  ///  * failed / aborted -> do NOT count it (no flip happened) and record an
  ///    error/warning so the session report cannot claim a clean night.
  void _handleMeridianFlipOutcome(MeridianFlipOutcome event) {
    final progressNotifier = _ref.read(sequenceProgressProvider.notifier);
    final outcome = event.outcome ?? 'unknown';
    final targetName = event.targetName ?? 'target';
    final attempts = event.attempts ?? 0;
    final durationSecs = event.durationSecs ?? 0;
    final error = event.error;
    final actionTaken = event.actionTaken;
    final failedSteps = event.failedSteps;

    switch (outcome) {
      case 'success':
        _stats.update((stats) => stats.recordMeridianFlip());
        if (failedSteps.isEmpty) {
          final message =
              'Meridian flip for "$targetName" completed in '
              '${durationSecs.toStringAsFixed(1)}s';
          _logger.info(message, source: 'SequenceExecutor');
          progressNotifier.updateProgress(message: message);
        } else {
          final message =
              'Meridian flip for "$targetName" succeeded only on attempt '
              '$attempts after ${failedSteps.length} failed '
              'attempt${failedSteps.length == 1 ? '' : 's'}: '
              '${failedSteps.join("; ")}. Verify framing — the post-flip '
              'recentre needed retries.';
          _logger.warning(message, source: 'SequenceExecutor');
          _stats.update((stats) => stats.recordWarning(message));
          progressNotifier.updateProgress(message: message);
        }
        break;

      case 'aborted':
        final message =
            'Meridian flip for "$targetName" was aborted after $attempts '
            'attempt${attempts == 1 ? "" : "s"}'
            '${error != null ? ": $error" : ""}. The mount was NOT '
            'flipped.';
        _logger.warning(message, source: 'SequenceExecutor');
        _stats.update((stats) => stats.recordWarning(message));
        progressNotifier.updateProgress(message: message);
        break;

      default:
        final message =
            'Meridian flip for "$targetName" FAILED after $attempts '
            'attempt${attempts == 1 ? "" : "s"}: ${error ?? "unknown error"}'
            '${actionTaken != null ? " (action: $actionTaken)" : ""}. '
            'Frames captured after this point may be mis-framed.';
        _logger.error(message, source: 'SequenceExecutor');
        _recordRunError(message);
        progressNotifier.updateProgress(message: message);
        // Same escalation the generic Error handler performs: a failed flip
        // may have left the rig mis-framed or slewing, so the run must not go
        // on claiming a healthy `running` state — the dashboard shows
        // needs-attention until the authoritative terminal event lands.
        if (_ref.read(sequenceExecutionStateProvider) ==
            SequenceExecutionState.running) {
          progressNotifier.updateState(SequenceExecutionState.recovering);
          _ref.read(sequenceExecutionStateProvider.notifier).state =
              SequenceExecutionState.recovering;
        }
        break;
    }
  }

  /// Finalize the run row and fire the once-per-run session-end hooks.
  ///
  /// Awaited by the drive, so the run id is cleared only after `finishRun` has
  /// persisted and a failed finish surfaces as `cleanupFailed`.
  /// [RunFinalization.runRecordFinished] is set only after `finishRun`
  /// succeeds: it makes the success path exactly-once without swallowing a
  /// retry after a failed finish.
  Future<void> _finalizeRun(RunFinalization f) async {
    if (f.runRecordFinished) {
      return;
    }
    final runId = _ref.read(currentRunIdProvider);
    final stats = _ref.read(liveSequenceStatsProvider);
    if (runId == null || stats == null) {
      return;
    }
    await _stats.sealAndDrain();
    stats.endTime = DateTime.now();
    await _ref
        .read(sequenceRunsDaoProvider)
        .finishRun(runId, f.runStatus, stats.toJson());
    f.runRecordFinished = true;
    _captureSessionEndHooks();
  }

  // Live-stacking auto-feed.
  //
  // The Rust `LiveStacking` instruction node is arm-only: it registers a
  // broadcast session on the Rust side and returns immediately, delegating
  // frame ingestion to Dart (see the single-frame OSC note in
  // `native/.../node/instructions/live_stacking.rs`). Dart is therefore the
  // only thing that can feed the stacker: each accepted sequence frame is
  // registered with the in-process stacker (first frame == reference,
  // automatically) and the rendered stack is published to
  // `LiveStackingBroadcastService` for the HTTP endpoints.

  /// Locate the enabled [LiveStackingNode] in the running sequence, if any.
  /// Returns the first enabled live-stacking node found; `null` means the
  /// running sequence does not use live stacking, so the accepted-frame
  /// feed is a no-op (NOT an error).
  LiveStackingNode? _findActiveLiveStackingNode() {
    final sequence = _ref.read(currentSequenceProvider);
    if (sequence == null) return null;
    for (final node in sequence.nodes.values) {
      if (node is LiveStackingNode && node.isEnabled) {
        return node;
      }
    }
    return null;
  }

  /// Map a [LiveStackingNode]'s combine method onto the engine config.
  /// The native stacker exposes sigma-clip as its only rejection knob, so
  /// `average` runs with rejection off and `medianRej`/`sigma` run with it
  /// on — matching the documented mapping in `BroadcastSessionState`.
  LiveStackingConfig _liveStackingConfigFor(LiveStackingNode node) {
    final sigmaClip = node.stackMethod != LiveStackingMethod.average;
    return LiveStackingConfig(sigmaClipEnabled: sigmaClip);
  }

  /// Auto-feed entry point invoked for every `FrameAccepted` event while a
  /// sequence runs. Serialises feeds onto [_liveStackingFeedChain] so a
  /// fast cadence cannot interleave the reference-frame start with a later
  /// add (which would corrupt the stack's coordinate system).
  void _maybeFeedLiveStacking(FrameAccepted event) {
    final node = _findActiveLiveStackingNode();
    if (node == null) return; // Sequence has no live stacking — nothing to do.

    final savePath = event.savePath;
    if (savePath == null || savePath.isEmpty) {
      // An accepted frame with no on-disk path cannot be fed. This is a
      // real wiring problem (the Rust grader is expected to ship
      // `save_path` for accepted frames), so we fail LOUD rather than
      // silently dropping the frame from the live stack.
      _logger.error(
        'Live-stacking auto-feed: accepted frame from node '
        '${event.nodeId} carried no save_path; cannot add it to the '
        'live stack. The broadcast stack will be missing this frame.',
        source: 'SequenceExecutor',
      );
      return;
    }

    final exposureSecs = _resolveLiveStackExposureSecs(event);
    final previous = _liveStackingFeedChain ?? Future<void>.value();
    _liveStackingFeedChain = previous.then(
      (_) => _feedLiveStackingFrame(
        node: node,
        savePath: savePath,
        exposureSecs: exposureSecs,
      ),
    );
  }

  /// Resolve the real exposure length for the accepted frame so the
  /// broadcast's integration counter is accurate. Prefers the producing
  /// node's attribution (the same source the captured-images row uses);
  /// falls back to the event's `duration_secs` payload.
  double _resolveLiveStackExposureSecs(FrameAccepted event) {
    final nodeId = event.nodeId;
    final loadedSequence = _ref.read(currentSequenceProvider);
    if (nodeId != null && loadedSequence != null) {
      final attribution = resolveFrameAttribution(
        loadedSequence,
        nodeId,
        currentFilter: _ref.read(sequenceProgressProvider).currentFilter,
      );
      if (attribution.exposureSecs != null) {
        return attribution.exposureSecs!;
      }
    }
    return event.durationSecs ?? 0.0;
  }

  /// Add one accepted frame to the live stack and publish the rendered
  /// result to the broadcast. Arms the stacker + broadcast lazily on the
  /// first frame of the run (the frame becomes the reference). Honours the
  /// node's [LiveStackingNode.maxFramesToStack] cap. Failures are logged
  /// LOUD — a frame that cannot be fed is never silently dropped.
  Future<void> _feedLiveStackingFrame({
    required LiveStackingNode node,
    required String savePath,
    required double exposureSecs,
  }) async {
    final broadcast = _ref.read(liveStackingBroadcastServiceProvider);
    final notifier = _ref.read(liveStackingProvider.notifier);

    try {
      if (!_liveStackingArmedForRun) {
        // First accepted frame of the run → arm the broadcast (Dart side)
        // and start the stacker from this file. The file becomes the
        // reference automatically; no hand-picked reference is required.
        broadcast.activate(node);
        broadcast.updateCurrentTarget(
          _ref.read(sequenceProgressProvider).currentTarget,
        );
        await notifier.startFromFile(
          savePath,
          config: _liveStackingConfigFor(node),
        );
        final started =
            _ref.read(liveStackingProvider).status ==
            LiveStackingStatus.running;
        if (!started) {
          final err = _ref.read(liveStackingProvider).errorMessage;
          _logger.error(
            'Live-stacking auto-feed: failed to start the stacker from the '
            'first accepted frame ($savePath): ${err ?? 'unknown error'}. '
            'Live stack/broadcast will not run for this sequence.',
            source: 'SequenceExecutor',
          );
          broadcast.deactivate();
          return;
        }
        _liveStackingArmedForRun = true;
        _logger.info(
          'Live-stacking auto-feed armed: reference frame $savePath '
          '(method=${node.stackMethod.label}, broadcast port '
          '${node.broadcastPort})',
          source: 'SequenceExecutor',
        );
      } else {
        // Honour the frame cap. `0` means unlimited.
        final cap = node.maxFramesToStack;
        if (cap > 0 &&
            _ref.read(liveStackingProvider).stats.stackedFrameCount >= cap) {
          _logger.debug(
            'Live-stacking auto-feed: frame cap ($cap) reached; not adding '
            '$savePath to the stack.',
            source: 'SequenceExecutor',
          );
          return;
        }
        broadcast.updateCurrentTarget(
          _ref.read(sequenceProgressProvider).currentTarget,
        );
        await notifier.addFrameFromFile(savePath);
      }

      // Publish the freshly-updated stack to the broadcast. Read the
      // engine's current preview from the notifier state (populated by
      // both startFromFile and addFrameFromFile).
      final stackState = _ref.read(liveStackingProvider);
      final preview = stackState.previewData;
      if (preview == null ||
          stackState.previewWidth <= 0 ||
          stackState.previewHeight <= 0) {
        _logger.warning(
          'Live-stacking auto-feed: stack has no preview after feeding '
          '$savePath; broadcast image not updated this frame.',
          source: 'SequenceExecutor',
        );
        return;
      }
      broadcast.publishFrame(
        width: stackState.previewWidth,
        height: stackState.previewHeight,
        previewData: preview,
        exposureSecs: exposureSecs,
      );
    } catch (e, st) {
      // Loud-fail policy: a frame that cannot be fed is surfaced,
      // not swallowed. The run itself keeps going (imaging must not stop
      // because the outreach broadcast hiccuped), but the operator sees
      // exactly which frame was lost and why.
      _logger.error(
        'Live-stacking auto-feed: failed to add accepted frame $savePath to '
        'the live stack: $e\n$st',
        source: 'SequenceExecutor',
      );
    }
  }

  /// Tear down the live-stacking auto-feed at the end of a run: stop the
  /// LAN broadcast and the stacking engine so the next run starts from a
  /// clean reference and a stopped public run cannot keep serving a stale
  /// stack. Idempotent — safe to call from both `stop()` and the terminal
  /// event handlers.
  Future<void> _teardownLiveStacking() async {
    if (!_liveStackingArmedForRun) {
      // Still deactivate the broadcast defensively in case it was armed
      // without a successful stacker start (e.g. activate() then start
      // failed); `deactivate()` is a no-op when nothing is active.
      _ref.read(liveStackingBroadcastServiceProvider).deactivate();
      return;
    }
    _liveStackingArmedForRun = false;
    // Drain any in-flight feed so we don't stop the engine out from under
    // a pending add.
    final chain = _liveStackingFeedChain;
    _liveStackingFeedChain = null;
    if (chain != null) {
      try {
        await chain;
      } catch (_) {
        // Feed errors are already logged in `_feedLiveStackingFrame`.
      }
    }
    _ref.read(liveStackingBroadcastServiceProvider).deactivate();
    try {
      await _ref.read(liveStackingProvider.notifier).stop();
    } catch (e) {
      _logger.warning(
        'Live-stacking auto-feed: failed to stop the stacker on teardown: $e',
        source: 'SequenceExecutor',
      );
    }
  }
}
