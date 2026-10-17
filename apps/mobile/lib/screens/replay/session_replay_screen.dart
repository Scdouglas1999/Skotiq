// Mobile session replay scrubber.
//
// Renders a single past sequence run as a scrub-able timeline. The
// state lives in `SessionReplayNotifier`; this widget translates the
// notifier's three concrete states into UI:
//   * Loading  → centered spinner
//   * Error    → error card with retry button
//   * Ready    → timeline + snapshot panel + transport controls
//
// The timeline is a horizontally-stretched CustomPaint that draws
// one tick per event (colored by severity) and one diamond per
// captured frame. A draggable playhead overlays the bar; tap-and-
// drag moves it, tapping a tick jumps to that exact offset.
//
// Snapshot data comes from the notifier's broadcast stream — the
// projection (current target / filter / HFR / frame count etc.) is
// computed by scanning the merged marker list up to the playhead.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The replay screen. Built on top of [SessionReplayNotifier] (a
/// [StateNotifierProvider.family] keyed on `(runId, dataSource)`).
class SessionReplayScreen extends ConsumerStatefulWidget {
  final int runId;

  /// Optional override for tests. Production callers leave this null,
  /// in which case we construct a [NetworkSessionReplayDataSource]
  /// from the active backend at build time.
  final SessionReplayDataSource? dataSourceOverride;

  const SessionReplayScreen({
    super.key,
    required this.runId,
    this.dataSourceOverride,
  });

  @override
  ConsumerState<SessionReplayScreen> createState() =>
      _SessionReplayScreenState();
}

class _SessionReplayScreenState extends ConsumerState<SessionReplayScreen> {
  SessionReplayDataSource? _dataSource;
  NetworkBackend? _dataSourceBackend;

  SessionReplayDataSource _resolveDataSource(SkotiqBackend backend) {
    final override = widget.dataSourceOverride;
    if (override != null) return override;
    if (backend is! NetworkBackend) {
      // The picker screen guards against this before opening the replay
      // screen, so reaching here means a backend swap happened mid-navigation.
      // Throw rather than fake a data source: replay on the FFI backend is
      // genuinely not implemented, and an empty timeline would read as a
      // session with no frames.
      throw StateError(
        'Session replay requires NetworkBackend; got ${backend.runtimeType}',
      );
    }
    final existing = _dataSource;
    if (existing != null && identical(_dataSourceBackend, backend)) {
      return existing;
    }
    final ds = NetworkSessionReplayDataSource(backend: backend);
    _dataSource = ds;
    _dataSourceBackend = backend;
    return ds;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final backend = ref.watch(backendProvider);
    late final SessionReplayDataSource dataSource;
    try {
      dataSource = _resolveDataSource(backend);
    } catch (e) {
      return Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.surface,
          elevation: 0,
          title: const Text('Replay'),
        ),
        body: Center(child: Text(e.toString())),
      );
    }
    final key = (runId: widget.runId, dataSource: dataSource);
    final state = ref.watch(sessionReplayNotifierProvider(key));
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        title: const Text('Replay'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: colors.border),
        ),
      ),
      body: switch (state) {
        SessionReplayLoading() => const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
        ),
        SessionReplayError(:final message) => _ReplayErrorView(
          message: message,
          onRetry: () =>
              ref.read(sessionReplayNotifierProvider(key).notifier).reload(),
        ),
        SessionReplayReady() => _ReplayReadyBody(stateKey: key, ready: state),
      },
    );
  }
}

class _ReplayErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ReplayErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.cloudOff, size: 36, color: colors.error),
          const SizedBox(height: 12),
          Text(
            'Replay failed',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          const SizedBox(height: 16),
          SkotiqButton(label: 'Retry', onPressed: onRetry),
        ],
      ),
    );
  }
}

class _ReplayReadyBody extends ConsumerWidget {
  final SessionReplayKey stateKey;
  final SessionReplayReady ready;

  const _ReplayReadyBody({required this.stateKey, required this.ready});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final notifier = ref.read(sessionReplayNotifierProvider(stateKey).notifier);
    return Column(
      children: [
        _RunHeader(ready: ready),
        if (ready.eventsPartial)
          _PartialBanner(reason: ready.eventsPartialReason),
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
        Container(height: 1, color: colors.border),
        Expanded(
          child: StreamBuilder<ReplaySnapshot>(
            stream: notifier.snapshotStream,
            initialData: notifier.latestSnapshot,
            builder: (context, snap) {
              final s = snap.data;
              if (s == null) {
                return const SizedBox.shrink();
              }
              return _SnapshotPanel(snapshot: s, ready: ready);
            },
          ),
        ),
      ],
    );
  }
}

