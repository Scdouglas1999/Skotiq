part of '../sequence_executor.dart';

extension _SequenceExecutorEventOperations on SequenceExecutor {
  void _handleSequencerEvent(SkotiqEvent event) {
    // Unconditional, this line runs once per backend event: at ~5 events/s it
    // fills LoggingService's whole 1000-entry ring in about three minutes and
    // Settings ▸ Advanced ▸ Logs shows nothing else. Rate-limited PER EVENT
    // TYPE so a chatty type (InstructionProgress) collapses while a rare one
    // (Stopped, Error) is still traced the moment it arrives, and the
    // suppressed count rides along on the next admitted line.
    final trace = _eventTraceLimiter.admit(
      '${event.category.name}/${event.eventType}',
      'Received event: type=${event.eventType}, category=${event.category}',
    );
    if (trace != null) {
      _logger.debug(trace, source: 'SequenceExecutor');
    }

    // A dither the run performed. The executor reports each one once,
    // whoever asked for it: a Dither node, a Smart Exposure plan, a burst's
    // dither-every, or the Dither Interval trigger. It is the ONE site that
    // may call `SequenceRunStats.recordDither()`. The guider's own
    // `DitherCompleted` is not counted: only the built-in guider sends it,
    // so a PHD2 run counted no dithers at all (rig, 2026-10-20), and counted
    // as well it would double every dither on the built-in guider. It is a
    // count, not node progress, so nothing below sees it.
    if (isRunDitherEvent(event)) {
      _incrementRunStat((stats) => stats.recordDither());
      return;
    }

    // Only process sequencer events for progress tracking
    if (event.category != EventCategory.sequencer) return;

    final progressNotifier = _ref.read(sequenceProgressProvider.notifier);

    // The frames a node captured live in their own slot, which no other
    // instruction reporting against the same node can overwrite — see
    // [applySequencerEventToNodeExposureTally]. The display strings below are
    // still written, but the card counts with the tally, not with them.
    applySequencerEventToNodeExposureTally(
      _ref.read(nodeExposureTallyProvider.notifier),
      event,
    );

    // WHO is ending this run, kept as it arrives. The cancel notice this
    // handler reclassifies below names no author, and the rows that do — the
    // operator's manual-intervention decision, the autopilot's, a subsystem's,
    // the trigger monitor's ParkAndAbort — all precede it.
    recordSequenceStopEvidence(_ref.read, event);

    switch (event.eventType) {
      case 'NodeStarted':
        final nodeId =
            event.data['node_id'] as String? ?? event.data['nodeId'] as String?;
        final nodeName =
            event.data['node_type'] as String? ??
            event.data['nodeName'] as String?;
        if (nodeId != null) {
          progressNotifier.updateProgress(
            currentNodeId: nodeId,
            currentNodeName: nodeName,
            currentNodeStatus: NodeStatus.running,
          );
          progressNotifier.updateNodeStatus(nodeId, NodeStatus.running);
        }
        // Frame indices restart at 1 for every node, so a verdict the previous
        // node never had an `ExposureCompleted` for (an aborted burst) must not
        // survive into this one's frame 1.
        _gradedFrames.clear();
        break;

      case 'NodeCompleted':
        final nodeId =
            event.data['node_id'] as String? ?? event.data['nodeId'] as String?;
        final statusStr = event.data['status'] as String? ?? 'failed';
        final nodeStatus = switch (statusStr) {
          'success' => NodeStatus.success,
          'skipped' => NodeStatus.skipped,
          'cancelled' => NodeStatus.skipped,
          _ => NodeStatus.failure,
        };
        if (nodeId != null) {
          progressNotifier.updateNodeStatus(nodeId, nodeStatus);
          // Count the autofocus that actually ran.
          //
          // `SequenceRunStats.recordAutofocus()` had ZERO production call
          // sites: the counter was declared, serialised into
          // `sequence_runs.stats_json`, mirrored onto
          // `imaging_sessions.autofocus_count` and rendered by the Session
          // Report's Mount & focus block — and nothing anywhere incremented
          // it. Verified on a live run: the Autofocus node swept 9 points,
          // logged "completed with status: Success" and moved the focuser
          // 25000 -> 25070, and the run still persisted `"autofocusRuns":0`.
          //
          // Read BEFORE the status write above would have been equivalent —
          // `updateNodeStatus` does not touch the structured-detail map — but
          // the evidence itself is what matters: the node's own last
          // structured progress payload. `ProgressDetail::Autofocus` is
          // emitted by the autofocus instruction and by nothing else, so it
          // identifies the sweep by what the node DID, keyed on node id. The
          // node's display name is not usable here: it is operator-editable
          // and the same string reaches us for a renamed Wait node.
          if (nodeStatus == NodeStatus.success && _nodeRanAutofocus(nodeId)) {
            _incrementRunStat((stats) => stats.recordAutofocus());
            _noteAutofocusOutcomeForBacklashOffer();
          }
          // An unrecognised status string maps to failure (above), but a
          // bare red node with no explanation trains users to ignore the
          // tree. Carry the raw status as a diagnostic and log it so a new
          // backend status that Dart hasn't learned yet is visible instead
          // of silently swallowed.
          if (statusStr != 'success' &&
              statusStr != 'skipped' &&
              statusStr != 'cancelled' &&
              statusStr != 'failed' &&
              statusStr != 'failure') {
            _logger.warning(
              'NodeCompleted with unknown status "$statusStr" for node '
              '$nodeId; treating as failure.',
              source: 'SequenceExecutor',
            );
            progressNotifier.updateNodeProgress(
              nodeId,
              0.0,
              'Unknown node status: "$statusStr"',
            );
          }
        }
        break;

      case 'ExposureStarted':
        final frame = event.data['frame'] as int? ?? 0;
        final total = event.data['total'] as int? ?? 0;
        final filter = event.data['filter'] as String?;
        // One vocabulary for the two wordings this node's progress line can
        // take — see [exposure_progress_vocabulary.dart].
        final exposureDetail = formatExposureStartedDetail(
          frame,
          total,
          filter,
        );
        progressNotifier.updateProgress(
          message: 'Exposing $exposureDetail',
          currentFilter: filter,
        );
        final exposureNodeId = _ref
            .read(sequenceProgressProvider)
            .currentNodeId;
        if (exposureNodeId != null && total > 0) {
          // frame-1 because exposure just started
          final exposurePercent = (frame - 1) / total * 100.0;
          progressNotifier.updateNodeProgress(
            exposureNodeId,
            exposurePercent,
            exposureDetail,
          );
        }
        break;

      case 'ExposureCompleted':
        final frame = event.data['frame'] as int? ?? 0;
        final total = event.data['total'] as int? ?? 1;
        final durationSecs =
            (event.data['duration_secs'] as num?)?.toDouble() ?? 0.0;
        // The grader emits before the completion, so an entry here means this
        // frame is already counted (see [_gradedFrames]) and only its capture
        // truth is still wanted, for the preview stamp below. A frame that
        // reaches here with no entry was never graded — a run with no save path
        // emits no grader event at all — and still completed, so it is counted
        // here as accepted rather than dropped.
        final graded = _gradedFrames.remove(frame);
        if (graded == null) {
          _recordRunFrame(
            exposureSecs: durationSecs,
            filter: event.data['filter'] as String?,
            accepted: true,
          );
        }
        // Feed the ETA smoother from the event's real exposure duration plus
        // a fixed per-frame download overhead. This is robust to AF/flip
        // gaps because it measures shutter-open time, not wall-clock between
        // ticks (which would fold AF/dither/slew stalls into the per-frame
        // estimate and yank the ETA around). Sub-second-capable double, so
        // short subs are no longer floored to integer-second deltas.
        if (durationSecs > 0) {
          final defaults = _ref.read(sequencerDefaultsProvider);
          _eta.recordFrame(durationSecs + defaults.frameDownloadOverheadSecs);
        }
        progressNotifier.updateProgress(completedExposures: frame);
        // Idempotent, keyed on the ORIGINATING EVENT: this handler and the
        // DeviceService-driven pump in `sequence_progress.dart` both see every
        // ExposureCompleted, so whichever subscriber gets there first wins and
        // the other is a no-op. An unkeyed read-modify-write counts each
        // frame's shutter time twice.
        progressNotifier.recordCompletedFrameIntegration(
          eventKey: '${event.timestamp}:$frame',
          durationSecs: durationSecs,
        );
        final completedNodeId = _ref
            .read(sequenceProgressProvider)
            .currentNodeId;
        if (completedNodeId != null) {
          final completedPercent = total > 0 ? (frame / total * 100.0) : 100.0;
          progressNotifier.updateNodeProgress(
            completedNodeId,
            completedPercent,
            formatExposureCompletedDetail(frame, total),
          );
        }

        // A graded frame was put on screen when its verdict arrived.
        if (graded == null) {
          _fetchAndDisplaySequenceImage(
            _previewSettingsForFrame(null, durationSecs),
          );
        }
        break;

      case 'Progress':
        final current = event.data['current'] as int? ?? 0;
        final total = event.data['total'] as int? ?? 0;
        progressNotifier.updateProgress(
          completedExposures: current,
          message: 'Progress: $current/$total exposures',
        );
        break;

      case 'TargetStarted':
      case 'TargetChanged':
        final name =
            event.data['target_name'] as String? ??
            event.data['name'] as String?;
        final ra = (event.data['ra'] as num?)?.toDouble();
        final dec = (event.data['dec'] as num?)?.toDouble();
        progressNotifier.updateProgress(
          currentTarget: name,
          message: name != null ? 'Started target: $name' : null,
        );
        if (name != null && ra != null && dec != null) {
          _logger.debug(
            'Target changed: $name (RA=${ra.toStringAsFixed(4)}h, Dec=${dec.toStringAsFixed(4)}°)',
            source: 'SequenceExecutor',
          );
          final sessionNotifier = _ref.read(sessionStateProvider.notifier);
          sessionNotifier.updateTargetCoordinates(ra: ra, dec: dec);
        }
        break;

      case 'TargetCompleted':
        final name =
            event.data['target_name'] as String? ??
            event.data['name'] as String?;
        progressNotifier.updateProgress(
          message: 'Completed target: ${name ?? 'unknown'}',
        );
        break;

      case 'Error':
        final message = event.data['message'] as String? ?? 'Unknown error';
        // An ADVISORY, not a fault. The executor has one payload for both and
        // separates them by severity (`ExecutorEvent::Warning` ->
        // `EventSeverity.warning` in `api/sequencer/event_bridge.rs`), so the
        // severity is what decides here. Treated as an error, the preflight
        // notice "the meridian-flip trigger is set to re-centre … but no plate
        // solver was found" painted the running node red, pushed a healthy run
        // into `recovering`, and put itself in the run's errorMessages — which
        // is how a darks run that finished Completed 3/3 showed a red Errors
        // section in its Session Report.
        if (event.severity == EventSeverity.warning) {
          _surfaceRunWarning(message);
          progressNotifier.updateProgress(message: message);
          break;
        }
        // Older native executors acknowledged an accepted SkipToNode command
        // through the generic Error event. It is an informational success: the
        // current instruction finishes, then preceding nodes are reported as
        // skipped. Do not poison run stats, paint the current node red, or move
        // Running -> Recovering for this compatibility event.
        if (message.startsWith('SkipToNode request accepted:')) {
          progressNotifier.updateProgress(message: message);
          break;
        }
        // PRODUCER 2 of the stop pipeline (the Sequencer target rollup, which
        // rendered a red "Error: Sequence cancelled", the red node badge, and
        // the run's persisted error list — the Session Report then had to
        // filter that entry back out).
        //
        // A cancelled run ends with `Error { message: "Sequence cancelled" }`
        // from the native executor. It is a lifecycle notice, not a fault: it
        // must not poison run stats, paint a node red, or push a stopping run
        // into `recovering` as if something were being salvaged.
        if (isSequenceCancelledNotice(message)) {
          // The cause comes from the run's authorship rows, not from the
          // notice — every cancellation path emits the same notice, so
          // reading it as the operator's Stop invents a human for a
          // trigger-driven park nobody was present for.
          final stopped = sequenceStoppedMessage(
            _ref.read(sequenceStopEvidenceProvider),
          );
          _logger.info(
            '[$kStopClassificationLogTag] sequence_executor: cancellation '
            'notice treated as a stop, not an error ($stopped)',
            source: 'SequenceExecutor',
          );
          progressNotifier.updateProgress(message: stopped);
          break;
        }
        _recordRunError(message);
        progressNotifier.updateProgress(message: 'Error: $message');
        final errorNodeId = _ref.read(sequenceProgressProvider).currentNodeId;
        if (errorNodeId != null) {
          progressNotifier.updateNodeProgress(
            errorNodeId,
            0.0,
            'Error: $message',
          );
        }
        // A mid-run Error is NOT necessarily terminal — a RecoveryNode or
        // the backend's own retry logic may still salvage the run, and the
        // authoritative terminal verdict arrives later as SequenceFailed /
        // SequenceCompleted. But leaving the state at `running` makes the UI
        // claim a healthy run while an error is being worked through. Escalate
        // to `recovering` only when we're currently `running` so the
        // dashboard surfaces the needs-attention state; the subsequent
        // terminal event flips it to failed/completed. We never downgrade
        // paused/stopping/terminal states here.
        if (_ref.read(sequenceExecutionStateProvider) ==
            SequenceExecutionState.running) {
          progressNotifier.updateState(SequenceExecutionState.recovering);
          _ref.read(sequenceExecutionStateProvider.notifier).state =
              SequenceExecutionState.recovering;
        }
        break;

      case 'InstructionProgressStructured':
        final nodeId = event.data['node_id'] as String?;
        final instruction = event.data['instruction'] as String? ?? '';
        final progressPercent =
            (event.data['progress_percent'] as num?)?.toDouble() ?? 0.0;
        final detailKind = event.data['detail_kind'] as String? ?? 'Unknown';
        final detailJson = decodeStructuredProgressJson(
          event.data['detail_json'],
        );
        final detail = InstructionProgressDetail.fromStructuredData(
          detailKind: detailKind,
          detailJson: detailJson,
        );

        // A Change Filter node is the ONLY place the running filter is named
        // on the wire. `SequencerEvent.ExposureStarted.filter` carries the
        // filter configured on the exposure node itself, which is null
        // whenever the operator selects the filter with a separate Change
        // Filter instruction — the normal way to author an LRGB/SHO plan. So
        // `currentFilter` stayed null for the whole run, and everything
        // downstream inherited the blank: the Run Dashboard's filter field,
        // and `captured_images.filter`, which `_registerSequenceFrame` reads
        // from here.
        //
        // Verified on the live rig: a run whose frames were written as
        // `untargeted_Filter 2_0001.fits` with `FILTER = 'Filter 2'` in the
        // FITS header produced `captured_images.filter = ''` and a run-watch
        // snapshot of `"currentFilter": null`. The app's own database
        // contradicted the file it had just written.
        if (detailKind == 'Filter' && detailJson is Map) {
          final filterName = detailJson['name'];
          if (filterName is String && filterName.isNotEmpty) {
            progressNotifier.updateProgress(currentFilter: filterName);
          }
        }

        final targetNodeId =
            nodeId ?? _ref.read(sequenceProgressProvider).currentNodeId;
        if (targetNodeId != null) {
          progressNotifier.updateNodeStructuredProgress(
            targetNodeId,
            progressPercent,
            detail,
          );
          progressNotifier.updateProgress(message: '$instruction: $detailKind');
        }
        break;

      case 'InstructionProgress':
        final nodeId = event.data['node_id'] as String?;
        final instruction = event.data['instruction'] as String? ?? '';
        final progressPercent =
            (event.data['progress_percent'] as num?)?.toDouble() ?? 0.0;
        final detail = event.data['detail'] as String? ?? '';

        _logger.debug(
          'InstructionProgress: nodeId=$nodeId, instruction=$instruction, progress=$progressPercent%, detail=$detail',
          source: 'SequenceExecutor',
        );

        // Use node_id from event, fallback to currentNodeId for backwards compatibility
        final targetNodeId =
            nodeId ?? _ref.read(sequenceProgressProvider).currentNodeId;
        _logger.debug(
          'Updating node progress for: $targetNodeId',
          source: 'SequenceExecutor',
        );
        if (targetNodeId != null) {
          progressNotifier.updateNodeProgress(
            targetNodeId,
            progressPercent,
            detail,
          );
          progressNotifier.updateProgress(message: '$instruction: $detail');
        }
        break;

      case 'MeridianFlipOutcome':
        _handleMeridianFlipOutcome(event);
        break;

      case 'TriggerFired':
        final triggerId = event.data['trigger_id'] as String? ?? '';
        final triggerName =
            event.data['trigger_name'] as String? ?? 'Unknown trigger';
        final action = event.data['action'] as String? ?? '';
        _incrementRunStat((stats) => stats.recordTriggerFire());
        // A target dropped by its own end_when is the one trigger fire that
        // costs the operator a whole target, so it goes on the run record
        // rather than only into the trigger feed — see
        // [targetEndWhenSkipWarning]. `recordWarning` collapses an exact
        // repeat of the previous entry, so a loop re-entering the same
        // already-closed target does not fill the list with copies.
        if (isTargetEndWhenSkip(triggerId)) {
          final warning = targetEndWhenSkipWarning(triggerName);
          _logger.warning(warning, source: 'SequenceExecutor');
          _incrementRunStat((stats) => stats.recordWarning(warning));
          progressNotifier.updateProgress(message: warning);
          break;
        }
        _logger.info(
          'Trigger fired: $triggerName -> $action',
          source: 'SequenceExecutor',
        );
        progressNotifier.updateProgress(
          message: 'Trigger "$triggerName" fired: $action',
        );
        break;

      case 'Started':
        // A new run answers for itself: the previous run's ParkAndAbort must
        // not be read as the cause of this one's stop.
        _ref.read(sequenceStopEvidenceProvider.notifier).state = null;
        progressNotifier.updateState(SequenceExecutionState.running);
        _ref.read(sequenceExecutionStateProvider.notifier).state =
            SequenceExecutionState.running;
        break;

      case 'Paused':
        progressNotifier.updateState(SequenceExecutionState.paused);
        _ref.read(sequenceExecutionStateProvider.notifier).state =
            SequenceExecutionState.paused;
        break;

      case 'Resumed':
        progressNotifier.updateState(SequenceExecutionState.running);
        _ref.read(sequenceExecutionStateProvider.notifier).state =
            SequenceExecutionState.running;
        break;

      case 'Completed':
      case 'SequenceCompleted':
        // Natural completion. Exactly-once teardown that ALSO ends the durable
        // session as completed. A duplicate/aliased Completed is ignored by
        // the guard in [_onTerminalEvent].
        _onTerminalEvent(SequenceExecutionState.completed, 'completed');
        break;

      case 'SequenceFailed':
        final error = event.data['error'] as String? ?? 'Unknown error';
        _onTerminalEvent(SequenceExecutionState.failed, 'failed', error: error);
        break;

      case 'Stopped':
      case 'SequenceStopped':
        // A native Stopped echoed after an explicit stop() is suppressed by
        // the terminal-cleanup guard (stop() claims teardown before issuing
        // sequencerStop). A native-initiated stop with no operator stop drives
        // the same exactly-once teardown here.
        //
        // A terminal this arm actually claims was therefore NOT commanded by
        // this executor's stop(): it came from the native side — a trigger's
        // ParkAndAbort, a watchdog, a safety abort. Filing it 'stopped'
        // recorded it byte-identically with the operator's own press, which
        // is what left three dawn-terminated runs claiming "you stopped it"
        // in `sequence_runs.status` (L52). The durable 'aborted' status —
        // "a safety rule or a trigger ended it", already rendered by every
        // history surface — separates them. The one exception: the wire may
        // still name the operator, which is how a remote/headless Stop lands
        // here without a local stop() drive. Its decision row keeps it
        // 'stopped'.
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
        break;

      case 'FrameAccepted':
        _recordGradedFrame(event, accepted: true);
        // The Rust grader now ships `save_path` for
        // accepted frames as well (it already did for rejected
        // frames). The thumbnail strip uses the on-disk path to load
        // an inline preview the same way it does for rejected frames
        // via `reject_path`.
        _registerSequenceFrame(event: event, isAccepted: true, grade: 'pass');
        // 2026-06-04 follow-up — auto-feed live stacking. When the
        // running sequence contains an enabled LiveStackingNode, every
        // accepted frame is fed into the live stacker + LAN broadcast
        // (the first becomes the reference automatically). Manual mode
        // still requires a hand-picked reference; this is the
        // unattended-run path.
        _maybeFeedLiveStacking(event);
        break;

      case 'FrameRejected':
        _recordGradedFrame(event, accepted: false);
        // The folder the rejects are piling up in is the first thing an
        // operator opens when a run dies on a reject storm, and the run record
        // is where he looks for it. Recorded from the grader's own
        // `reject_path` so it names the directory the files are actually in.
        final rejectPath = event.data['reject_path'] as String?;
        final rejectFolder = rejectPath == null
            ? null
            : parentDirectoryOf(rejectPath);
        if (rejectFolder != null) {
          _incrementRunStat((stats) => stats.recordRejectFolder(rejectFolder));
        }
        // Thumbnail — same as FrameAccepted, but with the
        // reject_path the Rust grader already ships so the strip can
        // surface a "REJECTED" tile that opens the actual file when
        // tapped.
        _registerSequenceFrame(
          event: event,
          isAccepted: false,
          grade: 'reject',
        );
        break;

      case 'PluginNodeRequested':
        // The Rust executor reached a
        // `NodeType::PluginNode` and is waiting for us to run the
        // plugin and reply with the verdict. Route through the
        // dispatcher provider (overridden by the app layer to plug in
        // the real `PluginNodeExecutor`); the default stub fails
        // loudly so an un-wired environment surfaces immediately
        // instead of hanging until Rust's 10-minute timeout.
        _dispatchPluginNode(event);
        break;

      case 'PluginNodeProgress':
        // Informational; plugin-authored intermediate
        // progress payload. The run dashboard's plugin-node panel
        // listens via its own provider; the sequence executor just
        // logs it so the timeline has the breadcrumb.
        final pluginId = event.data['plugin_id'] as String? ?? '';
        final nodeTypeId = event.data['node_type_id'] as String? ?? '';
        final detailJson = event.data['detail_json'] as String? ?? '';
        _logger.debug(
          'PluginNodeProgress: $pluginId/$nodeTypeId $detailJson',
          source: 'SequenceExecutor',
        );
        break;

      case 'DepthGoalCompleted':
        // A Smart Exposure plan that stopped on its depth goal rather than on
        // its frame count. Recorded as a durable decision row so the Session
        // Report can explain why the plan is short of its nominal count
        // without holding the goal store open — the score, the threshold it
        // cleared and the exposures behind it are the whole justification.
        _persistDepthGoalDecision(event);
        break;

      case 'DecisionLogged':
        // Replay Debug — persist the structured decision into
        // the `sequence_decisions` Drift table so the Replay screen
        // can scrub through the run later.
        _persistReplayDecision(event);
        break;
    }
  }

