part of '../sequencer_handlers.dart';

/// Crash-recovery checkpoints and the standalone meridian flip.
extension _SequencerCheckpoints on SequencerHandlers {
  /// POST /api/sequencer/checkpoint/dir.
  ///
  /// The host owns its crash-recovery storage layout: a client-supplied path
  /// is refused, and an empty body re-asserts the host's own directory. A
  /// paired client's documents directory does not exist on the rig, so
  /// accepting one fails every later checkpoint write and makes a mid-night
  /// crash unrecoverable.
  Future<Response> _handleSequencerSetCheckpointDir(Request request) async {
    _logInfo('[API] POST /api/sequencer/checkpoint/dir');
    final payload = await readJsonObject(request);
    final requested = optionalString(payload, 'path')?.trim();
    if (requested != null && requested.isNotEmpty) {
      _logger.warning(
        'Refused client-supplied checkpoint directory "$requested" — the host '
        'owns its crash-recovery storage layout',
        source: 'SequencerHandlers',
        fields: {'requestedPath': requested},
      );
      return jsonForbidden({
        'error':
            'The host owns its crash-recovery checkpoint directory; a client '
            'cannot set it. Omit "path" to re-assert the host directory.',
        'code': 'checkpoint_dir_host_owned',
      });
    }

    final Directory directory;
    try {
      directory = await resolveHostCheckpointDirectory();
    } on FileSystemException catch (error) {
      return jsonBadRequest({
        'error':
            'The host checkpoint directory is not usable: ${error.message}. '
            'Crash recovery is disabled until it can be written to.',
        'code': 'checkpoint_dir_unwritable',
      });
    }

    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerSetCheckpointDir(directory.path);
    return jsonOk({'status': 'ok', 'path': directory.path});
  }

  Future<Response> _handleSequencerHasCheckpoint(Request request) async {
    final backend = container.read(sequencerBackendProvider);
    final hasCheckpoint = await backend.hasCheckpoint();
    return jsonOk({'hasCheckpoint': hasCheckpoint});
  }

  Future<Response> _handleSequencerGetCheckpointInfo(Request request) async {
    final backend = container.read(sequencerBackendProvider);
    final info = await backend.getCheckpointInfo();
    return jsonOk({'info': info?.toJson()});
  }

  /// POST /api/sequencer/checkpoint/resume.
  ///
  /// Restores the interrupted run (sequence, progress, devices) and leaves it
  /// ready: nothing moves, and the answer is `status: restored`. A later
  /// `POST /api/sequencer/start` continues it from the checkpoint. A body of
  /// `{"start": true}` restores and starts at once (`status: resumed`).
  Future<Response> _handleSequencerResumeFromCheckpoint(Request request) async {
    _logInfo('[API] POST /api/sequencer/checkpoint/resume');
    final payload = await readJsonObjectOrEmpty(request);
    final startNow = optionalBool(payload, 'start') == true;
    // A resume commands the mount exactly like a start does, but neither the
    // executor's resume path nor the native restore runs any pre-flight: the
    // checkpoint is replayed verbatim. A checkpoint written before target
    // coordinates were validated (or by an older build) therefore resumed
    // straight back into the wrong slew. Check the tree this resume will
    // actually execute first.
    final rejection = await _rejectUnpointableCheckpoint();
    if (rejection != null) return rejection;
    // Route through the SequenceExecutor provider so the editor tree, the
    // progress and the native prepared resume agree, and so a later start
    // continues the checkpoint instead of reloading the sequence.
    final executor = container.read(sequenceExecutorProvider);
    if (startNow) {
      await executor.resumeFromCheckpoint();
      return jsonOk({'status': 'resumed'});
    }
    await executor.restoreFromCheckpoint();
    return jsonOk({'status': 'restored'});
  }

