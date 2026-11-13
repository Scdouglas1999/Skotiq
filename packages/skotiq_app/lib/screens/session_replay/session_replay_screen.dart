import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../widgets/run_status/run_status_presentation.dart';
import 'session_picker_screen.dart';
import '../../router/app_routes.dart';

/// One past run as a timeline to scrub: events above the track, frames below
/// it, and what the rig was doing at the playhead.
///
/// The state lives in [SessionReplayNotifier], keyed on the run and the data
/// source; production reads the linked host's imaging records.
class SessionReplayScreen extends ConsumerStatefulWidget {
  final int runId;

  /// Replaces the linked host's records in tests.
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
  RemoteHost? _dataSourceHost;

  /// The data source for [host], kept while the host stays the same so the
  /// notifier family keeps its state across rebuilds.
  SessionReplayDataSource? _resolveDataSource(RemoteHost? host) {
    final override = widget.dataSourceOverride;
    if (override != null) return override;
    if (host == null) return null;
    final existing = _dataSource;
    if (existing != null && identical(_dataSourceHost, host)) return existing;
    _dataSourceHost = host;
    return _dataSource = NetworkSessionReplayDataSource(
      backend: host.imagingRecords,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final dataSource = _resolveDataSource(
      ref.watch(backendProvider.select((b) => b.remoteHost)),
    );
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PageHeader(
              icon: SkotiqIcons.history,
              title: 'Replay',
              actions: [_BackToRunList()],
            ),
            Expanded(
              child: dataSource == null
                  ? const SessionReplayNeedsRig()
                  : _ReplayBody(
                      stateKey: (runId: widget.runId, dataSource: dataSource),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackToRunList extends StatelessWidget {
  const _BackToRunList();

  @override
  Widget build(BuildContext context) {
    return SkotiqIconButton(
      icon: SkotiqIcons.arrowLeft,
      tooltip: 'Back to past runs',
      onPressed: () {
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop();
          return;
        }
        // A deep link leaves nothing beneath this screen.
        context.go(AppRoute.sessionReplay.path);
      },
    );
  }
}

class _ReplayBody extends ConsumerWidget {
  final SessionReplayKey stateKey;

  const _ReplayBody({required this.stateKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionReplayNotifierProvider(stateKey));
    return switch (state) {
      SessionReplayLoading() => const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
        ),
      SessionReplayError(:final cause) => EmptyState(
          icon: SkotiqIcons.disconnected,
          title: 'Replay failed',
          body: userFacingError(cause),
          action: SkotiqButton(
            label: 'Try again',
            icon: SkotiqIcons.refresh,
            onPressed: () => ref
                .read(sessionReplayNotifierProvider(stateKey).notifier)
                .reload(),
          ),
        ),
      SessionReplayReady() =>
        _ReplayReadyBody(stateKey: stateKey, ready: state),
    };
  }
}

class _ReplayReadyBody extends ConsumerWidget {
  final SessionReplayKey stateKey;
  final SessionReplayReady ready;

  const _ReplayReadyBody({required this.stateKey, required this.ready});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final notifier = ref.read(sessionReplayNotifierProvider(stateKey).notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
              if (s == null) return const SizedBox.shrink();
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
    final colors = SkotiqColors.of(context);
    final run = ready.run;
    final duration = run.duration;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceMd,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            run.sequenceName ?? 'Untitled sequence',
            style: SkotiqTypography.bodyStrong.copyWith(
              color: colors.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Wrap(
            spacing: SkotiqTokens.spaceMd,
            runSpacing: SkotiqTokens.spaceXs,
            children: [
              if (run.targetName != null)
                _HeaderFact(icon: SkotiqIcons.target, label: run.targetName!),
              _HeaderFact(
                icon: SkotiqIcons.clock,
                label: ClockFormat.dateHm(run.startedAt.toLocal()),
              ),
              if (duration != null)
                _HeaderFact(
                  icon: SkotiqIcons.timer,
                  label: DurationFormat.of(
                    duration,
                    style: DurationStyle.short,
                  ),
                ),
              _HeaderFact(
                icon: SkotiqIcons.image,
                label: run.frameCount == 1
                    ? '1 frame'
                    : '${run.frameCount} frames',
              ),
              _HeaderFact(
                icon: SkotiqIcons.circle,
                label: runStatusTokenLabel(run.status),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderFact extends StatelessWidget {
  final IconData icon;
  final String label;
  const _HeaderFact({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width - 2 * SkotiqTokens.space2xl,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: SkotiqTokens.iconChipGlyph, color: colors.textSecondary),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Flexible(
            child: Text(
              label,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
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
      color: colors.surface,
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceSm,
      ),
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
      color: colors.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: Row(
        children: [
          SkotiqIconButton(
            icon: ready.isPlaying ? SkotiqIcons.pause : SkotiqIcons.play,
            tooltip: ready.isPlaying ? 'Pause' : 'Play',
            color: colors.primary,
            onPressed: onTogglePlayback,
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: SegmentedControl(
              segments: [for (final s in _speeds) _speedLabel(s)],
              selectedIndex: selected < 0 ? 0 : selected,
              onSelected: (i) => onSpeedChanged(_speeds[i]),
              semanticLabel: 'Playback speed',
            ),
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

  @override
  Widget build(BuildContext context) {
    final hfr = snapshot.lastHfr;
    final rms = snapshot.lastGuideRmsTotal;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkotiqPanel(
            head: PanelHead(
              label:
                  'At ${ClockFormat.hms(snapshot.playheadWallClock.toLocal())}',
              icon: SkotiqIcons.clock,
            ),
            child: KeyValueList(
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
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          SkotiqPanel(
            head: PanelHead(
              label: 'Events so far (${snapshot.markersUpToPlayhead.length})',
              icon: SkotiqIcons.list,
            ),
            child: _EventLogList(markers: snapshot.markersUpToPlayhead),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _DataSourceFooter(ready: ready),
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
  static const int _shown = 30;

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

class _DataSourceFooter extends StatelessWidget {
  final SessionReplayReady ready;
  const _DataSourceFooter({required this.ready});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final events = ready.markers.whereType<ReplayEventMarker>().length;
    final frames = ready.markers.whereType<ReplayFrameMarker>().length;
    return Row(
      children: [
        Icon(
          SkotiqIcons.database,
          size: SkotiqTokens.iconChipGlyph,
          color: colors.textMuted,
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Text(
            '$events events · $frames frames. Weather is not recorded for '
            'replay.',
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
  }
}
