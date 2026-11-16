import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../analytics_providers.dart';

/// A run's replay data read from the records the imaging host keeps: the run
/// row, the frames of its session and its logged decisions. Unlike the host's
/// in-memory event log these survive a restart, and they reach a linked
/// client through the same host roles as the rest of History.
class RunRecordsReplaySource implements SessionReplayDataSource {
  RunRecordsReplaySource({
    required this.run,
    required this.targetName,
    required this.loadFrames,
    required this.loadDecisions,
  });

  final SequenceRun run;
  final String? targetName;
  final Future<List<DbCapturedImage>> Function() loadFrames;
  final Future<List<ReplayDecision>> Function() loadDecisions;

  /// Second-resolution timestamps can put a frame or decision a moment
  /// before the run row's start; the timeline starts at the run.
  bool _inRun(DateTime when) => !when.isBefore(run.startedAt);

  @override
  Future<RemoteSequenceRunDetail> fetchRun(int runId) async {
    final frames = await loadFrames();
    return RemoteSequenceRunDetail(
      id: run.id,
      sequenceId: run.sequenceId,
      sequenceName: run.sequenceName,
      startedAt: run.startedAt,
      endedAt: run.endedAt,
      status: run.status,
      statsJson: run.statsJson,
      frameCount: frames.where((f) => _inRun(f.capturedAt)).length,
      targetName: targetName,
    );
  }

  @override
  Future<RemoteReplayEventsPage> fetchEvents(int runId) async {
    final events = [
      for (final decision in await loadDecisions())
        if (_inRun(decision.timestamp))
          RemoteReplayEvent(
            timestamp: decision.timestamp,
            timestampMs: decision.timestamp.millisecondsSinceEpoch,
            severity: switch (decision.category) {
              DecisionCategory.frameRejected ||
              DecisionCategory.recoveryEntered =>
                'warning',
              _ => 'info',
            },
            source: decision.category.displayLabel,
            message: decision.summary,
            fields: decision.details,
          ),
    ]..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    return RemoteReplayEventsPage(
      items: events,
      total: events.length,
      isPartial: false,
      source: 'decision_log',
    );
  }

  @override
  Future<List<RemoteReplayFrame>> fetchFrames(int runId) async => [
        for (final frame in await loadFrames())
          if (_inRun(frame.capturedAt)) replayFrameOf(frame),
      ];
}

/// The timeline of one run: scrub or play through it and read what the rig
/// was doing at that moment, with the frames and decisions up to it.
class RunTimeline extends ConsumerStatefulWidget {
  const RunTimeline({
    super.key,
    required this.run,
    required this.sessionId,
    required this.targetName,
    this.dataSourceOverride,
  });

  final SequenceRun run;

  /// The session whose frames the run produced, or null when none is paired.
  final int? sessionId;
  final String? targetName;

  /// Canned data for tests.
  final SessionReplayDataSource? dataSourceOverride;

  @override
  ConsumerState<RunTimeline> createState() => _RunTimelineState();
}

class _RunTimelineState extends ConsumerState<RunTimeline> {
  // The provider family keys on the data source's identity, so one instance
  // lives as long as the run it reads.
  late SessionReplayDataSource _dataSource = _source();

  SessionReplayDataSource _source() =>
      widget.dataSourceOverride ??
      RunRecordsReplaySource(
        run: widget.run,
        targetName: widget.targetName,
        loadFrames: () async {
          final sessionId = widget.sessionId;
          return sessionId == null
              ? const <DbCapturedImage>[]
              : ref.read(dbSessionImagesProvider(sessionId).future);
        },
        loadDecisions: () =>
            ref.read(decisionsForRunProvider(widget.run.id).future),
      );

