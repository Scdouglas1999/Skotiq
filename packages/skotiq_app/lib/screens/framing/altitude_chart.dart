import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
// Hide TwilightTimes from the core barrel (the scheduler's
// sky_calculations.dart adds its own). This chart consumes planetarium's
// TwilightTimes via AstronomyCalculations below.
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../analytics/widgets/adaptive_chart_container.dart';

/// Altitude chart widget showing target visibility over time
class AltitudeChart extends ConsumerStatefulWidget {
  final double raHours;
  final double decDegrees;
  final String? targetName;

  /// Test seam for the wall clock. Production always uses [DateTime.now];
  /// the astronomy here needs the true instant, so it deliberately does NOT
  /// go through `clockProvider` (that clock returns the operator's *chosen*
  /// timezone rendering, which would skew rise/transit/set math).
  final DateTime Function()? nowOverride;

  const AltitudeChart({
    super.key,
    required this.raHours,
    required this.decDegrees,
    this.targetName,
    this.nowOverride,
  });

  DateTime nowValue() => nowOverride?.call() ?? DateTime.now();

  @override
  ConsumerState<AltitudeChart> createState() => _AltitudeChartState();
}

class _AltitudeChartState extends ConsumerState<AltitudeChart> {
  List<FlSpot> _altitudeData = [];
  List<FlSpot> _airmassData = [];
  TwilightTimes? _twilight;
  ObjectVisibility? _visibility;
  DateTime _startTime = DateTime.now();
  DateTime _endTime = DateTime.now();

  /// The target's altitude right now, or null when it is NOT KNOWN — no
  /// observing site is configured, so there is no basis for an altitude at all.
  ///
  /// Deliberately nullable rather than a `0` sentinel. As a plain double it
  /// stayed at its `0` initial value whenever [_calculateData] bailed out for a
  /// missing site, and the chip below rendered a hard red "Alt: 0.0°" — a
  /// specific claim that the target is on the horizon — immediately above the
  /// "Set location in Settings" panel that admits the app has no location.
  double? _currentAltitude;

  /// The clock every HH:MM face in this widget renders through. Assigned from
  /// [clockProvider] at the top of [build]; see the note there.
  Clock _clock = const SystemClock();
  double _currentAirmass = 0;
  bool _showAirmass = false;

  /// Wall clock for the present-tense readouts.
  ///
  /// [_calculateData] runs on mount and on a ra/dec (or settings) change only,
  /// so without a tick the chips labelled "Alt:" and "Airmass:" — present
  /// tense, no timestamp — keep stating whatever the sky looked like when the
  /// card first built.
  ///
  /// Only the "now" quantities are recomputed on the tick. The night curve and
  /// the twilight window are properties of the night, not of the minute, so
  /// re-solving them on every candidate card every minute would be wasted work.
  Timer? _nowTicker;

