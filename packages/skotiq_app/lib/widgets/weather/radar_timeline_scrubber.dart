import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Index of the frame a radar timeline should sit on when nobody has scrubbed:
/// the newest OBSERVATION, i.e. the live edge of the loop.
///
/// Chosen by TIMESTAMP, never by list position. The providers do not agree on
/// an order: RainViewer sorts ascending, Open-Meteo / MET Norway walk an
/// ascending hourly series, but NOAA NEXRAD builds its frames from timestamps
/// sorted reverse-chronologically (noaa_radar_provider.dart:348), so its
/// newest frame is `frames.first` and its two-hour-old frame is `frames.last`.
/// Nothing between the provider and the widget re-sorts. Picking "the last
/// non-forecast entry" would therefore open a NOAA user on the OLDEST frame —
/// exactly the staleness this helper exists to prevent.
///
/// Forecast frames are skipped: RainViewer appends nowcast tiles and
/// Open-Meteo / MET Norway append hours past `now`, and opening on one would
/// show predicted cloud as though it had been measured.
///
/// When every frame is a forecast there is no observation to show, so the one
/// nearest to now is the least-wrong choice. An empty list yields 0 (nothing
/// to point at).
int latestObservedRadarFrameIndex(List<RadarFrame> frames) {
  if (frames.isEmpty) return 0;

  int? newestObserved;
  for (var i = 0; i < frames.length; i++) {
    if (frames[i].isForecast) continue;
    if (newestObserved == null ||
        frames[i].timestamp.isAfter(frames[newestObserved].timestamp)) {
      newestObserved = i;
    }
  }
  if (newestObserved != null) return newestObserved;

  final now = DateTime.now();
  var nearest = 0;
  var nearestDistance = frames[0].timestamp.difference(now).abs();
  for (var i = 1; i < frames.length; i++) {
    final distance = frames[i].timestamp.difference(now).abs();
    if (distance < nearestDistance) {
      nearest = i;
      nearestDistance = distance;
    }
  }
  return nearest;
}

/// Timeline scrubber for radar frame animation
/// Shows past frames, current time, and forecast frames
class RadarTimelineScrubber extends ConsumerStatefulWidget {
  /// All available radar frames
  final List<RadarFrame> frames;

  /// Currently selected frame index
  final int currentIndex;

  /// Callback when frame selection changes
  final ValueChanged<int> onFrameChanged;

  /// Whether animation is playing
  final bool isPlaying;

  /// Callback to toggle play/pause
  final VoidCallback onPlayPauseToggle;

  /// Playback speed multiplier (1.0 = normal)
  final double playbackSpeed;

  /// Callback when playback speed changes
  final ValueChanged<double>? onSpeedChanged;

  /// Put the readouts on their own row beneath the transport instead of
  /// beside it. Set when the control bar is too narrow for one row.
  final bool stacked;

  const RadarTimelineScrubber({
    super.key,
    required this.frames,
    required this.currentIndex,
    required this.onFrameChanged,
    required this.isPlaying,
    required this.onPlayPauseToggle,
    this.playbackSpeed = 1.0,
    this.onSpeedChanged,
    this.stacked = false,
  });

  @override
  ConsumerState<RadarTimelineScrubber> createState() =>
      _RadarTimelineScrubberState();
}