  @override
  void didUpdateWidget(RunTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.run.id != widget.run.id ||
        oldWidget.sessionId != widget.sessionId ||
        !identical(oldWidget.dataSourceOverride, widget.dataSourceOverride)) {
      _dataSource = _source();
    }
  }

  @override
  Widget build(BuildContext context) {
    final stateKey = (runId: widget.run.id, dataSource: _dataSource);
    final state = ref.watch(sessionReplayNotifierProvider(stateKey));
    return SkotiqPanel(
      head: const PanelHead(label: 'Timeline', icon: SkotiqIcons.history),
      child: switch (state) {
        SessionReplayLoading() => const SizedBox(
            height: _TimelineBar._height,
            child: Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 24),
            ),
          ),
        SessionReplayError(:final cause) => EmptyState.error(
            title: 'The timeline did not load',
            body: userFacingError(cause),
            onRetry: () => ref
                .read(sessionReplayNotifierProvider(stateKey).notifier)
                .reload(),
          ),
        SessionReplayReady() =>
          _ReplayReadyBody(stateKey: stateKey, ready: state),
      },
    );
  }
}

class _ReplayReadyBody extends ConsumerWidget {
  final SessionReplayKey stateKey;
  final SessionReplayReady ready;

  const _ReplayReadyBody({required this.stateKey, required this.ready});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(sessionReplayNotifierProvider(stateKey).notifier);
    if (ready.markers.isEmpty) {
      return const EmptyState.compact(
        icon: SkotiqIcons.history,
        title: 'Nothing was recorded for this run',
        body: 'It took no frames and logged no decisions.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (ready.eventsPartial) ...[
          _PartialBanner(reason: ready.eventsPartialReason),
          const SizedBox(height: SkotiqTokens.spaceMd),
        ],
        _TimelineBar(
          ready: ready,
          onSeek: notifier.seekTo,
          onMarkerTap: notifier.seekToMarker,
        ),
        _TransportControls(
          ready: ready,
          onTogglePlayback: notifier.togglePlayback,
          onSpeedChanged: notifier.setPlaybackSpeed,
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        StreamBuilder<ReplaySnapshot>(
          stream: notifier.snapshotStream,
          initialData: notifier.latestSnapshot,
          builder: (context, snap) {
            final s = snap.data;
            if (s == null) return const SizedBox.shrink();
            return _SnapshotPanel(snapshot: s, ready: ready);
          },
        ),
      ],
    );
  }
}

class _PartialBanner extends StatelessWidget {
  final String? reason;
  const _PartialBanner({required this.reason});

  @override
  Widget build(BuildContext context) {
    final body = switch (reason) {
      'no_buffered_entries' =>
        'The host has no events for this run. It keeps events only until it '
            'restarts, so runs from before its last restart replay with frames '
            'only.',
      'ring_buffer_truncated' =>
        'Only part of this run\'s events are left. The host keeps its most '
            'recent 1000 log entries, and older events have aged out.',
      'client_page_limit' =>
        'This run has more events than the replay can load, so the timeline '
            'is incomplete.',
      'server_empty_page' =>
        'The host sent an incomplete event page. Go back and open the run '
            'again to ask for the missing events.',
      _ => 'Only part of this run\'s events could be loaded.',
    };
    return SkotiqBanner(
      title: 'Event history is incomplete',
      message: body,
      tone: BannerTone.warning,
    );
  }
}

class _TimelineBar extends StatelessWidget {
  final SessionReplayReady ready;
  final ValueChanged<int> onSeek;
  final void Function(ReplayMarker) onMarkerTap;

  const _TimelineBar({
    required this.ready,
    required this.onSeek,
    required this.onMarkerTap,
  });