  @override
  void initState() {
    super.initState();
    _calculateData();
    // One minute: the fastest a target's altitude moves is ~0.25°/min at the
    // horizon, so the 0.1° the chip prints can never be more than a rounding
    // step behind.
    _nowTicker = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshCurrentPosition(),
    );
  }

  @override
  void dispose() {
    _nowTicker?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(AltitudeChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.raHours != widget.raHours ||
        oldWidget.decDegrees != widget.decDegrees) {
      _calculateData();
    }
  }

  /// Re-solve the target's altitude/airmass for the current instant.
  void _refreshCurrentPosition() {
    if (!mounted) return;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return;

    final lat = settings.latitude;
    final lon = settings.longitude;
    // No observing site: the chips already say an em dash and there is nothing to
    // refresh them to.
    if (!settings.hasObserverLocation) return;

    final now = widget.nowValue();
    // Left open past the end of the plotted night: the whole solve is stale,
    // not just the marker, so redo it rather than moving a dot around a window
    // that has finished.
    if (now.isAfter(_endTime)) {
      _calculateData();
      return;
    }

    final (alt, _) = AstronomyCalculations.objectAltAz(
      raDeg: widget.raHours * 15.0,
      decDeg: widget.decDegrees,
      dt: now,
      latitudeDeg: lat,
      longitudeDeg: lon,
    );
    setState(() {
      _currentAltitude = alt;
      _currentAirmass = alt > 0 ? AstronomyCalculations.airmass(alt) : 0;
    });
  }

  void _calculateData() {
    final settingsAsync = ref.read(appSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    if (settings == null) return;

    final lat = settings.latitude;
    final lon = settings.longitude;

    if (!settings.hasObserverLocation) {
      setState(() {
        _altitudeData = [];
        _airmassData = [];
        // No site => no altitude. Clear it rather than leaving a stale (or
        // initial-zero) value that the chip would present as fact.
        _currentAltitude = null;
        _currentAirmass = 0;
        _visibility = null;
        _twilight = null;
      });
      return;
    }

    final now = widget.nowValue();
    final raDeg = widget.raHours * 15.0;
    final decDeg = widget.decDegrees;

    // Which night to plot. `calculateTwilightTimes(date:)` returns a
    // sunset-tonight → sunrise-tomorrow window, so anchoring purely on the
    // calendar date describes the NEXT night once the clock passes midnight —
    // while the user is still imaging the current one. Mirror
    // `twilightTimesProvider`: keep the previous date's window for as long as
    // it is still running.
    TwilightTimes twilightFor(DateTime date) =>
        AstronomyCalculations.calculateTwilightTimes(
          date: date,
          latitudeDeg: lat,
          longitudeDeg: lon,
        );

    final todayTwilight = twilightFor(now);
    _twilight = todayTwilight;
    final tonightStart = todayTwilight.sunset?.subtract(
      const Duration(hours: 1),
    );
    final todaySunrise = todayTwilight.sunrise;
    if (tonightStart != null &&
        todaySunrise != null &&
        now.isBefore(tonightStart)) {
      // A twilight solve costs ~1.3 ms and this widget is built once per
      // planner candidate card, so estimate before paying for a second one.
      // `sunrise` is TOMORROW morning's, so the previous night's window ended
      // about 23 h earlier; sunrise drifts only a couple of minutes a day, and
      // the slack covers that. Past that estimate there is no running night to
      // switch to and the calendar-date window is already the right one.
      final approximatePreviousEnd = todaySunrise.subtract(
        const Duration(hours: 23) - const Duration(minutes: 15),
      );
      if (now.isBefore(approximatePreviousEnd)) {
        final previousTwilight = twilightFor(
          now.subtract(const Duration(days: 1)),
        );
        final previousEnd = previousTwilight.sunrise?.add(
          const Duration(hours: 1),
        );
        if (previousEnd != null && previousEnd.isAfter(now)) {
          _twilight = previousTwilight;
        }
      }
    }

    // Determine time range - prefer sunset to sunrise, fallback to 12 hours
    if (_twilight?.sunset != null && _twilight?.sunrise != null) {
      _startTime = _twilight!.sunset!.subtract(const Duration(hours: 1));
      _endTime = _twilight!.sunrise!.add(const Duration(hours: 1));
    } else {
      _startTime = now.subtract(const Duration(hours: 2));
      _endTime = now.add(const Duration(hours: 10));
    }

    // Calculate visibility info for the night this chart is PLOTTING.
    //
    // `date` selects a noon-to-noon search window, so passing the raw `now`
    // described a different night than the curve above whenever the clock was
    // on the other side of local noon from the plotted window — and the
    // planner scorer anchors on `nightDateOf` of its own night. One card then
    // printed the warning's rise time and this footer's rise time a sidereal
    // day apart for the same event. Anchoring both on the same rule makes that
    // structurally impossible.
    final plottedNightMid = _startTime.add(
      Duration(
        milliseconds: _endTime.difference(_startTime).inMilliseconds ~/ 2,
      ),
    );
    _visibility = AstronomyCalculations.calculateObjectVisibility(
      raDeg: raDeg,
      decDeg: decDeg,
      date: AstronomyCalculations.nightDateOf(plottedNightMid),
      latitudeDeg: lat,
      longitudeDeg: lon,
      minAltitude: 0,
    );

    // Calculate altitude at 10-minute intervals
    final altitudePoints = <FlSpot>[];
    final airmassPoints = <FlSpot>[];
    var time = _startTime;
    const interval = Duration(minutes: 10);

    while (time.isBefore(_endTime) || time.isAtSameMomentAs(_endTime)) {
      final x = time.difference(_startTime).inMinutes.toDouble();
      final (alt, _) = AstronomyCalculations.objectAltAz(
        raDeg: raDeg,
        decDeg: decDeg,
        dt: time,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );

      altitudePoints.add(FlSpot(x, alt.clamp(-10, 90)));

      // Calculate airmass (only meaningful above horizon)
      if (alt > 0) {
        final airmass = AstronomyCalculations.airmass(alt);
        airmassPoints.add(FlSpot(x, airmass.clamp(1, 5)));
      }

      time = time.add(interval);
    }

    // Calculate current altitude
    final (currentAlt, _) = AstronomyCalculations.objectAltAz(
      raDeg: raDeg,
      decDeg: decDeg,
      dt: now,
      latitudeDeg: lat,
      longitudeDeg: lon,
    );
    _currentAltitude = currentAlt;
    _currentAirmass =
        currentAlt > 0 ? AstronomyCalculations.airmass(currentAlt) : 0;

    setState(() {
      _altitudeData = altitudePoints;
      _airmassData = airmassPoints;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    // Recompute when location settings resolve after this widget mounts,
    // otherwise the chart stays stuck on the "Set location" warning.
    ref.listen(appSettingsProvider, (prev, next) {
      if (next.hasValue) _calculateData();
    });

    // Captured here, in build, rather than read inside the formatter: the axis
    // and tooltip label callbacks run during the chart's layout, where
    // `ref.watch` is illegal, and `ref.read` would leave the faces on whatever
    // clock existed before `appSettingsProvider` resolved — i.e. host-local
    // forever, which is the defect this replaced.
    _clock = ref.watch(clockProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with toggle
        Row(
          children: [
            Icon(LucideIcons.trendingUp, size: 14, color: colors.textMuted),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Altitude',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SkotiqTypography.eyebrow
                    .copyWith(color: colors.textPrimary),
              ),
            ),
            const Spacer(),
            // Airmass toggle
            GestureDetector(
              onTap: () => setState(() => _showAirmass = !_showAirmass),
              child: Row(
                children: [
                  Icon(
                    _showAirmass ? LucideIcons.checkSquare : SkotiqIcons.stop,
                    size: 12,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Airmass',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Current values
        _buildCurrentValues(colors),
        const SizedBox(height: 8),

        // Chart
        if (_altitudeData.isEmpty)
          _buildNoLocationWarning(colors)
        else
          _buildChart(colors),

        const SizedBox(height: 8),

        // Rise/Transit/Set times
        if (_visibility != null) _buildVisibilityInfo(colors),
      ],
    );
  }

  Widget _buildCurrentValues(SkotiqColors colors) {
    final altitude = _currentAltitude;
    // Unknown altitude: show the same em dash the Coordinates card uses, with no
    // severity colouring. A red "0.0°" here read as "your target is on the
    // horizon", which the app cannot know without an observing site.
    // Wrap, not Row: these chips size to their own content, so in a narrow
    // framing rail (or a phone in landscape) a fixed Row had no way to yield and
    // overflowed by ~5 px. Wrapping to a second line costs nothing here and
    // cannot clip, whereas ellipsizing a value chip would hide the number that
    // is the entire point of it.
    if (altitude == null) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _buildValueChip(colors, 'Alt', kReadoutUnknown, colors.textMuted),
          _buildValueChip(colors, 'Airmass', kReadoutUnknown, colors.textMuted),
        ],
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _buildValueChip(
          colors,
          'Alt',
          '${altitude.toStringAsFixed(1)}°',
          altitude > 30
              ? colors.success
              : altitude > 0
                  ? colors.warning
                  : colors.error,
        ),
        if (altitude > 0)
          _buildValueChip(
            colors,
            'Airmass',
            _currentAirmass.toStringAsFixed(2),
            _currentAirmass < 1.5
                ? colors.success
                : _currentAirmass < 2.0
                    ? colors.warning
                    : colors.error,
          ),
      ],
    );
  }

  Widget _buildValueChip(
      SkotiqColors colors, String label, String value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: SkotiqTokens.borderRadiusInline4,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
          Text(
            value,
            style: SkotiqTypography.caption
                .copyWith(color: valueColor, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildNoLocationWarning(SkotiqColors colors) {
    return AdaptiveChartContainer.fixed(
      height: 120,
      child: Container(
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: SkotiqTokens.borderRadiusInline8,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(SkotiqIcons.location, size: 24, color: colors.textMuted),
              const SizedBox(height: 8),
              Text(
                'Set location in Settings',
                style:
                    SkotiqTypography.caption.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChart(SkotiqColors colors) {
    final siteMinimumAltitude = ref.watch(siteMinimumAltitudeDegProvider);
    final now = widget.nowValue();
    final nowX = now.difference(_startTime).inMinutes.toDouble();
    final totalMinutes = _endTime.difference(_startTime).inMinutes.toDouble();

    return AdaptiveChartContainer(
      preferredHeight: 140,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: totalMinutes,
          minY: _showAirmass ? 1 : -10,
          maxY: _showAirmass ? 5 : 90,
          clipData: const FlClipData.all(),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: true,
            horizontalInterval: _showAirmass ? 1 : 30,
            verticalInterval: 60, // Every hour
            getDrawingHorizontalLine: (value) {
              // The site minimum is drawn as an explicit HorizontalLine below
              // (it is rarely a multiple of the 30° grid step), so the grid
              // does not imply 30 is special.
              return FlLine(
                color: colors.border.withValues(alpha: 0.3),
                strokeWidth: 0.5,
              );
            },
            getDrawingVerticalLine: (value) {
              return FlLine(
                color: colors.border.withValues(alpha: 0.3),
                strokeWidth: 0.5,
              );
            },
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                interval: _showAirmass ? 1 : 30,
                getTitlesWidget: (value, meta) {
                  if (_showAirmass) {
                    if (value == 1 || value == 2 || value == 3 || value == 4) {
                      return Text(
                        value.toInt().toString(),
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textMuted),
                      );
                    }
                  } else {
                    if (value == 0 ||
                        value == 30 ||
                        value == 60 ||
                        value == 90) {
                      return Text(
                        '${value.toInt()}°',
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textMuted),
                      );
                    }
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 20,
                interval: 120, // Every 2 hours
                getTitlesWidget: (value, meta) {
                  final time = _startTime.add(Duration(minutes: value.toInt()));
                  return Text(
                    _siteHhmm(time),
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                  );
                },
              ),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border.all(color: colors.border.withValues(alpha: 0.5)),
          ),
          lineBarsData: [
            // Altitude curve
            if (!_showAirmass)
              LineChartBarData(
                spots: _altitudeData,
                isCurved: true,
                curveSmoothness: 0.2,
                color: colors.primary,
                barWidth: 2,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colors.primary.withValues(alpha: 0.3),
                      colors.primary.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            // Airmass curve
            if (_showAirmass && _airmassData.isNotEmpty)
              LineChartBarData(
                spots: _airmassData,
                isCurved: true,
                curveSmoothness: 0.2,
                color: colors.warning,
                barWidth: 2,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
              ),
          ],
          extraLinesData: ExtraLinesData(
            verticalLines: [
              // Current time indicator — ONLY when now actually falls inside
              // the plotted window, which is tonight's sunset→sunrise. Clamping
              // it to the edge would pin a confident "Now" line at an altitude
              // the target reaches hours later, contradicting the "Alt:"
              // readout above it. With no marker the axis times still say what
              // window is plotted, and the Alt chip remains the truth about now.
              if (nowX >= 0 && nowX <= totalMinutes)
                VerticalLine(
                  x: nowX,
                  color: colors.error,
                  strokeWidth: 1,
                  dashArray: [4, 2],
                  label: VerticalLineLabel(
                    show: true,
                    alignment: Alignment.topRight,
                    style:
                        SkotiqTypography.caption.copyWith(color: colors.error),
                    labelResolver: (_) => 'Now',
                  ),
                ),
              // Twilight markers
              if (_twilight?.astronomicalDusk != null)
                _twilightLine(
                  _twilight!.astronomicalDusk!,
                  colors.textMuted.withValues(alpha: 0.5),
                  totalMinutes,
                ),
              if (_twilight?.astronomicalDawn != null)
                _twilightLine(
                  _twilight!.astronomicalDawn!,
                  colors.textMuted.withValues(alpha: 0.5),
                  totalMinutes,
                ),
            ],
            horizontalLines: [
              // Horizon line
              if (!_showAirmass)
                HorizontalLine(
                  y: 0,
                  color: colors.error.withValues(alpha: 0.5),
                  strokeWidth: 1,
                ),
              // The SITE's minimum imaging altitude, not a hard-coded 30°.
              // This chart drew 30 while the scheduler was gating on its own
              // configured value, so the dashed line the operator reads as
              // "below this I cannot image" disagreed with the engine that
              // decides it.
              if (!_showAirmass)
                HorizontalLine(
                  y: siteMinimumAltitude,
                  color: colors.warning.withValues(alpha: 0.5),
                  strokeWidth: 1,
                  dashArray: [4, 4],
                ),
            ],
          ),
          lineTouchData: LineTouchData(
            enabled: true,
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => colors.surface,
              tooltipBorder: BorderSide(color: colors.border),
              getTooltipItems: (touchedSpots) {
                return touchedSpots.map((spot) {
                  final time =
                      _startTime.add(Duration(minutes: spot.x.toInt()));
                  final timeStr = _siteHhmm(time);
                  if (_showAirmass) {
                    return LineTooltipItem(
                      '$timeStr\nAirmass: ${spot.y.toStringAsFixed(2)}',
                      SkotiqTypography.caption
                          .copyWith(color: colors.textPrimary),
                    );
                  }
                  return LineTooltipItem(
                    '$timeStr\nAlt: ${spot.y.toStringAsFixed(1)}°',
                    SkotiqTypography.caption
                        .copyWith(color: colors.textPrimary),
                  );
                }).toList();
              },
            ),
          ),
        ),
      ),
    );
  }

  VerticalLine _twilightLine(DateTime time, Color color, double maxX) {
    final x = time.difference(_startTime).inMinutes.toDouble();
    return VerticalLine(
      x: x.clamp(0, maxX),
      color: color,
      strokeWidth: 1,
      dashArray: [2, 4],
    );
  }

  /// HH:MM as the OBSERVING SITE reads it.
  ///
  /// Only the DISPLAY moves: the rise/transit/set solve and the plotted window
  /// still run on the true instant from [AltitudeChart.nowValue], because
  /// shifting the input would skew the astronomy itself (see the doc on
  /// `nowOverride`). Every face in this widget — axis, touch tooltip and the
  /// three chips — goes through here together, so the chart can never label its
  /// axis in one zone and its chips in another.
  String _siteHhmm(DateTime t) {
    final shown = _clock.fromUtc(t.toUtc());
    return '${shown.hour.toString().padLeft(2, '0')}:'
        '${shown.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildVisibilityInfo(SkotiqColors colors) {
    final items = <Widget>[];

    if (_visibility!.riseTime != null) {
      items.add(_buildTimeChip(
        colors,
        'Rise',
        _siteHhmm(_visibility!.riseTime!),
        SkotiqIcons.sunrise,
      ));
    }

    if (_visibility!.transitTime != null) {
      items.add(_buildTimeChip(
        colors,
        'Transit',
        _siteHhmm(_visibility!.transitTime!),
        SkotiqIcons.arrowUp,
      ));
    }

    if (_visibility!.setTime != null) {
      items.add(_buildTimeChip(
        colors,
        'Set',
        _siteHhmm(_visibility!.setTime!),
        SkotiqIcons.sunset,
      ));
    }

    if (_visibility!.transitAltitude != null) {
      // Named "Transit alt", not "Max Alt": this is the altitude at
      // culmination, which happens whenever it happens - often in daylight.
      // The planner cards' "Peak" chip is a different quantity (the highest
      // altitude while the sky is actually dark), and calling this one "Max
      // Alt" made two correct numbers look like a contradiction.
      items.add(_buildTimeChip(
        colors,
        'Transit alt',
        '${_visibility!.transitAltitude!.toStringAsFixed(1)}°',
        SkotiqIcons.chevronUp,
        tooltip: 'Altitude at transit (culmination), whenever that falls - '
            'including in daylight. The planner\'s "Peak in dark" chip is the '
            'highest altitude while the sky is astronomically dark tonight.',
      ));
    }

    if (items.isEmpty) {
      // Check if circumpolar or never rises
      if (_visibility!.transitAltitude != null &&
          _visibility!.transitAltitude! > 0) {
        return Text(
          'Circumpolar - always visible',
          style: SkotiqTypography.caption.copyWith(color: colors.success),
        );
      } else {
        return Text(
          'Never rises at this location',
          style: SkotiqTypography.caption.copyWith(color: colors.error),
        );
      }
    }

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: items,
    );
  }

  Widget _buildTimeChip(
    SkotiqColors colors,
    String label,
    String value,
    IconData icon, {
    String? tooltip,
  }) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: SkotiqTokens.borderRadiusInline4,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: colors.textMuted),
          const SizedBox(width: 4),
          Text(
            '$label: ',
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
          Text(
            value,
            style: SkotiqTypography.caption.copyWith(
                color: colors.textPrimary, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
    if (tooltip == null) return chip;
    return Tooltip(message: tooltip, child: chip);
  }
}
