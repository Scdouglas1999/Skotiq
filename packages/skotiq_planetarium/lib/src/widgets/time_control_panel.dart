import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:intl/intl.dart';
import '../astronomy/astronomy_calculations.dart';
import '../providers/planetarium_providers.dart';

/// Time control panel for the planetarium
///
/// Provides controls for:
/// - Real-time toggle
/// - Time speed multiplier
/// - Jump to specific date/time
/// - Jump to tonight's astronomical dusk
class TimeControlPanel extends ConsumerStatefulWidget {
  /// Background color
  final Color? backgroundColor;

  /// Text color
  final Color? textColor;

  /// Accent color for buttons
  final Color? accentColor;

  /// Whether to show compact mode (icon-only buttons)
  final bool compact;

  const TimeControlPanel({
    super.key,
    this.backgroundColor,
    this.textColor,
    this.accentColor,
    this.compact = false,
  });

  @override
  ConsumerState<TimeControlPanel> createState() => _TimeControlPanelState();
}

class _TimeControlPanelState extends ConsumerState<TimeControlPanel> {
  static const List<double> _speedMultipliers = [
    -86400.0, // -1 day/sec
    -3600.0, // -1 hour/sec
    -60.0, // -1 min/sec
    1.0, // Real time
    60.0, // +1 min/sec
    3600.0, // +1 hour/sec
    86400.0, // +1 day/sec
  ];

  /// Index of the 1x entry in [_speedMultipliers] — "play" in the wall-clock
  /// sense, as opposed to any of the accelerated rates.
  static const int _realTimeSpeedIndex = 3;

  int _currentSpeedIndex = _realTimeSpeedIndex;

  /// What play should go back to. Pausing an accelerated sky and pressing play
  /// resumes that rate; pausing a live sky resumes the wall clock.
  bool _resumeToRealTime = true;