  /// Reject a checkpoint resume whose sequence still carries an unset target
  /// pointing, using the same [TargetCoordinatesUnsetRule] the desktop start
  /// path enforces.
  ///
  /// Scope is deliberately narrow — only the pointing rule, not the full
  /// validator stack. A resume happens mid-night with hardware in whatever
  /// state the interruption left it, so running the equipment / disk-space /
  /// dark-library rules here would refuse resumes that are perfectly fine to
  /// finish. The one thing that must never be replayed is a slew to a target
  /// that does not know where it is.
  ///
  /// Anything that stops us from reading the tree (no checkpoint info, no
  /// stored snapshot, a snapshot that no longer parses) returns null and lets
  /// the resume proceed: imaging with an unverifiable tree still beats
  /// refusing to finish the night over bookkeeping.
  Future<Response?> _rejectUnpointableCheckpoint() async {
    Sequence? sequence;
    try {
      // The executor resumes the already-open editor tree when there is one and
      // only falls back to the interrupted run's stored snapshot otherwise.
      // Mirror that order so this checks the same tree that will run.
      sequence = container.read(currentSequenceProvider);
      if (sequence == null) {
        final info = await container
            .read(sequencerBackendProvider)
            .getCheckpointInfo();
        if (info == null) return null;
        final snapshot = await container
            .read(sequenceRunsDaoProvider)
            .latestSnapshotForSequenceName(info.sequenceName);
        if (snapshot == null || snapshot.trim().isEmpty) return null;
        final decoded = jsonDecode(snapshot);
        if (decoded is! Map<String, dynamic>) return null;
        sequence = container
            .read(sequenceFileServiceProvider)
            .parseFromMap(decoded);
      }
    } catch (e) {
      _logger.warning(
        'Could not pre-check the checkpoint before resuming: $e',
        source: 'SequencerHandlers',
      );
      return null;
    }

    final issues = TargetCoordinatesUnsetRule()
        .validate(sequence)
        .where((i) => i.severity == ValidationSeverity.error)
        .toList(growable: false);
    if (issues.isEmpty) return null;
    _logInfo(
      '[API] checkpoint resume rejected: ${issues.length} '
      'target${issues.length == 1 ? '' : 's'} still on '
      'the RA 0h / Dec +0 placeholder',
    );
    return jsonBadRequest({
      'error': 'sequence_validation_failed',
      'code': 'sequence_validation_failed',
      'message':
          'Cannot resume: ${issues.length} validation '
          '${issues.length == 1 ? 'error' : 'errors'}: '
          '${issues.map((i) => i.title).join('; ')}',
      'errorCount': issues.length,
      'warningCount': 0,
      'issues': issues
          .map(
            (i) => {
              'severity': i.severity.name,
              'category': i.category.name,
              'title': i.title,
              'description': i.description,
              if (i.resolutionHint != null) 'resolutionHint': i.resolutionHint,
              if (i.affectedNodeId != null) 'affectedNodeId': i.affectedNodeId,
              if (i.code != null) 'code': i.code,
            },
          )
          .toList(growable: false),
    });
  }

  Future<Response> _handlePerformMeridianFlip(Request request) async {
    _logInfo('[API] POST /api/sequencer/meridian-flip');
    final payload = await readJsonObject(request);
    final mountId = requireString(payload, 'mountId', maxLength: 512).trim();
    final targetName = requireString(
      payload,
      'targetName',
      maxLength: 512,
    ).trim();
    if (mountId.isEmpty || targetName.isEmpty) {
      throw BadRequestError(
        field: mountId.isEmpty ? 'mountId' : 'targetName',
        expected: 'non-empty string',
        message: 'Device and target identifiers must not be blank',
      );
    }
    String? optionalDeviceId(String field) {
      final value = optionalString(payload, field, maxLength: 512)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final backend = container.read(sequencerBackendProvider);
    await backend.performMeridianFlip(
      mountId: mountId,
      cameraId: optionalDeviceId('cameraId'),
      focuserId: optionalDeviceId('focuserId'),
      coverCalibratorId: optionalDeviceId('coverCalibratorId'),
      targetName: targetName,
      targetRaHours: requireDouble(payload, 'targetRaHours', min: 0, max: 24),
      targetDecDegrees: requireDouble(
        payload,
        'targetDecDegrees',
        min: -90,
        max: 90,
      ),
      pauseGuiding: optionalBool(payload, 'pauseGuiding') ?? true,
      autoCenter: optionalBool(payload, 'autoCenter') ?? true,
      refocusAfter: optionalBool(payload, 'refocusAfter') ?? false,
      resumeGuiding: optionalBool(payload, 'resumeGuiding') ?? true,
      settleTimeSecs:
          optionalDouble(payload, 'settleTimeSecs', min: 0, max: 3600) ?? 10.0,
    );
    return jsonOk({'status': 'flipped'});
  }

  /// POST `/api/sequencer/request-meridian-flip`.
  ///
  /// Asks the running sequence to flip at its next safe point through its own
  /// meridian trigger. Answers once the request is queued
  /// (`status: flip_requested`); the flip's outcome arrives on the event
  /// stream. A request the run refuses (target not past the meridian, mount
  /// parked, run paused, ...) answers 409 `flip_refused` with the reason.
  Future<Response> _handleSequencerRequestMeridianFlip(Request request) async {
    _logInfo('[API] POST /api/sequencer/request-meridian-flip');
    final backend = container.read(sequencerBackendProvider);
    try {
      await backend.sequencerRequestMeridianFlip();
    } on HandlerFailure {
      rethrow;
    } catch (error) {
      throw HandlerFailure(
        code: 'flip_refused',
        statusCode: 409,
        message: describeBackendError(error),
      );
    }
    return jsonOk({'status': 'flip_requested'});
  }

  Future<Response> _handleSequencerDiscardCheckpoint(Request request) async {
    _logInfo('[API] POST /api/sequencer/checkpoint/discard');
    final backend = container.read(sequencerBackendProvider);
    await backend.discardCheckpoint();
    return jsonOk({'status': 'discarded'});
  }

  Future<Response> _handleSequencerSaveCheckpoint(Request request) async {
    _logInfo('[API] POST /api/sequencer/checkpoint/save');
    final backend = container.read(sequencerBackendProvider);
    await backend.saveCheckpoint();
    return jsonOk({'status': 'saved'});
  }
}