class _RadarTimelineScrubberState extends ConsumerState<RadarTimelineScrubber>
    with WidgetsBindingObserver {
  Timer? _animationTimer;
  bool _isDragging = false;
  bool _isAppPaused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateAnimationTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isAppPaused = false;
      _updateAnimationTimer();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _isAppPaused = true;
      if (_animationTimer != null && _animationTimer!.isActive) {
        _animationTimer?.cancel();
        _animationTimer = null;
      }
    }
  }

  @override
  void didUpdateWidget(RadarTimelineScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.playbackSpeed != widget.playbackSpeed ||
        !identical(oldWidget.frames, widget.frames)) {
      _updateAnimationTimer();
    }

    if (widget.frames.isNotEmpty &&
        (widget.currentIndex < 0 ||
            widget.currentIndex >= widget.frames.length)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.frames.isEmpty) return;
        if (widget.currentIndex < 0 ||
            widget.currentIndex >= widget.frames.length) {
          widget.onFrameChanged(_safeCurrentIndex);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animationTimer?.cancel();
    super.dispose();
  }

  /// Updates the animation timer based on play state and speed
  void _updateAnimationTimer() {
    _animationTimer?.cancel();
    _animationTimer = null;

    // Only animate when there are at least two frames to cycle through. A
    // single frame has no loop, so a timer would just re-select index 0.
    if (widget.isPlaying &&
        !_isDragging &&
        !_isAppPaused &&
        widget.frames.length > 1 &&
        widget.playbackSpeed.isFinite &&
        widget.playbackSpeed > 0) {
      // Base interval: 500ms per frame (2 FPS)
      const baseInterval = Duration(milliseconds: 500);
      final adjustedInterval = Duration(
        milliseconds:
            (baseInterval.inMilliseconds / widget.playbackSpeed).round(),
      );

      _animationTimer = Timer.periodic(adjustedInterval, (_) {
        if (!_isDragging) {
          _advanceFrame();
        }
      });
    }
  }

  /// Advances to the next frame, looping back to start if at end
  void _advanceFrame() {
    if (widget.frames.isEmpty) return;

    final nextIndex = (_safeCurrentIndex + 1) % widget.frames.length;
    widget.onFrameChanged(nextIndex);
  }

  /// Steps backward one frame
  void _stepBackward() {
    if (widget.frames.isEmpty) return;

    final currentIndex = _safeCurrentIndex;
    final prevIndex =
        currentIndex > 0 ? currentIndex - 1 : widget.frames.length - 1;
    widget.onFrameChanged(prevIndex);
  }

  /// Steps forward one frame
  void _stepForward() {
    if (widget.frames.isEmpty) return;

    _advanceFrame();
  }

  int get _safeCurrentIndex {
    if (widget.frames.isEmpty) return 0;
    return widget.currentIndex.clamp(0, widget.frames.length - 1);
  }

  /// Finds the index of the frame closest to current time
  int? _findNowIndex() {
    if (widget.frames.isEmpty) return null;

    final now = DateTime.now();
    int? closestIndex;
    Duration? smallestDiff;

    for (int i = 0; i < widget.frames.length; i++) {
      final diff = widget.frames[i].timestamp.difference(now).abs();
      if (smallestDiff == null || diff < smallestDiff) {
        smallestDiff = diff;
        closestIndex = i;
      }
    }

    // Only return if the closest frame is within 30 minutes of now
    if (smallestDiff != null && smallestDiff.inMinutes <= 30) {
      return closestIndex;
    }

    return null;
  }

  /// Formats timestamp for display
  String _formatTimestamp(DateTime time) {
    // Frames carry absolute instants whose `DateTime` zone varies by provider
    // (RainViewer/NOAA build local-zoned instants from a Unix epoch, OpenMeteo
    // builds UTC instants). Normalize to local before formatting so the label
    // reads in the operator's wall-clock regardless of the source zone.
    final local = time.toLocal();
    final now = DateTime.now();
    final isToday = local.day == now.day &&
        local.month == now.month &&
        local.year == now.year;

    if (isToday) {
      return DateFormat('HH:mm').format(local);
    } else {
      return DateFormat('MMM d HH:mm').format(local);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    if (widget.frames.isEmpty) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.cloudOff,
            size: SkotiqTokens.iconSm,
            color: colors.textMuted,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            'No radar frames',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textMuted,
            ),
          ),
        ],
      );
    }

    // A single frame can't be animated or scrubbed: there is nothing to seek
    // through and nothing for the play loop to advance to. Some sources (e.g.
    // the GOES satellite composite) only expose the latest image, so rather
    // than show dead transport controls we present a clean static readout of
    // the one frame's timestamp. Multi-frame sources (NOAA NEXRAD, RainViewer)
    // get the full animated timeline below.
    if (widget.frames.length == 1) {
      return _buildSingleFrame(colors, widget.frames.first);
    }

    final currentIndex = _safeCurrentIndex;
    final currentFrame = widget.frames[currentIndex];
    final nowIndex = _findNowIndex();

    final transport = <Widget>[
      SkotiqIconButton(
        icon: widget.isPlaying ? SkotiqIcons.pause : SkotiqIcons.play,
        tooltip: widget.isPlaying ? 'Pause' : 'Play',
        size: IconButtonSize.sm,
        onPressed: widget.onPlayPauseToggle,
      ),
      SkotiqIconButton(
        icon: LucideIcons.skipBack,
        tooltip: 'Previous frame',
        size: IconButtonSize.sm,
        onPressed: _stepBackward,
      ),
      SkotiqIconButton(
        icon: LucideIcons.skipForward,
        tooltip: 'Next frame',
        size: IconButtonSize.sm,
        onPressed: _stepForward,
      ),
    ];

    final readouts = <Widget>[
      _FrameTime(
        frame: currentFrame,
        label: _formatTimestamp(currentFrame.timestamp),
      ),
      const SizedBox(width: SkotiqTokens.spaceLg),
      _FrameCounter(index: currentIndex, total: widget.frames.length),
      if (widget.onSpeedChanged != null) ...[
        const SizedBox(width: SkotiqTokens.spaceLg),
        _SpeedSelector(
          speed: widget.playbackSpeed,
          onChanged: widget.onSpeedChanged!,
        ),
      ],
    ];

    final track = _ScrubTrack(
      frames: widget.frames,
      currentIndex: currentIndex,
      nowIndex: nowIndex,
      colors: colors,
      onDragStart: () => setState(() => _isDragging = true),
      onDragEnd: () {
        setState(() => _isDragging = false);
        _updateAnimationTimer();
      },
      onFrameChanged: widget.onFrameChanged,
    );

    if (widget.stacked) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ...transport,
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(child: track),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Row(children: readouts),
        ],
      );
    }

    return Row(
      children: [
        ...transport,
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(child: track),
        const SizedBox(width: SkotiqTokens.spaceMd),
        ...readouts,
      ],
    );
  }

  /// Static readout for a single-frame source (no animation possible).
  ///
  /// Shows the frame's capture time and a "latest image" note instead of dead
  /// play/scrub controls, which would do nothing with only one frame.
  Widget _buildSingleFrame(SkotiqColors colors, RadarFrame frame) {
    return Row(
      children: [
        Icon(
          frame.isForecast ? SkotiqIcons.clock : LucideIcons.satellite,
          size: SkotiqTokens.iconSm,
          color: frame.isForecast ? colors.warning : colors.success,
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Text(
            frame.isForecast
                ? 'Forecast snapshot — this source gives one frame, so there '
                    'is no loop to play.'
                : 'Latest image — this source gives one frame, so there is no '
                    'loop to play.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        _FrameTime(frame: frame, label: _formatTimestamp(frame.timestamp)),
      ],
    );
  }
}

/// The frame's capture time. A forecast frame says so in `warning`, because a
/// predicted sky drawn as a measured one is the whole reason this screen
/// exists.
class _FrameTime extends StatelessWidget {
  final RadarFrame frame;
  final String label;

  const _FrameTime({required this.frame, required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (frame.isForecast) ...[
          Icon(
            SkotiqIcons.clock,
            size: SkotiqTokens.iconXs,
            color: colors.warning,
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
        ],
        Readout(
          value: label,
          label: frame.isForecast ? 'Forecast' : 'Frame time',
          size: ReadoutSize.sm,
          valueColor: frame.isForecast ? colors.warning : null,
        ),
      ],
    );
  }
}

/// Which frame of the loop is on screen.
///
/// The sentence form is what the weather tour and the regression tests read,
/// so it stays a sentence: "Frame 13 of 13".
class _FrameCounter extends StatelessWidget {
  final int index;
  final int total;

  const _FrameCounter({required this.index, required this.total});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Text(
      'Frame ${index + 1} of $total',
      style: SkotiqTypography.monoCaption.copyWith(color: colors.textMuted),
    );
  }
}