  static const double _height = 56;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final offsetStyle = SkotiqTypography.monoXs.copyWith(
      color: colors.textSecondary,
    );
    return Container(
      key: const Key('timeline_bar'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final dur = ready.durationMs.toDouble().clamp(1.0, 1 << 30);
                double offsetToX(int ms) =>
                    width * (ms.clamp(0, ready.durationMs) / dur);

                int xToOffset(double x) =>
                    (x.clamp(0.0, width) / width * dur).round();

                return Semantics(
                  label: 'Replay timeline',
                  value: _formatOffset(ready.playheadMs),
                  child: GestureDetector(
                    onTapDown: (details) {
                      final marker = _hitMarker(
                        details.localPosition.dx,
                        width,
                        ready.markers,
                        ready.durationMs,
                      );
                      if (marker != null) {
                        onMarkerTap(marker);
                      } else {
                        onSeek(xToOffset(details.localPosition.dx));
                      }
                    },
                    onHorizontalDragUpdate: (details) {
                      onSeek(xToOffset(details.localPosition.dx));
                    },
                    child: CustomPaint(
                      painter: _TimelinePainter(
                        ready: ready,
                        colors: colors,
                        offsetToX: offsetToX,
                      ),
                      size: Size(width, _height),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatOffset(0), style: offsetStyle),
              Text(
                _formatOffset(ready.playheadMs),
                style: offsetStyle.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(_formatOffset(ready.durationMs), style: offsetStyle),
            ],
          ),
        ],
      ),
    );
  }

  /// The marker within a finger's reach of [x], nearest first.
  ReplayMarker? _hitMarker(
    double x,
    double width,
    List<ReplayMarker> markers,
    int durationMs,
  ) {
    const tolerance = 12.0;
    final dur = durationMs.toDouble().clamp(1.0, 1 << 30);
    ReplayMarker? best;
    double bestDist = tolerance;
    for (final m in markers) {
      final mx = width * (m.offsetMs.clamp(0, durationMs) / dur);
      final dist = (mx - x).abs();
      if (dist <= bestDist) {
        best = m;
        bestDist = dist;
      }
    }
    return best;
  }

  /// Elapsed time since the run started, as a scrubber reads it.
  static String _formatOffset(int ms) {
    final s = ms ~/ 1000;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final ss = s % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '${two(h)}:${two(m)}:${two(ss)}';
    return '${two(m)}:${two(ss)}';
  }
}

Color _severityColor(String severity, SkotiqColors colors) {
  switch (severity.toLowerCase()) {
    case 'critical':
    case 'error':
      return colors.error;
    case 'warning':
      return colors.warning;
    case 'debug':
      return colors.textSecondary;
    default:
      return colors.info;
  }
}

class _TimelinePainter extends CustomPainter {
  final SessionReplayReady ready;
  final SkotiqColors colors;
  final double Function(int) offsetToX;

  _TimelinePainter({
    required this.ready,
    required this.colors,
    required this.offsetToX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final trackY = size.height * 0.5;
    final trackPaint = Paint()
      ..color = colors.border
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, trackY), Offset(size.width, trackY), trackPaint);

    final playheadX = offsetToX(ready.playheadMs);
    final passedPaint = Paint()
      ..color = colors.primary
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, trackY), Offset(playheadX, trackY), passedPaint);

    // Events tick above the track; frames are diamonds below it.
    for (final m in ready.markers) {
      final x = offsetToX(m.offsetMs);
      switch (m) {
        case ReplayEventMarker event:
          final paint = Paint()..color = _severityColor(event.severity, colors);
          canvas.drawRect(Rect.fromLTWH(x - 1, trackY - 14, 2, 12), paint);
        case ReplayFrameMarker frame:
          final paint = Paint()
            ..color = frame.isAccepted ? colors.success : colors.error;
          final path = Path()
            ..moveTo(x, trackY + 4)
            ..lineTo(x + 4, trackY + 8)
            ..lineTo(x, trackY + 12)
            ..lineTo(x - 4, trackY + 8)
            ..close();
          canvas.drawPath(path, paint);
      }
    }

    final playheadPaint = Paint()
      ..color = colors.primary
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(playheadX, 0),
      Offset(playheadX, size.height),
      playheadPaint,
    );
    canvas.drawCircle(
      Offset(playheadX, trackY),
      5,
      Paint()..color = colors.primary,
    );
  }

  @override
  bool shouldRepaint(_TimelinePainter old) {
    return old.ready.playheadMs != ready.playheadMs ||
        !identical(old.ready.markers, ready.markers) ||
        old.ready.durationMs != ready.durationMs ||
        !identical(old.colors, colors);
  }
}

class _TransportControls extends StatelessWidget {
  final SessionReplayReady ready;
  final VoidCallback onTogglePlayback;
  final ValueChanged<double> onSpeedChanged;

  const _TransportControls({
    required this.ready,
    required this.onTogglePlayback,
    required this.onSpeedChanged,
  });

  static const List<double> _speeds = [1.0, 4.0, 16.0, 60.0];

