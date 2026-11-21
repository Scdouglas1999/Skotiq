import 'dart:async';

import '../../../models/sequence/sequence_models.dart';
import '../../../services/live_stacking_broadcast_service.dart';
import '../../../utils/logging_service.dart';
import '../../live_stacking_provider.dart';
import '../../../backend/bridge_events.dart' show SequencerEvent_FrameAccepted;
import '../../../models/imaging/live_stacking_models.dart';

/// Feeds a run's accepted frames to the live stacker and its LAN broadcast.
///
/// The native `LiveStacking` node only arms a broadcast session; Dart is the
/// only thing that can feed the stacker. When the running sequence has an
/// enabled [LiveStackingNode], its first accepted frame becomes the stack's
/// reference and every later one is added. Feeds are serialized: an add that
/// overtook the reference start would corrupt the stack's coordinate system.
/// A frame that cannot be fed is logged loudly; the run itself keeps imaging.
///
/// Even without a [LiveStackingNode], if the user has opted in by manually
/// arming or starting a live stack with `autoFeedEnabled`, accepted light
/// frames are forwarded with their filter, exposure, HFR, and star count so
/// per-filter live stacks update automatically during normal sequences.
class LiveStackingFeed {
  LiveStackingFeed({
    required Sequence? Function() sequence,
    required SequenceProgress Function() progress,
    required LiveStackingBroadcastService Function() broadcast,
    required LiveStackingNotifier Function() stacker,
    required LiveStackingState Function() stackState,
    required LoggingService Function() logger,
  }) : _sequence = sequence,
       _progress = progress,
       _broadcast = broadcast,
       _stacker = stacker,
       _stackState = stackState,
       _logger = logger;

  final Sequence? Function() _sequence;
  final SequenceProgress Function() _progress;
  final LiveStackingBroadcastService Function() _broadcast;
  final LiveStackingNotifier Function() _stacker;
  final LiveStackingState Function() _stackState;
  final LoggingService Function() _logger;

  /// Whether this run's stack has its reference frame (started by a sequence
  /// [LiveStackingNode]).
  bool _armed = false;

  /// The tail of the serialized feed chain; null when nothing is queued.
  Future<void>? _chain;

  /// The feed queued last, for tests waiting on quiescence.
  Future<void>? get pending => _chain;

  /// Forget the previous run's stack, so a new run never inherits its
  /// reference frame.
  void resetForRun() {
    _armed = false;
    _chain = null;
  }

  /// Queue [event]'s frame for the stack. A no-op when neither the running
  /// sequence nor the user has opted into live stacking.
  void feed(SequencerEvent_FrameAccepted event) {
    final node = _activeNode();
    final state = _stackState();
    final userOptedIn =
        node == null && state.isActiveOrArmed && state.config.autoFeedEnabled;
    if (node == null && !userOptedIn) return;

    // For manually armed opt-in stacking during a general sequence, only feed
    // light frames (never Darks, Flats, or Biases).
    if (userOptedIn &&
        event.capture.frameType.trim().isNotEmpty &&
        event.capture.frameType.trim().toLowerCase() != 'light') {
      return;
    }

    final savePath = event.savePath;
    if (savePath == null || savePath.isEmpty) {
      if (node != null) {
        _logger().error(
          'Live-stacking auto-feed: accepted frame from node '
          '${event.nodeId} carried no save_path; cannot add it to the '
          'live stack. The broadcast stack will be missing this frame.',
          source: 'SequenceExecutor',
        );
      }
      return;
    }

    // The camera's reported exposure, which the frame's row records too, for
    // the broadcast's integration counter.
    final exposureSecs = event.capture.exposureSecs;
    final filterName = _progress().currentFilter;
    final previous = _chain ?? Future<void>.value();
    if (node != null) {
      _chain = previous.then(
        (_) => _feedFrame(
          node: node,
          savePath: savePath,
          exposureSecs: exposureSecs,
          filterName: filterName,
          hfr: event.hfr,
          starCount: event.starCount,
        ),
      );
    } else {
      _chain = previous.then(
        (_) => _feedManualOptInFrame(
          savePath: savePath,
          exposureSecs: exposureSecs,
          filterName: filterName,
          hfr: event.hfr,
          starCount: event.starCount,
        ),
      );
    }
  }

