// Phone-friendly diagnostic card surfacing PHD2 guide health at a glance.
//
// Why this exists: the companion DevicesTab showed total RMS as a single
// line of text, which gives no sense of whether guiding is trending or
// spiking, and the shared GuidingScreen full chart is cramped at 390pt
// width. The card lives in skotiq_app (not skotiq_ui) because it
// subscribes to Riverpod providers and the backend event stream — it's
// not a pure visual primitive.
//
// Subscriptions:
//   * guiderStateProvider     -> connection + device name + isGuiding/isCalibrating
//   * phd2StateProvider       -> textual state label (Guiding, Lost Star, etc.)
//   * guideStatsProvider      -> rolling RA/Dec/Total RMS (pixels; PHD2's
//                                RADistanceRaw/AvgDist. Shown in arcsec only
//                                when a pixel scale is known, else "px".)
//   * starLostEventProvider   -> drives the "Lost star" banner
//   * backend.eventStream     -> raw GuideStep events feed the sparkline ring
//
// The sparkline ring buffer lives in widget state (not a provider) so the
// data does not survive route changes or hot-restarts. That avoids stale
// samples leaking across sessions when the same PHD2 connection produced
// different statistics. Capacity = 200 samples (â‰ˆ3 minutes at PHD2's ~1Hz
// step rate).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Compact (~120dp tall) phone-friendly guide-health diagnostic card.
///
/// Renders:
///   * RMS badge (large numeric "0.62"") + traffic-light colour
///   * State chip ("Guiding" / "Calibrating" / "Lost Star" / "Disconnected")
///   * Guider device name
///   * Sparkline of total RMS over the last ~3 minutes
///   * RA RMS / Dec RMS bottom row
///   * "Details" button → `/guiding`
class GuideHealthCard extends ConsumerStatefulWidget {
  /// When non-null, replaces the default "navigate to /guiding" Details
  /// affordance. The shared GuidingScreen mounts the card and doesn't need
  /// a "go to me" button, so it passes a null handler to suppress it.
  final VoidCallback? onDetails;

  /// When false, suppresses the Details button entirely. Use when the card
  /// is already on the full GuidingScreen.
  final bool showDetails;

  const GuideHealthCard({
    super.key,
    this.onDetails,
    this.showDetails = true,
  });

  @override
  ConsumerState<GuideHealthCard> createState() => _GuideHealthCardState();
}

class _GuideHealthCardState extends ConsumerState<GuideHealthCard> {
  /// Fixed-capacity ring buffer of total-RMS samples (arcsec). We use a
  /// plain `List<double>` and trim the head when we cross [_capacity] —
  /// `dart:collection`'s `Queue` would work but iterating it inside the
  /// CustomPainter twice per frame allocates more than a List slice.
  static const int _capacity = 200;
  final List<double> _samples = <double>[];

  StreamSubscription<SkotiqEvent>? _eventSub;
  ProviderSubscription<DiagnosticsBackend>? _backendSub;
  int _backendGeneration = 0;

  @override
  void initState() {
    super.initState();
    _bindEvents();
  }

  void _bindEvents() {
    _bindEventStream(ref.read(diagnosticsBackendProvider), clear: false);
    // Why also listen for backend swap: when the mobile companion connects
    // to a remote rig, `backendProvider` flips from DisconnectedBackend to
    // NetworkBackend mid-session. We re-bind so the subscription points at
    // the new stream.
    _backendSub = ref.listenManual<DiagnosticsBackend>(
        diagnosticsBackendProvider, (previous, next) {
      if (!mounted) return;
      if (identical(previous, next)) return;
      _bindEventStream(next, clear: true);
    });
  }

  void _bindEventStream(DiagnosticsBackend backend, {required bool clear}) {
    final generation = ++_backendGeneration;
    final previous = _eventSub;
    if (clear && _samples.isNotEmpty) setState(_samples.clear);
    _eventSub = backend.eventStream.listen((event) {
      if (generation != _backendGeneration) return;
      _onEvent(event);
    });
    previous?.cancel();
  }

  void _onEvent(SkotiqEvent event) {
    if (!mounted) return;
    if (event.category != EventCategory.guiding) return;
    if (event.eventType == 'GuidingStopped' ||
        event.eventType == 'Disconnected') {
      // Why clear: PHD2 stops emitting useful RMS and the trailing chart
      // would otherwise freeze on the last value, falsely implying the
      // rig is still tracking that error magnitude.
      if (_samples.isNotEmpty) {
        setState(_samples.clear);
      }
      return;
    }
    if (event.eventType != 'GuideStep') return;

    // Extract the same fields the production GuideGraphNotifier uses; total
    // RMS is sqrt(ra^2 + dec^2) of the *raw* per-step residuals so the
    // sparkline captures instantaneous error (not the rolling RMS that
    // guideStatsProvider exposes).
    final raRaw = _doubleField(event.data, ['RADistanceRaw', 'raPx']);
    final decRaw = _doubleField(event.data, ['DECDistanceRaw', 'decPx']);
    final total = math.sqrt(raRaw * raRaw + decRaw * decRaw);

    setState(() {
      _samples.add(total);
      if (_samples.length > _capacity) {
        _samples.removeRange(0, _samples.length - _capacity);
      }
    });
  }