  static String _speedLabel(double speed) => '${speed.toInt()}×';

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final selected = _speeds.indexOf(ready.playbackSpeed);
    return Container(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
      child: Row(
        children: [
          SkotiqIconButton(
            icon: ready.isPlaying ? SkotiqIcons.pause : SkotiqIcons.play,
            tooltip: ready.isPlaying ? 'Pause' : 'Play',
            color: colors.primary,
            onPressed: onTogglePlayback,
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          SegmentedControl(
            segments: [for (final s in _speeds) _speedLabel(s)],
            selectedIndex: selected < 0 ? 0 : selected,
            onSelected: (i) => onSpeedChanged(_speeds[i]),
            semanticLabel: 'Playback speed',
          ),
        ],
      ),
    );
  }
}

class _SnapshotPanel extends StatelessWidget {
  final ReplaySnapshot snapshot;
  final SessionReplayReady ready;

  const _SnapshotPanel({required this.snapshot, required this.ready});

  /// Above this width the state and the events sit side by side.
  static const double _sideBySideAbove = 640;
  static const double _stateWidth = 280;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final hfr = snapshot.lastHfr;
    final rms = snapshot.lastGuideRmsTotal;
    final eyebrow = SkotiqTypography.eyebrow.copyWith(color: colors.textMuted);
    final stateAtPlayhead = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'AT ${ClockFormat.hms(snapshot.playheadWallClock.toLocal())}',
          style: eyebrow,
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        KeyValueList(
          rows: [
            ('Target', snapshot.currentTarget ?? kReadoutUnknown),
            ('Step', snapshot.currentNodeName ?? kReadoutUnknown),
            ('Filter', snapshot.currentFilter ?? kReadoutUnknown),
            (
              'Frames captured',
              '${snapshot.frameCount} of ${ready.run.frameCount}',
            ),
            (
              'Last HFR',
              hfr != null ? hfr.toStringAsFixed(2) : kReadoutUnknown
            ),
            (
              'Guide RMS',
              rms != null ? '${rms.toStringAsFixed(2)}"' : kReadoutUnknown,
            ),
            ('Recovery', snapshot.recoveryState ?? kReadoutUnknown),
          ],
        ),
      ],
    );
    final events = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'UP TO HERE · ${snapshot.markersUpToPlayhead.length} OF '
          '${ready.markers.length}',
          style: eyebrow,
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        _EventLogList(markers: snapshot.markersUpToPlayhead),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= _sideBySideAbove
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: _stateWidth, child: stateAtPlayhead),
                    const SizedBox(width: SkotiqTokens.space2xl),
                    Expanded(child: events),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    stateAtPlayhead,
                    const SizedBox(height: SkotiqTokens.spaceLg),
                    events,
                  ],
                ),
    );
  }
}

class _EventLogList extends StatelessWidget {
  final List<ReplayMarker> markers;

  const _EventLogList({required this.markers});

  /// The newest entries, newest first; the panel stays short enough that the
  /// snapshot above it remains in view.
  static const int _shown = 8;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    if (markers.isEmpty) {
      return Text(
        'Nothing has happened yet at this point in the run.',
        style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
      );
    }
    final start = markers.length > _shown ? markers.length - _shown : 0;
    return Column(
      children: [
        for (var i = markers.length - 1; i >= start; i--)
          _MarkerRow(marker: markers[i]),
      ],
    );
  }
}

class _MarkerRow extends StatelessWidget {
  final ReplayMarker marker;

  const _MarkerRow({required this.marker});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final (label, color, source) = switch (marker) {
      ReplayEventMarker e => (
          e.message,
          _severityColor(e.severity, colors),
          e.source ?? e.severity,
        ),
      ReplayFrameMarker f => (
          [
            'Frame ${f.frameId}',
            if (f.filter != null) f.filter!,
            if (f.hfr != null) 'HFR ${f.hfr!.toStringAsFixed(2)}',
            if (!f.isAccepted) 'rejected',
          ].join(' · '),
          f.isAccepted ? colors.success : colors.error,
          'Imaging',
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: SkotiqTokens.spaceXs),
            child: StatusDot(color: color),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  '${ClockFormat.hms(marker.wallClock.toLocal())} · $source',
                  style: SkotiqTypography.captionSm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