  /// Stop the broadcast and the stacker at the end of a run, after any queued
  /// feed finishes, so a stopped run cannot keep serving a stale stack.
  /// Idempotent.
  Future<void> teardown() async {
    final wasArmed = _armed;
    _armed = false;
    final chain = _chain;
    _chain = null;
    if (chain != null) {
      try {
        await chain;
      } catch (_) {
        // Already logged by the feed.
      }
    }
    _broadcast().deactivate();
    // The first frame's start can finish during the drain above and set
    // [_armed] after [wasArmed] was captured. That stack belongs to this run.
    final armedByThisRun = wasArmed || _armed;
    _armed = false;
    if (!armedByThisRun) {
      // Manual opt-in stacks belong to the operator, not the sequence node, so
      // drain the queued feed chain above without tearing down their session.
      return;
    }
    try {
      await _stacker().stop();
    } catch (e) {
      _logger().warning(
        'Live-stacking auto-feed: failed to stop the stacker on teardown: $e',
        source: 'SequenceExecutor',
      );
    }
  }

  LiveStackingNode? _activeNode() {
    final sequence = _sequence();
    if (sequence == null) return null;
    for (final node in sequence.enabledNodes) {
      if (node is LiveStackingNode) return node;
    }
    return null;
  }

  /// The native stacker's only rejection knob is sigma clipping, so `average`
  /// runs without it and the rejecting methods with it.
  LiveStackingConfig _configFor(LiveStackingNode node) => LiveStackingConfig(
    sigmaClipEnabled: node.stackMethod != LiveStackingMethod.average,
  );

  Future<void> _feedManualOptInFrame({
    required String savePath,
    required double exposureSecs,
    String? filterName,
    double? hfr,
    int? starCount,
  }) async {
    final state = _stackState();
    if (!state.isActiveOrArmed || !state.config.autoFeedEnabled) return;
    try {
      await _stacker().addFrameFromFileWithMetadata(
        savePath,
        filter: filterName,
        exposureSecs: exposureSecs,
        hfr: hfr,
        starCount: starCount,
      );
    } catch (e) {
      _logger().warning(
        'Live-stacking opt-in auto-feed skipped $savePath: $e',
        source: 'SequenceExecutor',
      );
    }
  }

  Future<void> _feedFrame({
    required LiveStackingNode node,
    required String savePath,
    required double exposureSecs,
    String? filterName,
    double? hfr,
    int? starCount,
  }) async {
    final broadcast = _broadcast();
    final stacker = _stacker();
    final logger = _logger();
    try {
      if (!_armed) {
        broadcast.activate(node);
        broadcast.updateCurrentTarget(_progress().currentTarget);
        if (filterName != null && filterName.trim().isNotEmpty) {
          await stacker.startFromFileForFilter(
            savePath,
            filterKey: normalizeLiveStackFilterKey(filterName),
            config: _configFor(node),
          );
        } else {
          await stacker.startFromFile(savePath, config: _configFor(node));
        }
        if (_stackState().status != LiveStackingStatus.running) {
          logger.error(
            'Live-stacking auto-feed: failed to start the stacker from the '
            'first accepted frame ($savePath): '
            '${_stackState().errorMessage ?? 'unknown error'}. '
            'Live stack/broadcast will not run for this sequence.',
            source: 'SequenceExecutor',
          );
          broadcast.deactivate();
          return;
        }
        _armed = true;
        logger.info(
          'Live-stacking auto-feed armed: reference frame $savePath '
          '(method=${node.stackMethod.label})',
          source: 'SequenceExecutor',
        );
      } else {
        // 0 means unlimited.
        final cap = node.maxFramesToStack;
        if (cap > 0 && _stackState().totalFramesAcrossFilters >= cap) {
          logger.debug(
            'Live-stacking auto-feed: frame cap ($cap) reached; not adding '
            '$savePath to the stack.',
            source: 'SequenceExecutor',
          );
          return;
        }
        broadcast.updateCurrentTarget(_progress().currentTarget);
        await stacker.addFrameFromFileWithMetadata(
          savePath,
          filter: filterName,
          exposureSecs: exposureSecs,
          hfr: hfr,
          starCount: starCount,
        );
      }

      final state = _stackState();
      final preview = state.previewData;
      if (preview == null ||
          state.previewWidth <= 0 ||
          state.previewHeight <= 0) {
        logger.warning(
          'Live-stacking auto-feed: stack has no preview after feeding '
          '$savePath; broadcast image not updated this frame.',
          source: 'SequenceExecutor',
        );
        return;
      }
      broadcast.publishFrame(
        width: state.previewWidth,
        height: state.previewHeight,
        previewData: preview,
        exposureSecs: exposureSecs,
      );
    } catch (e, st) {
      logger.error(
        'Live-stacking auto-feed: failed to add accepted frame $savePath to '
        'the live stack: $e\n$st',
        source: 'SequenceExecutor',
      );
    }
  }
}