  double _doubleField(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final raw = data[key];
      if (raw is num) return raw.toDouble();
    }
    return 0.0;
  }

  @override
  void dispose() {
    _backendGeneration++;
    _eventSub?.cancel();
    _backendSub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final guiderState = ref.watch(guiderStateProvider);
    final phd2State = ref.watch(phd2StateProvider);
    final stats = ref.watch(guideStatsProvider);
    final isConnected =
        guiderState.connectionState == DeviceConnectionState.connected;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: !isConnected
          ? _buildDisconnectedState(context, colors)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTopRow(context, colors, guiderState, phd2State, stats),
                if (phd2State == Phd2State.lostLock)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _StatusBanner(
                      icon: LucideIcons.alertTriangle,
                      message: 'Lost star — guiding paused',
                      tint: colors.error,
                    ),
                  )
                else if (phd2State == Phd2State.calibrating)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _StatusBanner(
                      icon: LucideIcons.gauge,
                      message: 'Calibrating — settle expected shortly',
                      tint: colors.warning,
                    ),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 40,
                  child: _Sparkline(
                    samples: _samples,
                    primary: colors.primary,
                    grid: colors.border,
                    axisLabel: colors.textMuted,
                  ),
                ),
                const SizedBox(height: 6),
                _buildBottomRow(colors, stats),
              ],
            ),
    );
  }

  Widget _buildTopRow(
    BuildContext context,
    SkotiqColors colors,
    GuiderState guiderState,
    Phd2State phd2State,
    Phd2GuideStats stats,
  ) {
    final readout = _rmsReadout(stats.rmsTotal, stats.pixelScale);
    final rmsColor = _rmsColor(readout.value, phd2State, colors);
    final rmsText = phd2State == Phd2State.guiding && stats.frameCount > 0
        ? readout.value.toStringAsFixed(2)
        : '—';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Large RMS badge — single source of "how bad is it right now".
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Total RMS',
              style: TextStyle(
                fontSize: 10,
                color: colors.textMuted,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  rmsText,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: rmsColor,
                    fontFamily: 'monospace',
                    height: 1.0,
                  ),
                ),
                if (rmsText != '—')
                  Text(
                    readout.unit,
                    style: TextStyle(
                      fontSize: 14,
                      color: rmsColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(width: 12),
        // State chip + guider name (stacked).
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _StateChip(state: phd2State, colors: colors),
              const SizedBox(height: 4),
              Text(
                guiderState.deviceName ?? 'PHD2',
                style: TextStyle(
                  fontSize: 11,
                  color: colors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (widget.showDetails)
          TextButton.icon(
            icon: Icon(LucideIcons.chevronRight,
                size: 14, color: colors.textSecondary),
            label: Text(
              'Details',
              style: TextStyle(
                fontSize: 12,
                color: colors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
            onPressed: widget.onDetails ?? () => _openGuidingDetails(context),
          ),
      ],
    );
  }

  Widget _buildBottomRow(SkotiqColors colors, Phd2GuideStats stats) {
    final ra = _rmsReadout(stats.rmsRa, stats.pixelScale);
    final dec = _rmsReadout(stats.rmsDec, stats.pixelScale);
    return Row(
      children: [
        _AxisChip(label: 'RA', value: ra.value, unit: ra.unit, colors: colors),
        const SizedBox(width: 8),
        _AxisChip(
            label: 'Dec', value: dec.value, unit: dec.unit, colors: colors),
        const Spacer(),
        Text(
          '3 min',
          style: TextStyle(
            fontSize: 10,
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _buildDisconnectedState(BuildContext context, SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(LucideIcons.unplug, size: 16, color: colors.textMuted),
            const SizedBox(width: 8),
            Text(
              'PHD2 not connected',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Connect a guider to see live RMS and the 3-minute trend.',
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 10),
        SkotiqButton(
          label: 'Connect',
          icon: LucideIcons.plug,
          size: ButtonSize.small,
          variant: ButtonVariant.outline,
          onPressed: () => _openEquipment(context),
        ),
      ],
    );
  }

  void _openGuidingDetails(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/guiding');
    }
  }

  void _openEquipment(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/equipment');
    }
  }

  /// Colour mapping for the RMS value:
  ///   < 0.8"   -> success (green)
  ///   < 1.5"   -> warning (amber)
  ///   >= 1.5"  -> error (red)
  ///
  /// When PHD2 is not actively guiding we render in muted grey to make it
  /// obvious the number is stale.
  /// PHD2 reports guide residuals in pixels (RADistanceRaw/AvgDist). When a
  /// pixel scale (arcsec/px) is known we present arcseconds; otherwise we show
  /// the raw pixel value labelled "px" rather than mislabelling it as arcsec.
  ({double value, String unit}) _rmsReadout(double raw, double pixelScale) {
    if (pixelScale > 0) return (value: raw * pixelScale, unit: '"');
    return (value: raw, unit: ' px');
  }

  Color _rmsColor(double rms, Phd2State state, SkotiqColors colors) {
    if (state != Phd2State.guiding) return colors.textMuted;
    if (rms < 0.8) return colors.success;
    if (rms < 1.5) return colors.warning;
    return colors.error;
  }
}

class _StateChip extends StatelessWidget {
  final Phd2State state;
  final SkotiqColors colors;

  const _StateChip({required this.state, required this.colors});

  @override
  Widget build(BuildContext context) {
    final (label, tint) = _styleFor(state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: SkotiqDecorations.tintedBadge(
        tint,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tint,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: tint,
            ),
          ),
        ],
      ),
    );
  }

  (String, Color) _styleFor(Phd2State state) {
    switch (state) {
      case Phd2State.guiding:
        return ('Guiding', colors.success);
      case Phd2State.calibrating:
        return ('Calibrating', colors.warning);
      case Phd2State.lostLock:
        return ('Lost Star', colors.error);
      case Phd2State.looping:
        return ('Looping', colors.warning);
      case Phd2State.paused:
        return ('Paused', colors.info);
      case Phd2State.settling:
        return ('Settling', colors.info);
      case Phd2State.stopped:
        return ('Stopped', colors.textMuted);
      case Phd2State.unknown:
        return ('Unknown', colors.warning);
      default:
        return ('Disconnected', colors.textMuted);
    }
  }
}

