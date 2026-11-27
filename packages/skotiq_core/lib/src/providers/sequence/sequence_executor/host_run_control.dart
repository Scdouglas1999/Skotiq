import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../backend/remote_host.dart';
import '../../../backend/skotiq_backend.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../../services/session_handoff_service.dart';
import '../../../utils/logging_service.dart';
import '../../linked_host.dart';
import '../../sequence_file_service_provider.dart';
import '../../sequence_provider.dart'
    show
        currentSequenceProvider,
        runRecordProvider,
        sequenceExecutionStateProvider;
import '../../session_handoff_provider.dart';

/// The run of a client linked to an imaging host on another machine. The
/// host owns the hardware, the database and the run; this client asks it to
/// start, stop and restore, and shows the host's run state.
class HostRunControl {
  HostRunControl(
    this._host, {
    required Ref ref,
    required SkotiqBackend backend,
    required LoggingService Function() logger,
    required void Function(SequenceExecutionState) setExecutionState,
    required Object Function() noSequenceLoaded,
  }) : _ref = ref,
       _backend = backend,
       _logger = logger,
       _setExecutionState = setExecutionState,
       _noSequenceLoaded = noSequenceLoaded;

  final Ref _ref;
  final SkotiqBackend _backend;
  final HostRunState _host;
  final LoggingService Function() _logger;
  final void Function(SequenceExecutionState) _setExecutionState;
  final Object Function() _noSequenceLoaded;

  /// The host restored its checkpoint at this client's request; the next
  /// start continues that run on the host instead of sending the editor's
  /// plan.
  bool _restoreAwaitingStart = false;

  /// Whether a checkpoint restore on the host is waiting for [start].
  bool get hasRestoredCheckpoint => _restoreAwaitingStart;

  /// The host restores its own checkpoint into its executor and editor; the
  /// next start continues it there.
  Future<void> restoreFromCheckpoint() async {
    await _backend.resumeFromCheckpoint();
    _restoreAwaitingStart = true;
    final info = await _backend.getCheckpointInfo();
    _ref.read(runRecordProvider.notifier).setRestoredCheckpoint(info);
    _ref
        .read(runRecordProvider.notifier)
        .setFramesDoneBeforeRun(
          info?.framesDoneByStep ?? const {},
          byFilter: info?.filterFramesDoneByStep ?? const {},
        );
  }

  /// A reset starts the next run from the beginning, so a restore waiting
  /// for start is forgotten. The host's reset clears its durable checkpoint.
  void forgetRestore() => _restoreAwaitingStart = false;

  /// Start the run on the imaging host this client controls.
  ///
  /// The host owns the hardware, the database and the run, so a remote client
  /// opens no session or run record of its own: it puts the plan the operator
  /// sees into the host's editor and asks the host to start it, which runs the
  /// host's own pre-flight and records. A plan restored from the host's
  /// checkpoint is already in the host's executor and is started as it is.
  Future<void> start() async {
    final ignoreHistory = _ref.read(
      sessionHandoffIgnoreUnavailableOnceProvider,
    );
    if (ignoreHistory) {
      _ref.read(sessionHandoffIgnoreUnavailableOnceProvider.notifier).state =
          false;
    }
    if (!_restoreAwaitingStart) {
      _ref.read(runRecordProvider.notifier).setFramesDoneBeforeRun(const {});
      final sequence = _ref.read(currentSequenceProvider);
      if (sequence == null) throw _noSequenceLoaded();
      await _host.putOpenEditorSequence(
        _ref.read(sequenceFileServiceProvider).sequenceToMap(sequence),
        databaseId: sequence.databaseId,
        isDirty: _ref.read(currentSequenceProvider.notifier).isDirty,
      );
    }
    final decisions = await _clientHandoffForHost(ignoreHistory);
    if (decisions.isEmpty && !ignoreHistory) {
      await _backend.sequencerStart();
    } else {
      await _host.sequencerStartOnHost(
        handoffDecisions: decisions,
        ignoreUnavailableHistory: ignoreHistory,
      );
    }
    if (_restoreAwaitingStart) {
      _restoreAwaitingStart = false;
      _ref.read(runRecordProvider.notifier).setRestoredCheckpoint(null);
    }
    _logger().info(
      'Started the run on the imaging host '
      '${_ref.read(linkedHostLinkProvider)?.serverHost}',
      source: 'SequenceExecutor',
    );
    await _reflectHostRunState();
  }

  /// The operator's handoff choices on this client. The host seeds from its
  /// own history after Start, so the choices have to travel with the request.
  /// A history read that throws is not "no history": without an explicit
  /// confirmation the start fails and the host is not asked to run.
  Future<Map<String, String>> _clientHandoffForHost(bool ignoreHistory) async {
    final sequence = _ref.read(currentSequenceProvider);
    final decisions = <String, String>{};
    if (sequence != null && sequence.targetHeaders.isNotEmpty) {
      List<SessionCarryOver> carry = const [];
      try {
        carry = await _ref.read(sessionCarryOverProvider.future);
      } catch (error, stackTrace) {
        if (!ignoreHistory) {
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
      for (final entry in carry) {
        final decision = _ref.read(
          sessionHandoffDecisionProvider((
            sequenceId: sequence.databaseId,
            targetId: entry.targetId,
          )),
        );
        if (decision != null) {
          decisions['${entry.targetId}'] = decision.name;
        }
      }
    }
    return decisions;
  }

  /// Stop the run on the imaging host through the host's own executor, which
  /// finalizes its run and session records.
  Future<void> stop({required bool preserveCheckpoint}) async {
    final before = _ref.read(sequenceExecutionStateProvider);
    if (!before.canStop) return;
    _setExecutionState(SequenceExecutionState.stopping);
    var stopped = false;
    try {
      await _host.sequencerStopOnHost(preserveCheckpoint: preserveCheckpoint);
      stopped = true;
    } finally {
      if (!stopped) _setExecutionState(before);
    }
    await _reflectHostRunState();
  }

  /// Show the host's run state at once rather than after the next mirrored
  /// event. A failed read leaves the state to the event mirror.
  Future<void> _reflectHostRunState() async {
    try {
      final status = await _backend.sequencerGetStatus();
      _ref.read(runRecordProvider.notifier).mirrorHostState(status.state);
    } catch (e) {
      _logger().debug(
        'Could not read the host run state after a command: $e',
        source: 'SequenceExecutor',
      );
    }
  }
}
