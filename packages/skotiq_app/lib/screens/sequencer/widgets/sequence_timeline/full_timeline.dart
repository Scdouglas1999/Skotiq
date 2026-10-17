part of '../sequence_timeline.dart';

/// The three twilight band hues as NAMES rather than painted colours.
///
/// [SkotiqChartColors] tokens the astronomical band only; civil and
/// nautical have no chart token yet, so they are named here as the same kind of
/// thing and mapped through the same remap. Band hue is chart data, not chrome:
/// red night is a WAVELENGTH constraint, so painting these raw washed a solid
/// Material blue across a timeline whose every other pixel was red, undoing the
/// dark adaptation the mode exists to protect. Resolve them with
/// [_TwilightBandColors.of] — never paint the constants directly.
@visibleForTesting
final Color namedCivilTwilightBand = Colors.lightBlue.withValues(alpha: 0.2);

@visibleForTesting
final Color namedNauticalTwilightBand = Colors.blue.withValues(alpha: 0.3);

@visibleForTesting
final Color namedAstroTwilightBand = SkotiqChartColors.twilightAstro();

/// The named band hues resolved onto the active theme, once per build.
///
/// Resolved as a set rather than at each band: the overlay adds six regions and
/// the legend three swatches from these same three hues, and a per-site remap
/// is how the legend and the band it explains drift apart.
class _TwilightBandColors {
  final Color civil;
  final Color nautical;
  final Color astro;

  const _TwilightBandColors({
    required this.civil,
    required this.nautical,
    required this.astro,
  });

  factory _TwilightBandColors.of(SkotiqColors colors) =>
      _TwilightBandColors(
        civil: SkotiqChartColors.forTheme(namedCivilTwilightBand, colors),
        nautical:
            SkotiqChartColors.forTheme(namedNauticalTwilightBand, colors),
        astro: SkotiqChartColors.forTheme(namedAstroTwilightBand, colors),
      );
}

/// Full timeline view with labels, astronomical overlays, and details
class _FullTimeline extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final List<TimelineSegment> segments;
  final double totalDuration;
  final bool isRunning;
  final DateTime? startTime;
  final bool showAstronomicalOverlay;
  final Sequence sequence;

  const _FullTimeline({
    required this.colors,
    required this.segments,
    required this.totalDuration,
    required this.isRunning,
    required this.startTime,
    required this.showAstronomicalOverlay,
    required this.sequence,
  });

  @override
  ConsumerState<_FullTimeline> createState() => _FullTimelineState();
}

