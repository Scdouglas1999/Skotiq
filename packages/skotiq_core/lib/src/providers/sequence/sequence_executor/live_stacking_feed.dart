import 'dart:async';

import '../../../models/sequence/sequence_models.dart';
import '../../../services/live_stacking_broadcast_service.dart';
import '../../../services/live_stacking_service.dart' show LiveStackingConfig;
import '../../../services/logging_service.dart';
import '../../live_stacking_provider.dart';
import '../sequencer_run_event.dart' show FrameAccepted;
import 'frame_attribution.dart';

/// Feeds a run's accepted frames to the live stacker and its LAN broadcast.
///
/// The native `LiveStacking` node only arms a broadcast session; Dart is the
/// only thing that can feed the stacker. When the running sequence has an
/// enabled [LiveStackingNode], its first accepted frame becomes the stack's
/// reference and every later one is added. Feeds are serialized: an add that
/// overtook the reference start would corrupt the stack's coordinate system.
/// A frame that cannot be fed is logged loudly; the run itself keeps imaging.
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

  /// Whether this run's stack has its reference frame.
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

  /// Queue [event]'s frame for the stack. A no-op when the running sequence
  /// does not live-stack.
  void feed(FrameAccepted event) {
    final node = _activeNode();
    if (node == null) return;

    final savePath = event.savePath;
    if (savePath == null || savePath.isEmpty) {
      _logger().error(
        'Live-stacking auto-feed: accepted frame from node '
        '${event.nodeId} carried no save_path; cannot add it to the '
        'live stack. The broadcast stack will be missing this frame.',
        source: 'SequenceExecutor',
      );
      return;
    }

    final exposureSecs = _exposureSecs(event);
    final previous = _chain ?? Future<void>.value();
    _chain = previous.then(
      (_) => _feedFrame(
        node: node,
        savePath: savePath,
        exposureSecs: exposureSecs,
      ),
    );
  }

  /// Stop the broadcast and the stacker at the end of a run, after any queued
  /// feed finishes, so a stopped run cannot keep serving a stale stack.
  /// Idempotent.
  Future<void> teardown() async {
    if (!_armed) {
      // The broadcast may have been activated by a reference start that then
      // failed; deactivating an inactive broadcast is a no-op.
      _broadcast().deactivate();
      return;
    }
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
    for (final node in sequence.nodes.values) {
      if (node is LiveStackingNode && node.isEnabled) return node;
    }
    return null;
  }

  /// The native stacker's only rejection knob is sigma clipping, so `average`
  /// runs without it and the rejecting methods with it.
  LiveStackingConfig _configFor(LiveStackingNode node) => LiveStackingConfig(
    sigmaClipEnabled: node.stackMethod != LiveStackingMethod.average,
  );

  /// The producing node's exposure (the source the captured-images row uses),
  /// else the event's own duration, for the broadcast's integration counter.
  double _exposureSecs(FrameAccepted event) {
    final nodeId = event.nodeId;
    final sequence = _sequence();
    if (nodeId != null && sequence != null) {
      final attribution = resolveFrameAttribution(
        sequence,
        nodeId,
        currentFilter: _progress().currentFilter,
      );
      final secs = attribution.exposureSecs;
      if (secs != null) return secs;
    }
    return event.durationSecs ?? 0.0;
  }

  Future<void> _feedFrame({
    required LiveStackingNode node,
    required String savePath,
    required double exposureSecs,
  }) async {
    final broadcast = _broadcast();
    final stacker = _stacker();
    final logger = _logger();
    try {
      if (!_armed) {
        broadcast.activate(node);
        broadcast.updateCurrentTarget(_progress().currentTarget);
        await stacker.startFromFile(savePath, config: _configFor(node));
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
          '(method=${node.stackMethod.label}, broadcast port '
          '${node.broadcastPort})',
          source: 'SequenceExecutor',
        );
      } else {
        // 0 means unlimited.
        final cap = node.maxFramesToStack;
        if (cap > 0 && _stackState().stats.stackedFrameCount >= cap) {
          logger.debug(
            'Live-stacking auto-feed: frame cap ($cap) reached; not adding '
            '$savePath to the stack.',
            source: 'SequenceExecutor',
          );
          return;
        }
        broadcast.updateCurrentTarget(_progress().currentTarget);
        await stacker.addFrameFromFile(savePath);
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