class _RunHeader extends StatelessWidget {
  final SessionReplayReady ready;
  const _RunHeader({required this.ready});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final duration = ready.run.duration;
    final start = ready.run.startedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final startStr =
        '${start.year}-${two(start.month)}-${two(start.day)} '
        '${two(start.hour)}:${two(start.minute)}';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ready.run.sequenceName ?? 'Untitled sequence',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 16,
              color: colors.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 10,
            children: [
              if (ready.run.targetName != null)
                _HeaderChip(
                  icon: LucideIcons.target,
                  label: ready.run.targetName!,
                ),
              _HeaderChip(icon: LucideIcons.clock, label: startStr),
              if (duration != null)
                _HeaderChip(
                  icon: LucideIcons.hourglass,
                  label: DurationFormat.of(
                    duration,
                    style: DurationStyle.hoursMinutes,
                  ),
                ),
              _HeaderChip(
                icon: LucideIcons.image,
                label: '${ready.run.frameCount} frames',
              ),
              _HeaderChip(icon: LucideIcons.circle, label: ready.run.status),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _HeaderChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width - 48,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: colors.textSecondary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _PartialBanner extends StatelessWidget {
  final String? reason;
  const _PartialBanner({required this.reason});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final body = switch (reason) {
      'no_buffered_entries' =>
        'Server has no buffered events for this run. Events from before the last server restart are not stored persistently.',
      'ring_buffer_truncated' =>
        'Event history is partial. The server retains only the most recent 1000 log entries; older events for this run have aged out.',
      'client_page_limit' =>
        'Event history is unusually large and exceeds the phone replay limit. The visible timeline is incomplete.',
      'server_empty_page' =>
        'The server returned an incomplete event page. Retry the replay to request the missing timeline entries again.',
      _ => 'Event timeline is partial.',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: colors.warning.withValues(alpha: 0.12),
      child: Row(
        children: [
          Icon(LucideIcons.alertTriangle, size: 14, color: colors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              body,
              style: TextStyle(fontSize: 11, color: colors.textPrimary),
            ),
          ),
        ],
      ),
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    return Container(
      key: const Key('timeline_bar'),
      color: colors.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 56,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final dur = ready.durationMs.toDouble().clamp(1.0, 1 << 30);
                double offsetToX(int ms) =>
                    width * (ms.clamp(0, ready.durationMs) / dur);

                int xToOffset(double x) =>
                    (x.clamp(0.0, width) / width * dur).round();

                return GestureDetector(
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
                    size: Size(width, 56),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatOffset(0),
                style: TextStyle(fontSize: 10, color: colors.textSecondary),
              ),
              Text(
                _formatOffset(ready.playheadMs),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: colors.primary,
                ),
              ),
              Text(
                _formatOffset(ready.durationMs),
                style: TextStyle(fontSize: 10, color: colors.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  ReplayMarker? _hitMarker(
    double x,
    double width,
    List<ReplayMarker> markers,
    int durationMs,
  ) {
    // 12 px tolerance. With markers at <= 12 px apart we'd prefer the
    // closer one (the tap is on the timeline, the marker is just the
    // visual hint).
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

  String _formatOffset(int ms) {
    final s = ms ~/ 1000;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final ss = s % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '${two(h)}:${two(m)}:${two(ss)}';
    return '${two(m)}:${two(ss)}';
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

    // Passed-region: the segment from 0 → playhead in primary color.
    final playheadX = offsetToX(ready.playheadMs);
    final passedPaint = Paint()
      ..color = colors.primary
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, trackY), Offset(playheadX, trackY), passedPaint);

    // Ticks (events) above the track; diamonds (frames) below.
    for (final m in ready.markers) {
      final x = offsetToX(m.offsetMs);
      switch (m) {
        case ReplayEventMarker event:
          final color = _severityColor(event.severity);
          final paint = Paint()..color = color;
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

    // Playhead — vertical bar with circle on top of track.
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

  Color _severityColor(String severity) {
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

  @override
  bool shouldRepaint(_TimelinePainter old) {
    return old.ready.playheadMs != ready.playheadMs ||
        !identical(old.ready.markers, ready.markers) ||
        old.ready.durationMs != ready.durationMs;
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              ready.isPlaying ? LucideIcons.pause : LucideIcons.play,
              color: colors.primary,
            ),
            onPressed: onTogglePlayback,
            tooltip: ready.isPlaying ? 'Pause' : 'Play',
          ),
          const SizedBox(width: 8),
          for (final speed in const [1.0, 4.0, 16.0, 60.0])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _SpeedChip(
                label: speed >= 60 ? 'fast' : '${speed.toInt()}x',
                active: ready.playbackSpeed == speed,
                onTap: () => onSpeedChanged(speed),
              ),
            ),
        ],
      ),
    );
  }
}

class _SpeedChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _SpeedChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? colors.primary : colors.background,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? colors.primary : colors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: active ? colors.onPrimary : colors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _SnapshotPanel extends StatelessWidget {
  final ReplaySnapshot snapshot;
  final SessionReplayReady ready;