/// The scrub track: frame ticks, the now marker, the played span and a thumb.
class _ScrubTrack extends StatelessWidget {
  final List<RadarFrame> frames;
  final int currentIndex;
  final int? nowIndex;
  final SkotiqColors colors;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final ValueChanged<int> onFrameChanged;

  const _ScrubTrack({
    required this.frames,
    required this.currentIndex,
    required this.nowIndex,
    required this.colors,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onFrameChanged,
  });

  /// Canvas height: the track, its ticks and the NOW label above them.
  ///
  /// 40 is what the scrub-position regression test measures the track by (it
  /// finds the CustomPaint by `size.height == 40`), and the painter's tick and
  /// thumb geometry is laid out around it.
  static const double _height = 40;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Scrub against the TRACK's own width. Measuring off the whole control
        // row needs a hardcoded correction for the transport buttons, which is
        // only ever an estimate — the speed selector is optional and its label
        // width varies — so the frame landed on would not match the thumb
        // dragged.
        final trackWidth = constraints.maxWidth;
        // A bare GestureDetector publishes no role and no name, so assistive
        // tech read the scrub track as inert decoration. It is the screen's
        // main control; give it a name and a value.
        return Semantics(
          slider: true,
          label: 'Radar frame',
          value: 'Frame ${currentIndex + 1} of ${frames.length}',
          child: GestureDetector(
            onHorizontalDragStart: (_) => onDragStart(),
            onHorizontalDragUpdate: (details) {
              if (frames.isEmpty || trackWidth <= 0) return;
              final fraction =
                  (details.localPosition.dx / trackWidth).clamp(0.0, 1.0);
              final newIndex = (fraction * frames.length)
                  .floor()
                  .clamp(0, frames.length - 1);
              if (newIndex != currentIndex) onFrameChanged(newIndex);
            },
            onHorizontalDragEnd: (_) => onDragEnd(),
            child: CustomPaint(
              size: const Size(double.infinity, _height),
              painter: _TimelineTrackPainter(
                frames: frames,
                currentIndex: currentIndex,
                nowIndex: nowIndex,
                colors: colors,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Playback speed, as a chip that opens the four speeds.
class _SpeedSelector extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onChanged;

  const _SpeedSelector({required this.speed, required this.onChanged});

  static const _speeds = <double>[0.5, 1.0, 2.0, 4.0];

  static String _label(double value) =>
      value == value.roundToDouble() ? '${value.toInt()}×' : '$value×';

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      initialValue: speed,
      onSelected: onChanged,
      tooltip: 'Playback speed',
      // The menu opens in an overlay OUTSIDE the glass, so its contents take
      // the ambient theme's ink, not the dark palette the glass imposes on the
      // chip. Leaving the check uncoloured is what keeps it legible on a white
      // menu in the light theme.
      itemBuilder: (context) => [
        for (final value in _speeds)
          PopupMenuItem<double>(
            value: value,
            child: Row(
              children: [
                if (value == speed)
                  const Icon(LucideIcons.check, size: SkotiqTokens.iconXs)
                else
                  const SizedBox(width: SkotiqTokens.iconXs),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Text(_label(value)),
              ],
            ),
          ),
      ],
      child: SkotiqChip(
        label: _label(speed),
        icon: LucideIcons.chevronsUpDown,
      ),
    );
  }
}

/// Custom painter for the timeline track
class _TimelineTrackPainter extends CustomPainter {
  final List<RadarFrame> frames;
  final int currentIndex;
  final int? nowIndex;
  final SkotiqColors colors;

  _TimelineTrackPainter({
    required this.frames,
    required this.currentIndex,
    required this.nowIndex,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (frames.isEmpty) return;

    const trackHeight = 6.0;
    const tickHeight = 12.0;
    const thumbRadius = 8.0;
    final trackY = size.height / 2;
    final hasMultipleFrames = frames.length > 1;
    final segmentWidth =
        hasMultipleFrames ? size.width / (frames.length - 1) : 0.0;
    final singleFrameX = size.width / 2;

    // Draw track background
    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        0,
        trackY - trackHeight / 2,
        size.width,
        trackHeight,
      ),
      const Radius.circular(SkotiqTokens.radiusXs),
    );

    final trackPaint = Paint()
      ..color = colors.well
      ..style = PaintingStyle.fill;

    canvas.drawRRect(trackRect, trackPaint);

    // Draw frame tick marks
    for (int i = 0; i < frames.length; i++) {
      final frame = frames[i];
      final x = hasMultipleFrames ? i * segmentWidth : singleFrameX;

      // Tick color based on frame type
      final tickColor = frame.isForecast
          ? colors.warning.withValues(alpha: 0.5)
          : colors.textMuted.withValues(alpha: 0.5);

      final tickPaint = Paint()
        ..color = tickColor
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(x, trackY - tickHeight / 2),
        Offset(x, trackY + tickHeight / 2),
        tickPaint,
      );
    }

    // Draw "now" marker if present
    if (nowIndex != null) {
      final nowX = hasMultipleFrames ? nowIndex! * segmentWidth : singleFrameX;
      final nowPaint = Paint()
        ..color = colors.success
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(nowX, trackY - tickHeight),
        Offset(nowX, trackY + tickHeight),
        nowPaint,
      );

      // Draw "NOW" label
      final textSpan = TextSpan(
        text: 'NOW',
        style: SkotiqTypography.readoutLabel.copyWith(
          color: colors.success,
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: ui.TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(nowX - textPainter.width / 2, trackY - tickHeight - 14),
      );
    }

    // Draw progress fill up to current frame
    if (currentIndex > 0 && hasMultipleFrames) {
      final progressWidth = currentIndex * segmentWidth;
      final progressRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          0,
          trackY - trackHeight / 2,
          progressWidth,
          trackHeight,
        ),
        const Radius.circular(SkotiqTokens.radiusXs),
      );

      final progressPaint = Paint()
        ..color = colors.primary.withValues(alpha: 0.3)
        ..style = PaintingStyle.fill;

      canvas.drawRRect(progressRect, progressPaint);
    }

    // Draw current position thumb
    final thumbX =
        hasMultipleFrames ? currentIndex * segmentWidth : singleFrameX;
    final thumbPaint = Paint()
      ..color = colors.primary
      ..style = PaintingStyle.fill;

    final thumbBorderPaint = Paint()
      ..color = colors.background
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(
      Offset(thumbX, trackY),
      thumbRadius,
      thumbPaint,
    );

    canvas.drawCircle(
      Offset(thumbX, trackY),
      thumbRadius,
      thumbBorderPaint,
    );
  }

  @override
  bool shouldRepaint(_TimelineTrackPainter oldDelegate) {
    return oldDelegate.currentIndex != currentIndex ||
        oldDelegate.nowIndex != nowIndex ||
        oldDelegate.frames.length != frames.length;
  }
}