  /// Persist a `DepthGoalCompleted` payload as a `budget_met` decision row.
  ///
  /// `budget_met` rather than a category of its own: a depth goal IS the
  /// budget for a plan bound to one, and the replay feed already renders that
  /// bucket as "the plan stopped because it had enough". Fire-and-forget for
  /// the same reason as [_persistReplayDecision] — the executor's event loop
  /// must keep pumping.
  void _persistDepthGoalDecision(SkotiqEvent event) {
    final runId = _ref.read(currentRunIdProvider);
    if (runId == null) {
      _logger.debug(
        'DepthGoalCompleted dropped: no active sequence_run_id '
        '(goal ${event.data['goal_id']})',
        source: 'SequenceExecutor',
      );
      return;
    }
    final filterName = event.data['filter_name'] as String? ?? '';
    final score = (event.data['score'] as num?)?.toDouble() ?? 0;
    final threshold = (event.data['threshold'] as num?)?.toDouble() ?? 0;
    final evidenceFrames =
        (event.data['evidence_frames'] as num?)?.toInt() ?? 0;
    final confirmationFrames =
        (event.data['confirmation_frames'] as num?)?.toInt() ?? 0;
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
              'goal_id': event.data['goal_id'],
              'revision': event.data['revision'],
              'filter_name': filterName,
              'score': score,
              'threshold': threshold,
              'evidence_frames': evidenceFrames,
              'confirmation_frames': confirmationFrames,
            }),
            nodeId: event.data['node_id'] as String?,
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
  void _persistReplayDecision(SkotiqEvent event) {
    final timestampIso = event.data['timestamp_iso'] as String? ?? '';
    final category = event.data['category'] as String? ?? '';
    final summary = event.data['summary'] as String? ?? '';
    final detailsJson = event.data['details_json'] as String? ?? '{}';
    final nodeId = event.data['node_id'] as String?;
    final rustRunId = event.data['sequence_run_id'] as int?;
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
  void _dispatchPluginNode(SkotiqEvent event) {
    final nodeId = event.data['node_id'] as String? ?? '';
    final pluginId = event.data['plugin_id'] as String? ?? '';
    final nodeTypeId = event.data['node_type_id'] as String? ?? '';
    final configJson = event.data['config_json'] as String? ?? '';
    final displayName = event.data['display_name'] as String?;
    final timeoutSecs = event.data['timeout_secs'] as int? ?? 600;

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
  void _registerSequenceFrame({
    required SkotiqEvent event,
    required bool isAccepted,
    required String grade,
  }) {
    final nodeId = event.data['node_id'] as String?;
    if (nodeId == null || nodeId.isEmpty) {
      // No producing node — typically a wizard-driven capture (flat
      // wizard, polar-align). Nothing for the sequence-tree strip to
      // hang the row off of, so we skip.
      return;
    }
    final hfr = (event.data['hfr'] as num?)?.toDouble();
    final eccentricity = (event.data['eccentricity'] as num?)?.toDouble();
    final starCount = event.data['star_count'] as int?;
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
    final capture = FrameCapture.fromEventData(event.data);
    // Accepted frames now carry the on-disk save_path
    // alongside the existing rejected-frame reject_path. The thumbnail
    // strip uses whichever field is populated to load the inline
    // preview. `save_path` may legitimately be null on legacy emit
    // sites that did not thread the path through; defaulting to empty
    // string keeps the "no thumbnail yet" colour-bordered tile rather
    // than skipping the row entirely.
    final filePath = isAccepted
        ? (event.data['save_path'] as String? ?? '')
        : (event.data['reject_path'] as String? ?? '');
    final fileName = filePath.isEmpty ? '' : p.basename(filePath);
    final rejectionReason = isAccepted
        ? null
        : (event.data['reason'] as String?);
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
  void _recordGradedFrame(SkotiqEvent event, {required bool accepted}) {
    final capture = FrameCapture.fromEventData(event.data);
    _recordRunFrame(
      exposureSecs: capture.exposureSecs ?? 0.0,
      filter: event.data['filter'] as String?,
      accepted: accepted,
    );
    _fetchAndDisplaySequenceImage(
      _previewSettingsForFrame(capture, capture.exposureSecs ?? 0.0),
    );
    final frame = (event.data['frame'] as num?)?.toInt();
    if (frame == null) return;
    _gradedFrames[frame] = (accepted: accepted, capture: capture);
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
    _incrementRunStat((stats) {
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
    _incrementRunStat((stats) => stats.recordError(message));
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
    _incrementRunStat((stats) => stats.recordTerminalError(message));
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
  void _handleMeridianFlipOutcome(SkotiqEvent event) {
    final progressNotifier = _ref.read(sequenceProgressProvider.notifier);
    final outcome = event.data['outcome'] as String? ?? 'unknown';
    final targetName = event.data['target_name'] as String? ?? 'target';
    final attempts = (event.data['attempts'] as num?)?.toInt() ?? 0;
    final durationSecs = (event.data['duration_secs'] as num?)?.toDouble() ?? 0;
    final error = event.data['error'] as String?;
    final actionTaken = event.data['action_taken'] as String?;
    final failedSteps =
        (event.data['failed_steps'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];

    switch (outcome) {
      case 'success':
        _incrementRunStat((stats) => stats.recordMeridianFlip());
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
          _incrementRunStat((stats) => stats.recordWarning(message));
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
        _incrementRunStat((stats) => stats.recordWarning(message));
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

  /// Mutate the live run stats and (by default) schedule an incremental
  /// `updateStats` write.
  ///
  /// [persist] = `false` records the mutation in memory only. It is for facts
  /// established at run START that are constant for the whole run (e.g. "this
  /// rig has no focuser, so refocus is off"). Those are already carried into
  /// `sequence_runs.stats_json` by the final `finishRun` write, and there is no
  /// mid-run window in which a crash could lose them but keep the run row — so
  /// an extra DB round-trip buys nothing, and every such write is one more
  /// chance to land after the finalization seal.
  void _incrementRunStat(
    void Function(SequenceRunStats stats) update, {
    bool persist = true,
  }) {
    // Once finalization has sealed the stats for the final finishRun write, no
    // further incremental mutation/persist may occur — a late/old-generation
    // event must not overwrite the final stats JSON.
    if (_statsSealed) {
      return;
    }
    final stats = _ref.read(liveSequenceStatsProvider);
    if (stats == null) {
      return;
    }
    update(stats);
    // Store a fresh COPY so the identity changes: [liveSequenceStatsProvider] is
    // a StateProvider whose updateShouldNotify is `!identical(prev, next)`, so
    // re-storing the same mutated instance would notify NO consumer (the live
    // Session Vitals tile / run dashboard would silently stop updating).
    _ref.read(liveSequenceStatsProvider.notifier).state = stats.copy();
    if (persist) _persistLiveRunStats();
  }

  void _persistLiveRunStats() {
    // Sealed: the final finishRun write owns the stats now. Skipping here (plus
    // draining already-submitted writes in [_finalizeRun]) guarantees no stale
    // updateStats lands after the final stats JSON.
    if (_statsSealed) {
      return;
    }
    final runId = _ref.read(currentRunIdProvider);
    final stats = _ref.read(liveSequenceStatsProvider);
    if (runId == null || stats == null) {
      return;
    }
    // Track the write so [_finalizeRun] can drain it before the final finish.
    final Future<void> write = _ref
        .read(sequenceRunsDaoProvider)
        .updateStats(runId, stats.toJson());
    _pendingStatWrites.add(write);
    // The failure has to be handled HERE, not only in [_drainPendingStatWrites]
    // — that only covers writes still pending when finalization drains, so a
    // write that failed earlier in the night reached the zone as an unhandled
    // async error. `whenComplete` forwards the error to its derived future, so
    // it is not a handler.
    final logger = _logger;
    unawaited(
      write
          .catchError((Object e) {
            logger.warning(
              'Failed to persist live run stats for run $runId: $e',
              source: 'SequenceExecutor',
            );
          })
          .whenComplete(() => _pendingStatWrites.remove(write)),
    );
  }

  /// Finalize the current run row and fire the once-per-run session-end hooks.
  ///
  /// Awaitable (contract: "finalization awaitable; clear IDs only after true
  /// finish success"): the caller awaits the durable `finishRun` write so the
  /// run id is only cleared once the finish has actually persisted, and a
  /// finish failure surfaces to the stop / terminal path instead of being
  /// swallowed by a fire-and-forget future.
  ///
  /// The `_runFinalized` guard is latched only AFTER `finishRun` succeeds — so
  /// it is an exactly-once guard for the SUCCESS path, never a permanent latch
  /// that would swallow a retry after a failed finish (a failed cleanup must be
  /// retryable, so a subsequent Stop can re-run this).
  Future<void> _finalizeRun(String status) async {
    if (_runFinalized) {
      return;
    }
    final runId = _ref.read(currentRunIdProvider);
    final stats = _ref.read(liveSequenceStatsProvider);
    if (runId == null || stats == null) {
      return;
    }
    // Seal the stats BEFORE the final write so no further incremental
    // updateStats can be SUBMITTED, then DRAIN the writes already in flight so
    // none of them lands AFTER finishRun and clobbers the final stats JSON.
    // Sealing is idempotent, so a Stop retry after a failed finish re-runs this
    // safely.
    _statsSealed = true;
    await _drainPendingStatWrites();
    stats.endTime = DateTime.now();
    final statsJson = stats.toJson();
    await _ref
        .read(sequenceRunsDaoProvider)
        .finishRun(runId, status, statsJson);
    _runFinalized = true;
    // Surface post-session diagnostics + clear the NotificationRouter override.
    // Fires exactly once per run (guarded by the `_runFinalized` latch above,
    // which is only set once the finish has persisted).
    _captureSessionEndHooks();
  }

  /// Await every incremental `updateStats` write submitted before the stats
  /// were sealed, so no stale write can race the final `finishRun`. Individual
  /// write errors are swallowed (they do not block finalization); the snapshot-
  /// and-clear means new writes (blocked while sealed) cannot re-populate the
  /// set mid-drain.
  Future<void> _drainPendingStatWrites() async {
    if (_pendingStatWrites.isEmpty) {
      return;
    }
    final batch = _pendingStatWrites.toList();
    _pendingStatWrites.clear();
    await Future.wait(batch.map((w) => w.catchError((Object _) {})));
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
  void _maybeFeedLiveStacking(SkotiqEvent event) {
    final node = _findActiveLiveStackingNode();
    if (node == null) return; // Sequence has no live stacking — nothing to do.

    final savePath = event.data['save_path'] as String?;
    if (savePath == null || savePath.isEmpty) {
      // An accepted frame with no on-disk path cannot be fed. This is a
      // real wiring problem (the Rust grader is expected to ship
      // `save_path` for accepted frames), so we fail LOUD rather than
      // silently dropping the frame from the live stack.
      _logger.error(
        'Live-stacking auto-feed: accepted frame from node '
        '${event.data['node_id']} carried no save_path; cannot add it to the '
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
  double _resolveLiveStackExposureSecs(SkotiqEvent event) {
    final nodeId = event.data['node_id'] as String?;
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
    return (event.data['duration_secs'] as num?)?.toDouble() ?? 0.0;
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