  const _SnapshotPanel({required this.snapshot, required this.ready});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final wallClock = snapshot.playheadWallClock.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final timeStr =
        '${two(wallClock.hour)}:${two(wallClock.minute)}:'
        '${two(wallClock.second)}';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SnapshotCard(
            title: 'Replay snapshot at $timeStr',
            colors: colors,
            child: Column(
              children: [
                _SnapshotRow(
                  label: 'Target',
                  value: snapshot.currentTarget ?? '—',
                  colors: colors,
                ),
                _SnapshotRow(
                  label: 'Current node',
                  value: snapshot.currentNodeName ?? '—',
                  colors: colors,
                ),
                _SnapshotRow(
                  label: 'Filter',
                  value: snapshot.currentFilter ?? '—',
                  colors: colors,
                ),
                _SnapshotRow(
                  label: 'Frames captured',
                  value: '${snapshot.frameCount} / ${ready.run.frameCount}',
                  colors: colors,
                ),
                _SnapshotRow(
                  label: 'Last HFR',
                  value: snapshot.lastHfr != null
                      ? snapshot.lastHfr!.toStringAsFixed(2)
                      : '—',
                  colors: colors,
                ),
                _SnapshotRow(
                  label: 'Guide RMS (total)',
                  value: snapshot.lastGuideRmsTotal != null
                      ? '${snapshot.lastGuideRmsTotal!.toStringAsFixed(2)}"'
                      : '—',
                  colors: colors,
                ),
                _SnapshotRow(
                  label: 'Recovery state',
                  value: snapshot.recoveryState ?? '—',
                  colors: colors,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SnapshotCard(
            title:
                'Events up to playhead '
                '(${snapshot.markersUpToPlayhead.length})',
            colors: colors,
            child: _EventLogList(
              markers: snapshot.markersUpToPlayhead,
              colors: colors,
            ),
          ),
          const SizedBox(height: 16),
          _DataSourceFooter(ready: ready),
        ],
      ),
    );
  }
}

class _SnapshotCard extends StatelessWidget {
  final String title;
  final SkotiqColors colors;
  final Widget child;

  const _SnapshotCard({
    required this.title,
    required this.colors,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          Divider(height: 1, color: colors.border),
          Padding(padding: const EdgeInsets.all(12), child: child),
        ],
      ),
    );
  }
}

class _SnapshotRow extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const _SnapshotRow({
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: colors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventLogList extends StatelessWidget {
  final List<ReplayMarker> markers;
  final SkotiqColors colors;

  const _EventLogList({required this.markers, required this.colors});

  @override
  Widget build(BuildContext context) {
    // We render the most-recent 30 markers in reverse-chronological
    // order (newest at top). The panel is scrollable but bounded so
    // the snapshot card above stays anchored — paginating the entire
    // event log inside this card would force the panel to compete with
    // its own contents for layout space.
    final lastN = markers.length > 30
        ? markers.sublist(markers.length - 30)
        : markers;
    if (lastN.isEmpty) {
      return Text(
        'No events at or before this point in the timeline yet.',
        style: TextStyle(fontSize: 12, color: colors.textSecondary),
      );
    }
    final reversed = lastN.reversed.toList(growable: false);
    return Column(
      children: [
        for (final m in reversed) _MarkerRow(marker: m, colors: colors),
      ],
    );
  }
}

class _MarkerRow extends StatelessWidget {
  final ReplayMarker marker;
  final SkotiqColors colors;

  const _MarkerRow({required this.marker, required this.colors});

  @override
  Widget build(BuildContext context) {
    final m = marker;
    final time = marker.wallClock.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final timeStr = '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    final (label, color, source) = switch (m) {
      ReplayEventMarker e => (
        e.message,
        _severityColor(e.severity, colors),
        e.source ?? e.severity,
      ),
      ReplayFrameMarker f => (
        'Frame #${f.frameId}'
            '${f.filter != null ? ' · ${f.filter}' : ''}'
            '${f.hfr != null ? ' · HFR ${f.hfr!.toStringAsFixed(2)}' : ''}',
        f.isAccepted ? colors.success : colors.error,
        'imaging',
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4),
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: colors.textPrimary),
                ),
                Text(
                  '$timeStr · $source',
                  style: TextStyle(fontSize: 10, color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
}

class _DataSourceFooter extends StatelessWidget {
  final SessionReplayReady ready;
  const _DataSourceFooter({required this.ready});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final events = ready.markers.whereType<ReplayEventMarker>().length;
    final frames = ready.markers.whereType<ReplayFrameMarker>().length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(LucideIcons.database, size: 12, color: colors.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$events events · $frames frames · '
              'Weather history not recorded for this session.',
              style: TextStyle(fontSize: 10, color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