class _AxisChip extends StatelessWidget {
  final String label;
  final double value;
  final String unit;
  final SkotiqColors colors;

  const _AxisChip({
    required this.label,
    required this.value,
    required this.unit,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: TextStyle(fontSize: 10, color: colors.textMuted),
          ),
          Text(
            '${value.toStringAsFixed(2)}$unit',
            style: TextStyle(
              fontSize: 11,
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final IconData icon;
  final String message;
  final Color tint;

  const _StatusBanner({
    required this.icon,
    required this.message,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: SkotiqDecorations.emphasisSurface(
        tint,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: tint,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// CustomPainter-backed sparkline. We bypass fl_chart because the card is
/// rebuilt on every guide step (~1Hz) and fl_chart's full layout pass is
/// overkill for a 200-point single-line chart with no axes/labels.
class _Sparkline extends StatelessWidget {
  final List<double> samples;
  final Color primary;
  final Color grid;
  final Color axisLabel;

  const _Sparkline({
    required this.samples,
    required this.primary,
    required this.grid,
    required this.axisLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (samples.length < 2) {
      return Center(
        child: Text(
          samples.isEmpty
              ? 'Waiting for guide steps…'
              : 'Need at least two samples for trend',
          style: TextStyle(
            fontSize: 11,
            color: axisLabel,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    return CustomPaint(
      size: Size.infinite,
      painter: _SparklinePainter(
        samples: List<double>.unmodifiable(samples),
        line: primary,
        grid: grid,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> samples;
  final Color line;
  final Color grid;

  _SparklinePainter({
    required this.samples,
    required this.line,
    required this.grid,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = samples.length;
    if (n < 2 || size.width <= 0 || size.height <= 0) return;

    // Find min/max but bias the visible scale so a perfect "all zeros"
    // doesn't crash the divisor. A lower bound of 0 keeps the chart
    // anchored — negative RMS is impossible by definition.
    double maxVal = samples[0];
    for (final v in samples) {
      if (v > maxVal) maxVal = v;
    }
    // Anchor a sane upper bound so a single spike doesn't squash the
    // baseline to a flat line. We pad by 20% so the peak isn't hugging
    // the top edge.
    final yScale = (maxVal * 1.2).clamp(0.5, double.infinity);

    final gridPaint = Paint()
      ..color = grid.withValues(alpha: 0.5)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    // Two horizontal reference lines: midline + top.
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      gridPaint,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      gridPaint,
    );

    final linePaint = Paint()
      ..color = line
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          line.withValues(alpha: 0.25),
          line.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final path = Path();
    final fillPath = Path();
    final dx = size.width / (n - 1);
    for (var i = 0; i < n; i++) {
      final x = dx * i;
      // Clamp to handle anomalous extreme samples (e.g. a stale "1e9
      // arcsec" entry written by a bug we haven't fixed yet).
      final normalized = (samples[i] / yScale).clamp(0.0, 1.0);
      final y = size.height - (normalized * size.height);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);

    // Latest-sample marker so the eye picks up the freshest value.
    final lastX = dx * (n - 1);
    final lastY =
        size.height - (samples.last / yScale).clamp(0.0, 1.0) * size.height;
    canvas.drawCircle(
      Offset(lastX, lastY),
      2.0,
      Paint()
        ..color = line
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) {
    // List identity is stable per paint because the caller passes
    // an UnmodifiableListView snapshot rebuilt every setState.
    if (identical(old.samples, samples)) return false;
    if (old.samples.length != samples.length) return true;
    if (old.line != line || old.grid != grid) return true;
    // Cheap reference equality on the last element is enough — when a new
    // sample arrives the list reference changed already.
    return true;
  }
}