  @override
  Widget build(BuildContext context) {
    final timeState = ref.watch(observationTimeProvider);
    final twilight = ref.watch(twilightTimesProvider);

    final bgColor = widget.backgroundColor ?? const Color(0xFF1A1A2E);
    final txtColor = widget.textColor ?? Colors.white;
    final accent = widget.accentColor ?? const Color(0xFF00E676);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: txtColor.withValues(alpha: 0.1)),
      ),
      child: widget.compact
          ? LayoutBuilder(
              builder: (context, constraints) => _buildCompactLayout(
                timeState,
                twilight,
                txtColor,
                accent,
                // At 360/369 px device widths the panel has roughly 336/345
                // px after its own padding. The labelled NOW action pushes
                // the otherwise compact row past that limit.
                narrow: constraints.maxWidth < 360,
              ),
            )
          : _buildFullLayout(timeState, twilight, txtColor, accent),
    );
  }

  Widget _buildCompactLayout(
    ObservationTimeState timeState,
    TwilightTimes twilight,
    Color txtColor,
    Color accent, {
    required bool narrow,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Time display
        _buildTimeDisplay(timeState, txtColor, showSeconds: !narrow),
        const SizedBox(width: 8),
        // Play/Pause
        _buildPlayPauseButton(timeState, accent),
        // Speed controls
        _buildSpeedButton(isForward: false, color: txtColor),
        _buildSpeedButton(isForward: true, color: txtColor),
        // Now button
        narrow ? _buildCompactNowButton(accent) : _buildNowButton(accent),
      ],
    );
  }

  Widget _buildFullLayout(
    ObservationTimeState timeState,
    TwilightTimes twilight,
    Color txtColor,
    Color accent,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Date/Time row
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Date button
            _buildDateButton(timeState.time, txtColor),
            const SizedBox(width: 8),
            // Time display
            _buildTimeDisplay(timeState, txtColor),
            const SizedBox(width: 8),
            // Speed indicator
            _buildSpeedIndicator(timeState, txtColor),
          ],
        ),
        const SizedBox(height: 8),
        // Controls row
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Fast rewind
            _buildSpeedButton(isForward: false, large: true, color: txtColor),
            const SizedBox(width: 4),
            // Step back
            _accessibleControl(
              label: 'Back 1 hour',
              IconButton(
                icon: Icon(LucideIcons.skipBack, color: txtColor, size: 18),
                onPressed: () => _stepTime(-3600), // -1 hour
                tooltip: 'Back 1 hour',
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(),
              ),
            ),
            const SizedBox(width: 4),
            // Play/Pause
            _buildPlayPauseButton(timeState, accent, large: true),
            const SizedBox(width: 4),
            // Step forward
            _accessibleControl(
              label: 'Forward 1 hour',
              IconButton(
                icon: Icon(LucideIcons.skipForward, color: txtColor, size: 18),
                onPressed: () => _stepTime(3600), // +1 hour
                tooltip: 'Forward 1 hour',
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(),
              ),
            ),
            const SizedBox(width: 4),
            // Fast forward
            _buildSpeedButton(isForward: true, large: true, color: txtColor),
          ],
        ),
        const SizedBox(height: 8),
        // Quick actions row
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildNowButton(accent, expanded: false),
            const SizedBox(width: 8),
            _buildTonightButton(twilight, accent),
          ],
        ),
      ],
    );
  }

  /// Put a transport control's accessible NAME on the button node itself.
  ///
  /// `IconButton(tooltip: ...)` does not name anything: Flutter's `Tooltip`
  /// publishes its message as `SemanticsProperties.tooltip`, a field separate
  /// from the label, so the button node's name stays empty. A live AT-SPI dump
  /// of the full transport showed exactly that — five bare `button:` entries
  /// with empty names between `Aug 13, 2026` and `NOW`, and no toggle state on
  /// the one that stops time, so the pause fix was invisible to assistive tech.
  ///
  /// [toggled] additionally gives the control an on/off state to report; used
  /// by play/pause, whose whole job is to hold the sky still. `MergeSemantics`
  /// collapses name, button role, enabled state and tap action onto one node —
  /// the same idiom the Layers rows use.
  Widget _accessibleControl(
    Widget child, {
    required String label,
    bool? toggled,
  }) {
    return MergeSemantics(
      child: Semantics(label: label, toggled: toggled, child: child),
    );
  }

  /// A readout that is its OWN accessible node, named in full.
  ///
  /// Flutter merges compatible sibling label fragments into the nearest
  /// enclosing node, and the nearest enclosing node on this screen is the sky
  /// canvas — which carries a tap action. So the clock, the rate chip and the
  /// whole bottom info bar arrived at AT-SPI as ONE focusable panel named
  /// "20:37:18 / 1x / Center RA: ... / Bortle: 5", reported as
  /// interactive-but-disabled. `container: true` makes each readout a node in
  /// its own right; `excludeSemantics` stops the raw glyphs being read twice,
  /// so the label carries the whole reading.
  Widget _readoutNode(Widget child, {required String label}) {
    return Semantics(
      container: true,
      label: label,
      excludeSemantics: true,
      child: child,
    );
  }

  Widget _buildTimeDisplay(
    ObservationTimeState timeState,
    Color txtColor, {
    bool showSeconds = true,
  }) {
    final timeFormat = DateFormat(showSeconds ? 'HH:mm:ss' : 'HH:mm');
    final displayTime = timeFormat.format(timeState.time);

    return _readoutNode(
      label: 'Sky time $displayTime',
      Text(
        displayTime,
        style: TextStyle(
          color: txtColor,
          fontSize: 18,
          fontWeight: FontWeight.w500,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Widget _buildDateButton(DateTime time, Color txtColor) {
    final dateFormat = DateFormat('MMM d, yyyy');

    // A bare InkWell carries no button role and no enabled state, so the chip
    // that opens the date picker was reported as an inert, DISABLED panel.
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: true,
        hint: 'Choose a date',
        child: InkWell(
          onTap: () => _showDatePicker(time),
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: txtColor.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.calendar, size: 14, color: txtColor),
                const SizedBox(width: 4),
                Text(
                  dateFormat.format(time),
                  style: TextStyle(color: txtColor, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedIndicator(ObservationTimeState timeState, Color txtColor) {
    // A held sky says so: reporting "1×" while nothing moves states a rate the
    // clock is not running at.
    if (timeState.isPaused) {
      return _readoutNode(
        label: 'Time paused',
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            'PAUSED',
            style: TextStyle(
              color: Colors.orange,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }

    final speed = _speedMultipliers[_currentSpeedIndex];
    String speedText;

    if (speed == 1.0) {
      speedText = '1×';
    } else if (speed.abs() >= 86400) {
      speedText = '${speed > 0 ? '+' : ''}${(speed / 86400).round()}d/s';
    } else if (speed.abs() >= 3600) {
      speedText = '${speed > 0 ? '+' : ''}${(speed / 3600).round()}h/s';
    } else if (speed.abs() >= 60) {
      speedText = '${speed > 0 ? '+' : ''}${(speed / 60).round()}m/s';
    } else {
      speedText = '${speed > 0 ? '+' : ''}${speed.round()}×';
    }

    return _readoutNode(
      label: 'Time running at $speedText',
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: speed != 1.0
              ? (speed > 0 ? Colors.green : Colors.orange).withValues(
                  alpha: 0.2,
                )
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          speedText,
          style: TextStyle(
            color: speed != 1.0
                ? (speed > 0 ? Colors.green : Colors.orange)
                : txtColor.withValues(alpha: 0.7),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildPlayPauseButton(
    ObservationTimeState timeState,
    Color accent, {
    bool large = false,
  }) {
    final running = !timeState.isPaused;

    // Name the ACTION and publish no toggle state.
    //
    // Naming the action AND inverting a toggle state is the one combination
    // that contradicts itself: with `label: running ? 'Pause' : 'Play'` and
    // `toggled: !running`, assistive tech announced "Play, toggle button, on"
    // at the moment time was held and "Pause, toggle button, off" while it ran
    // — the name and the state saying opposite things about the same sky. The
    // state now lives where it is also drawn, on the rate chip beside the
    // clock (see [_buildSpeedIndicator]), which publishes "Time paused" /
    // "Time running at 1×" as its own accessible node.
    return _accessibleControl(
      label: running ? 'Pause time' : 'Play time',
      IconButton(
        icon: Icon(
          running ? LucideIcons.pause : LucideIcons.play,
          color: accent,
          size: large ? 24 : 18,
        ),
        onPressed: _togglePlayPause,
        tooltip: running ? 'Pause' : 'Play',
        padding: EdgeInsets.all(large ? 12 : 8),
        constraints: const BoxConstraints(),
        style: IconButton.styleFrom(
          backgroundColor: accent.withValues(alpha: 0.1),
          shape: const CircleBorder(),
        ),
      ),
    );
  }

  Widget _buildSpeedButton({
    required bool isForward,
    bool large = false,
    required Color color,
  }) {
    return _accessibleControl(
      label: isForward ? 'Faster' : 'Slower',
      IconButton(
        icon: Icon(
          isForward ? LucideIcons.fastForward : LucideIcons.rewind,
          color: color,
          size: large ? 20 : 16,
        ),
        onPressed: () => _changeSpeed(isForward),
        tooltip: isForward ? 'Faster' : 'Slower',
        padding: EdgeInsets.all(large ? 8 : 4),
        constraints: const BoxConstraints(),
      ),
    );
  }

  Widget _buildNowButton(Color accent, {bool expanded = false}) {
    final button = TextButton.icon(
      icon: Icon(LucideIcons.clock, size: 14, color: accent),
      // Title case, like every other button in the build.
      label: Text('Now', style: TextStyle(color: accent, fontSize: 11)),
      onPressed: _jumpToNow,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );

    return expanded ? Expanded(child: button) : button;
  }

  Widget _buildCompactNowButton(Color accent) {
    return _accessibleControl(
      label: 'Jump to now',
      IconButton(
        icon: Icon(LucideIcons.clock, size: 18, color: accent),
        tooltip: 'Jump to now',
        onPressed: _jumpToNow,
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _buildTonightButton(TwilightTimes twilight, Color accent) {
    final hasDusk = twilight.astronomicalDusk != null;

    return TextButton.icon(
      icon: Icon(
        LucideIcons.moon,
        size: 14,
        color: hasDusk ? accent : accent.withValues(alpha: 0.5),
      ),
      label: Text(
        // Title case, like every other button in the build.
        'Tonight',
        style: TextStyle(
          color: hasDusk ? accent : accent.withValues(alpha: 0.5),
          fontSize: 11,
        ),
      ),
      onPressed: hasDusk ? () => _jumpToTonight(twilight) : null,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  void _togglePlayPause() {
    final notifier = ref.read(observationTimeProvider.notifier);
    final currentState = ref.read(observationTimeProvider);

    if (!currentState.isPaused) {
      _resumeToRealTime = currentState.isRealTime;
      notifier.pause();
      return;
    }
    if (_resumeToRealTime) {
      setState(() => _currentSpeedIndex = _realTimeSpeedIndex);
      notifier.setRealTime(true);
    } else {
      notifier.setSpeedMultiplier(_speedMultipliers[_currentSpeedIndex]);
    }
  }

  void _changeSpeed(bool faster) {
    setState(() {
      if (faster && _currentSpeedIndex < _speedMultipliers.length - 1) {
        _currentSpeedIndex++;
      } else if (!faster && _currentSpeedIndex > 0) {
        _currentSpeedIndex--;
      }
    });

    final speed = _speedMultipliers[_currentSpeedIndex];
    ref.read(observationTimeProvider.notifier).setSpeedMultiplier(speed);
  }

  void _stepTime(int seconds) {
    final notifier = ref.read(observationTimeProvider.notifier);
    if (seconds > 0) {
      notifier.fastForward(Duration(seconds: seconds));
    } else {
      notifier.rewind(Duration(seconds: -seconds));
    }
  }

  void _jumpToNow() {
    setState(() => _currentSpeedIndex = 3);
    ref.read(observationTimeProvider.notifier).setRealTime(true);
  }

  void _jumpToTonight(TwilightTimes twilight) {
    if (twilight.astronomicalDusk != null) {
      ref
          .read(observationTimeProvider.notifier)
          .setTime(twilight.astronomicalDusk!);
      ref.read(observationTimeProvider.notifier).setRealTime(false);
    }
  }

  Future<void> _showDatePicker(DateTime currentDate) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: currentDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      // Combine picked date with current time
      final currentTime = ref.read(observationTimeProvider).time;
      final newDateTime = DateTime(
        picked.year,
        picked.month,
        picked.day,
        currentTime.hour,
        currentTime.minute,
        currentTime.second,
      );
      ref.read(observationTimeProvider.notifier).setTime(newDateTime);
      ref.read(observationTimeProvider.notifier).setRealTime(false);
    }
  }
}