class _FullTimelineState extends ConsumerState<_FullTimeline>
    with WidgetsBindingObserver {
  Timer? _nowTimer;
  DateTime _now = DateTime.now();

  // Cached twilight times to avoid recalculation on every build
  TwilightTimes? _twilightTimes;
  DateTime? _twilightCacheDate;
  double? _twilightCacheLat;
  double? _twilightCacheLon;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startNowTimer();
  }

  void _startNowTimer() {
    _nowTimer?.cancel();
    // Update the "now" indicator every minute
    _nowTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() {
          _now = DateTime.now();
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Suspend the now-indicator timer when the app is backgrounded so a
    // hidden timeline doesn't repaint every minute.
    if (state == AppLifecycleState.resumed) {
      if (_nowTimer == null || !_nowTimer!.isActive) {
        setState(() => _now = DateTime.now());
        _startNowTimer();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _nowTimer?.cancel();
      _nowTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nowTimer?.cancel();
    super.dispose();
  }

  /// Calculate twilight times, caching to avoid redundant computations
  TwilightTimes? _getTwilightTimes(double lat, double lon, DateTime date) {
    final cacheDate = DateTime(date.year, date.month, date.day);

    if (_twilightTimes != null &&
        _twilightCacheDate == cacheDate &&
        _twilightCacheLat == lat &&
        _twilightCacheLon == lon) {
      return _twilightTimes;
    }

    _twilightTimes = AstronomyCalculations.calculateTwilightTimes(
      date: date,
      latitudeDeg: lat,
      longitudeDeg: lon,
    );
    _twilightCacheDate = cacheDate;
    _twilightCacheLat = lat;
    _twilightCacheLon = lon;

    return _twilightTimes;
  }

  /// Calculate target visibility windows for rise/set markers.
  ///
  /// [date] is the timeline's start INSTANT, so it is resolved to the night
  /// that contains it: the visibility scan runs local noon to noon, and a run
  /// starting after midnight otherwise drew its rise/set markers from the
  /// following night.
  Map<String, ObjectVisibility> _getTargetWindows(
    double lat,
    double lon,
    DateTime date,
  ) {
    final windows = <String, ObjectVisibility>{};
    final nightDate = AstronomyCalculations.nightDateOf(date);

    for (final node in widget.sequence.nodes.values) {
      if (node is TargetHeaderNode && node.isEnabled) {
        final visibility = AstronomyCalculations.calculateObjectVisibility(
          raDeg: node.raHours * 15.0, // Convert RA hours to degrees
          decDeg: node.decDegrees,
          date: nightDate,
          latitudeDeg: lat,
          longitudeDeg: lon,
          minAltitude: node.minAltitude ?? 0,
        );
        windows[node.id] = visibility;
      }
    }

    return windows;
  }

  /// Real run-start timestamp from the active session, when one is running.
  /// Cached in build() (which watches [sessionStateProvider]) so the getters
  /// below stay reactive without each reading the provider independently.
  DateTime? _sessionRunStart;

  /// Anchor the timeline's clock to the real run start: prefer the explicit
  /// [widget.startTime], then the live session's run-start timestamp, and only
  /// fall back to "now" when the rig is genuinely idle (no run in progress).
  /// Falling straight to DateTime.now() made the "now" indicator pin to the
  /// left edge every rebuild instead of advancing through the run.
  DateTime get _effectiveStartTime =>
      widget.startTime ?? _sessionRunStart ?? DateTime.now();

  DateTime get _estimatedEndTime =>
      _effectiveStartTime.add(Duration(seconds: widget.totalDuration.round()));

  bool get _isNowInRange {
    if (widget.totalDuration <= 0) return false;
    return _now.isAfter(_effectiveStartTime) &&
        _now.isBefore(_estimatedEndTime);
  }

  double? get _nowFraction {
    if (!_isNowInRange || widget.totalDuration <= 0) return null;
    final elapsed = _now.difference(_effectiveStartTime).inSeconds;
    return elapsed / widget.totalDuration;
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    // Track the live session run-start so _effectiveStartTime can anchor the
    // "now" indicator to the real run start rather than DateTime.now(). Only
    // meaningful while a run is in flight; idle sessions carry a null start.
    _sessionRunStart =
        widget.isRunning ? ref.watch(sessionStateProvider).startTime : null;

    return settingsAsync.when(
      loading: () => _buildWithoutOverlay(),
      error: (_, __) => _buildWithoutOverlay(),
      data: (settings) {
        final lat = settings.latitude;
        final lon = settings.longitude;

        // Only show astronomical overlay if we have valid location
        final hasValidLocation = lat != 0.0 || lon != 0.0;
        final shouldShowOverlay =
            widget.showAstronomicalOverlay && hasValidLocation;

        TwilightTimes? twilight;
        Map<String, ObjectVisibility>? targetWindows;

        if (shouldShowOverlay) {
          twilight = _getTwilightTimes(lat, lon, _effectiveStartTime);
          targetWindows = _getTargetWindows(lat, lon, _effectiveStartTime);
        }

        return _buildTimeline(
          twilight: twilight,
          targetWindows: targetWindows,
          showOverlay: shouldShowOverlay,
        );
      },
    );
  }

  Widget _buildWithoutOverlay() {
    return _buildTimeline(
      twilight: null,
      targetWindows: null,
      showOverlay: false,
    );
  }

  Widget _buildTimeline({
    required TwilightTimes? twilight,
    required Map<String, ObjectVisibility>? targetWindows,
    required bool showOverlay,
  }) {
    final bands = _TwilightBandColors.of(widget.colors);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Icon(LucideIcons.ganttChart,
                  size: 14, color: widget.colors.textMuted),
              const SizedBox(width: 8),
              Text(
                'Sequence Timeline',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  fontWeight: FontWeight.w600,
                  color: widget.colors.textSecondary,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              Text(
                _formatDuration(widget.totalDuration),
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: widget.colors.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),

        // Timeline bar with overlays
        LayoutBuilder(
          builder: (context, constraints) {
            return Container(
              height: 40,
              decoration: BoxDecoration(
                color: widget.colors.surfaceAlt,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                border: Border.all(color: widget.colors.border),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                child: Stack(
                  children: [
                    // Twilight overlay bands (behind the timeline segments)
                    if (showOverlay && twilight != null)
                      _buildTwilightOverlay(
                          twilight, constraints.maxWidth, bands),

                    // Timeline segments
                    widget.totalDuration > 0
                        ? Row(
                            children: widget.segments.map((segment) {
                              final widthFraction =
                                  segment.duration / widget.totalDuration;
                              return Expanded(
                                flex: (widthFraction * 1000)
                                    .round()
                                    .clamp(1, 1000),
                                child: _TimelineBlock(
                                  colors: widget.colors,
                                  segment: segment,
                                ),
                              );
                            }).toList(),
                          )
                        : Center(
                            child: Text(
                              'No timed activities',
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize11,
                                color: widget.colors.textMuted,
                              ),
                            ),
                          ),

                    // Target rise/set markers
                    if (showOverlay && targetWindows != null)
                      ..._buildTargetMarkers(
                          targetWindows, constraints.maxWidth),

                    // "Now" indicator
                    if (_nowFraction != null)
                      _buildNowIndicator(constraints.maxWidth),
                  ],
                ),
              ),
            );
          },
        ),

        // Estimated completion time
        if (widget.startTime != null || widget.totalDuration > 0) ...[
          const SizedBox(height: 8),
          _buildCompletionInfo(),
        ],

        // Legend
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _LegendItem(
                colors: widget.colors,
                color: widget.colors.primary,
                label: 'Exposure'),
            _LegendItem(
                colors: widget.colors,
                color: widget.colors.warning,
                label: 'Focus'),
            _LegendItem(
                colors: widget.colors,
                color: widget.colors.accent,
                label: 'Slew'),
            _LegendItem(
                colors: widget.colors,
                color: widget.colors.info,
                label: 'Dither'),
            _LegendItem(
                colors: widget.colors,
                color: widget.colors.textMuted,
                label: 'Wait'),
            _LegendItem(
                colors: widget.colors,
                color: widget.colors.textSecondary,
                label: 'Other'),
            if (showOverlay) ...[
              const SizedBox(width: 8),
              _LegendItem(
                colors: widget.colors,
                color: bands.civil,
                label: 'Civil',
              ),
              _LegendItem(
                colors: widget.colors,
                color: bands.nautical,
                label: 'Nautical',
              ),
              _LegendItem(
                colors: widget.colors,
                color: bands.astro,
                label: 'Astro',
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Build twilight overlay bands behind the timeline
  Widget _buildTwilightOverlay(
    TwilightTimes twilight,
    double totalWidth,
    _TwilightBandColors bands,
  ) {
    if (widget.totalDuration <= 0) {
      return const SizedBox.shrink();
    }

    final start = _effectiveStartTime;
    final end = _estimatedEndTime;

    // Build list of twilight regions within our timeline range
    final regions = <_TwilightRegion>[];

    // Helper to add a region if it overlaps with our timeline
    void addRegion(DateTime? regionStart, DateTime? regionEnd, Color color) {
      if (regionStart == null || regionEnd == null) return;
      if (regionEnd.isBefore(start) || regionStart.isAfter(end)) return;

      // Clamp to timeline range
      final clampedStart = regionStart.isBefore(start) ? start : regionStart;
      final clampedEnd = regionEnd.isAfter(end) ? end : regionEnd;

      final startFraction =
          clampedStart.difference(start).inSeconds / widget.totalDuration;
      final endFraction =
          clampedEnd.difference(start).inSeconds / widget.totalDuration;

      if (endFraction > startFraction) {
        regions.add(_TwilightRegion(
          startFraction: startFraction.clamp(0.0, 1.0),
          endFraction: endFraction.clamp(0.0, 1.0),
          color: color,
        ));
      }
    }

    // Civil twilight (evening): sunset to civil dusk
    addRegion(twilight.sunset, twilight.civilDusk, bands.civil);

    // Nautical twilight (evening): civil dusk to nautical dusk
    addRegion(twilight.civilDusk, twilight.nauticalDusk, bands.nautical);

    // Astronomical twilight (evening): nautical dusk to astronomical dusk
    addRegion(twilight.nauticalDusk, twilight.astronomicalDusk, bands.astro);

    // Astronomical twilight (morning): astronomical dawn to nautical dawn
    addRegion(twilight.astronomicalDawn, twilight.nauticalDawn, bands.astro);

    // Nautical twilight (morning): nautical dawn to civil dawn
    addRegion(twilight.nauticalDawn, twilight.civilDawn, bands.nautical);

    // Civil twilight (morning): civil dawn to sunrise
    addRegion(twilight.civilDawn, twilight.sunrise, bands.civil);

    return Stack(
      children: regions.map((region) {
        return Positioned(
          left: region.startFraction * totalWidth,
          width: (region.endFraction - region.startFraction) * totalWidth,
          top: 0,
          bottom: 0,
          child: Container(color: region.color),
        );
      }).toList(),
    );
  }

  /// Build target rise/set markers as vertical lines with tooltips
  List<Widget> _buildTargetMarkers(
    Map<String, ObjectVisibility> targetWindows,
    double totalWidth,
  ) {
    if (widget.totalDuration <= 0) {
      return [];
    }

    final markers = <Widget>[];
    final start = _effectiveStartTime;
    final end = _estimatedEndTime;

    for (final entry in targetWindows.entries) {
      final targetNode = widget.sequence.nodes[entry.key];
      if (targetNode is! TargetHeaderNode) continue;

      final visibility = entry.value;
      final targetName = targetNode.targetName;

      // Rise marker
      if (visibility.riseTime != null &&
          visibility.riseTime!.isAfter(start) &&
          visibility.riseTime!.isBefore(end)) {
        final fraction = visibility.riseTime!.difference(start).inSeconds /
            widget.totalDuration;
        markers.add(_buildTargetMarker(
          fraction: fraction,
          totalWidth: totalWidth,
          label: '$targetName rises',
          color: widget.colors.success,
          icon: LucideIcons.sunrise,
        ));
      }

      // Set marker
      if (visibility.setTime != null &&
          visibility.setTime!.isAfter(start) &&
          visibility.setTime!.isBefore(end)) {
        final fraction = visibility.setTime!.difference(start).inSeconds /
            widget.totalDuration;
        markers.add(_buildTargetMarker(
          fraction: fraction,
          totalWidth: totalWidth,
          label: '$targetName sets',
          color: widget.colors.warning,
          icon: LucideIcons.sunset,
        ));
      }

      // Transit marker (optional - can add if desired)
      if (visibility.transitTime != null &&
          visibility.transitTime!.isAfter(start) &&
          visibility.transitTime!.isBefore(end)) {
        final fraction = visibility.transitTime!.difference(start).inSeconds /
            widget.totalDuration;
        markers.add(_buildTargetMarker(
          fraction: fraction,
          totalWidth: totalWidth,
          label: '$targetName transit',
          color: widget.colors.info,
          icon: LucideIcons.moveVertical,
        ));
      }
    }

    return markers;
  }

  Widget _buildTargetMarker({
    required double fraction,
    required double totalWidth,
    required String label,
    required Color color,
    required IconData icon,
  }) {
    return Positioned(
      left: fraction * totalWidth - 6, // Center the 12px wide marker
      top: 0,
      bottom: 0,
      child: Tooltip(
        message: label,
        child: Container(
          width: 12,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: color.withValues(alpha: 0.8),
                width: 2,
              ),
            ),
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              padding: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.9),
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline2),
              ),
              child: Icon(
                icon,
                size: 8,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Build the "now" indicator as a vertical red line
  Widget _buildNowIndicator(double totalWidth) {
    final fraction = _nowFraction;
    if (fraction == null) return const SizedBox.shrink();

    return Positioned(
      left: fraction * totalWidth - 1, // Center the 2px wide line
      top: 0,
      bottom: 0,
      child: Tooltip(
        message: 'Now: ${_formatClockTime(_now)}',
        child: Container(
          width: 2,
          decoration: BoxDecoration(
            color: widget.colors.error,
            boxShadow: [
              BoxShadow(
                color: widget.colors.error.withValues(alpha: 0.5),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Column(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: widget.colors.error,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build estimated completion info
  Widget _buildCompletionInfo() {
    final remaining = _estimatedEndTime.difference(_now);
    final isInPast = remaining.isNegative;

    String completionText;
    if (widget.startTime != null) {
      completionText =
          'Est. completion: ${_formatClockTime(_estimatedEndTime)}';
      if (!isInPast && remaining.inMinutes > 0) {
        completionText +=
            ' (~${_formatRemainingDuration(remaining)} remaining)';
      } else if (isInPast) {
        completionText += ' (completed)';
      }
    } else {
      completionText = 'Duration: ${_formatRemainingDuration(
        Duration(seconds: widget.totalDuration.round()),
      )}';
    }

    return Row(
      children: [
        Icon(
          LucideIcons.clock,
          size: 12,
          color: widget.colors.textMuted,
        ),
        const SizedBox(width: 6),
        Text(
          completionText,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: widget.colors.textMuted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  String _formatDuration(double seconds) =>
      '${DurationFormat.seconds(seconds, style: DurationStyle.compact, rounding: DurationRounding.truncate)} total';

  String _formatRemainingDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  String _formatClockTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
