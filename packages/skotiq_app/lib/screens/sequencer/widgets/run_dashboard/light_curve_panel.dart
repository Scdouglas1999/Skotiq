// Run-dashboard live light-curve panel for the
// SciencePhotometryNode.
//
// Data flow:
//   Rust executor emits ProgressDetail::PhotometryFrame for each frame
//     -> Dart science_processing_service writes a row to
//        photometry_measurements (one per (object, timestamp))
//     -> Drift stream in sessionPhotometryProvider fires
//     -> sessionLightCurveProvider rebuilds a per-target LightCurvePoint
//        list, which this panel renders as a magnitude-vs-time chart.
//
// The panel mounts only when a SciencePhotometryNode has executed at
// least one frame in the current run. Visibility is driven by a small
// notifier (`lightCurveActivityProvider`) that watches the typed run-event
// stream and binds the photometry SequencerEvent variants
// (PhotometryFrame / PhotometryCadenceBroken / PhotometrySummary) to remember
// the last Science Photometry target / filter / cadence-break counter.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The typed `SkotiqEvent` union (and its `EventPayload_*` arms) carries the
// photometry SequencerEvent variants this panel binds to. It collides by name
// with the wire/JSON event model the barrel above keeps canonical, so it is
// imported from the core's dedicated typed-event seam under the `ns_events`
// prefix. The non-colliding `EventPayload_Sequencer` arm is reachable
// unprefixed off the barrel.
import 'package:skotiq_core/skotiq_core_events.dart' as ns_events;
import 'package:skotiq_ui/skotiq_ui.dart';

class LightCurvePanel extends ConsumerWidget {
  const LightCurvePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final session = ref.watch(sessionStateProvider);
    final activity = ref.watch(lightCurveActivityProvider);

    // Visibility rule: hide until we've seen a Science Photometry event
    // in this run. After the first frame the panel sticks around for
    // the rest of the run so the operator can still review the curve
    // once the burst has finished.
    if (!activity.hasSeenPhotometry) {
      return const SizedBox.shrink();
    }

    final sessionId = session.dbSessionId;
    if (sessionId == null) {
      return _buildShell(
        colors,
        child: _emptyState(
          'No active session yet — waiting for the executor to '
          'announce a Photometry burst.',
        ),
      );
    }

    final targetDesignation = activity.lastTargetDesignation;
    if (targetDesignation == null || targetDesignation.isEmpty) {
      return _buildShell(
        colors,
        child: _emptyState(
          'Capture a few photometry frames to build a light curve.',
        ),
      );
    }

    final points = ref.watch(
      sessionLightCurveProvider((sessionId, targetDesignation)),
    );

    return _buildShell(
      colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            colors: colors,
            target: targetDesignation,
            filter: activity.lastFilter,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          if (points.isEmpty)
            _emptyState(
              'Frames captured but the science pipeline has not yet '
              'written photometry rows.',
            )
          else ...[
            _SummaryRow(
              colors: colors,
              points: points,
              cadenceBreaks: activity.cadenceBreaks,
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            SizedBox(
              height: 140,
              child: CustomPaint(
                painter: _LightCurvePainter(
                  points: points,
                  primary: colors.primary,
                  axis: colors.border,
                  text: colors.textMuted,
                ),
                size: Size.infinite,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SkotiqButton(
                  label: 'View in Science',
                  icon: LucideIcons.arrowRight,
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  onPressed: () => context.go('/science'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildShell(SkotiqColors colors, {required Widget child}) {
    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: child,
    );
  }

  Widget _emptyState(String message) {
    return EmptyState.compact(
      icon: LucideIcons.lineChart,
      title: 'No light curve yet',
      body: message,
    );
  }
}

// Header / summary widgets

class _Header extends StatelessWidget {
  const _Header({
    required this.colors,
    required this.target,
    required this.filter,
  });

  final SkotiqColors colors;
  final String target;
  final String? filter;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(LucideIcons.lineChart, size: 14, color: colors.primary),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Text(
          'LIGHT CURVE',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: colors.textMuted,
          ),
        ),
        const Spacer(),
        Text(
          filter == null ? target : '$target · $filter',
          style: SkotiqTypography.labelStrongSm
              .copyWith(color: colors.textPrimary),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.colors,
    required this.points,
    required this.cadenceBreaks,
  });

  final SkotiqColors colors;
  final List<LightCurvePoint> points;
  final int cadenceBreaks;

  @override
  Widget build(BuildContext context) {
    final latest = points.last;
    final mag = latest.differentialMagnitude;
    final snr = latest.snr;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        _Metric(label: 'frames', value: '${points.length}', colors: colors),
        const SizedBox(width: SkotiqTokens.spaceLg),
        _Metric(
          label: 'Δmag',
          value: mag == 0 ? '—' : mag.toStringAsFixed(3),
          colors: colors,
        ),
        const SizedBox(width: SkotiqTokens.spaceLg),
        _Metric(
          label: 'snr',
          value: snr == 0 ? '—' : snr.toStringAsFixed(0),
          colors: colors,
        ),
        const Spacer(),
        if (cadenceBreaks > 0)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm,
              vertical: 3,
            ),
            decoration: SkotiqDecorations.statusChip(
              colors.warning,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
              bordered: false,
            ),
            child: Text(
              '$cadenceBreaks cadence break${cadenceBreaks == 1 ? '' : 's'}',
              style: SkotiqTypography.labelStrongSm
                  .copyWith(color: colors.warning),
            ),
          ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.colors,
  });

  final String label;
  final String value;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: colors.textMuted,
          ),
        ),
        Text(
          value,
          style: SkotiqTypography.withTabular(
            SkotiqTypography.h4.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
              height: 1.1,
            ),
          ),
        ),
      ],
    );
  }
}

// Painter — magnitude (Δmag) vs time

class _LightCurvePainter extends CustomPainter {
  _LightCurvePainter({
    required this.points,
    required this.primary,
    required this.axis,
    required this.text,
  });

  final List<LightCurvePoint> points;
  final Color primary;
  final Color axis;
  final Color text;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final sorted = [...points]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final tStart = sorted.first.timestamp.millisecondsSinceEpoch.toDouble();
    final tEnd = sorted.last.timestamp.millisecondsSinceEpoch.toDouble();
    final tSpan = (tEnd - tStart).abs() < 1 ? 1.0 : tEnd - tStart;

    // Magnitude axis: plot diff-mag when present, else instrumental
    // magnitude derived from flux (Pogson: -2.5 log10(flux)). If flux
    // is zero we plot the raw value so the chart still shows something
    // rather than silently dropping the frame.
    final values = <double>[];
    for (final p in sorted) {
      if (p.differentialMagnitude != 0) {
        values.add(p.differentialMagnitude);
      } else if (p.flux > 0) {
        values.add(-2.5 * (math.log(p.flux) / math.ln10));
      } else {
        values.add(p.flux);
      }
    }
    final yMin = values.reduce((a, b) => a < b ? a : b);
    final yMax = values.reduce((a, b) => a > b ? a : b);
    final ySpan = (yMax - yMin).abs() < 1e-6 ? 1.0 : (yMax - yMin);

    final axisPaint = Paint()
      ..color = axis
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    // Y-axis (left), X-axis (bottom).
    canvas.drawLine(Offset.zero, Offset(0, size.height), axisPaint);
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      axisPaint,
    );

    // Min/max magnitude labels. Magnitudes are conventionally plotted
    // with smaller (brighter) values at the top; the painter inverts y
    // accordingly so the chart reads like a published light curve.
    _paintText(canvas, yMin.toStringAsFixed(2), const Offset(4, 2), text);
    _paintText(
      canvas,
      yMax.toStringAsFixed(2),
      Offset(4, size.height - 14),
      text,
    );

    if (sorted.length == 1) {
      // Single point → draw a dot centered horizontally.
      final v = values.first;
      final yNorm = (v - yMin) / ySpan;
      final y = (1.0 - yNorm) * size.height;
      canvas.drawCircle(
        Offset(size.width / 2, y),
        3.0,
        Paint()..color = primary,
      );
      return;
    }

    final linePaint = Paint()
      ..color = primary
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()..color = primary;

    final path = Path();
    for (var i = 0; i < sorted.length; i++) {
      final p = sorted[i];
      final tNorm = (p.timestamp.millisecondsSinceEpoch - tStart) / tSpan;
      // Inverted axis (1 - yNorm): brighter mags higher on the canvas.
      final yNorm = (values[i] - yMin) / ySpan;
      final x = tNorm * size.width;
      final y = (1.0 - yNorm) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      canvas.drawCircle(Offset(x, y), 2.0, dotPaint);
    }
    canvas.drawPath(path, linePaint);
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: SkotiqTypography.withTabular(
          TextStyle(fontSize: SkotiqTypography.fontSize9, color: color),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _LightCurvePainter old) {
    if (old.points.length != points.length) return true;
    if (identical(old.points, points)) return false;
    if (old.points.isEmpty || points.isEmpty) return true;
    return old.points.last.timestamp != points.last.timestamp;
  }
}

// Activity provider — listens for science photometry executor events

/// Snapshot of what the light-curve panel knows about the currently-
/// executing (or most recently executed) photometry node in this run.
class LightCurveActivity {
  final bool hasSeenPhotometry;
  final String? lastTargetDesignation;
  final String? lastFilter;
  final int framesCaptured;
  final int cadenceBreaks;
  final DateTime? lastFrameAt;

  const LightCurveActivity({
    this.hasSeenPhotometry = false,
    this.lastTargetDesignation,
    this.lastFilter,
    this.framesCaptured = 0,
    this.cadenceBreaks = 0,
    this.lastFrameAt,
  });

  LightCurveActivity copyWith({
    bool? hasSeenPhotometry,
    String? lastTargetDesignation,
    String? lastFilter,
    int? framesCaptured,
    int? cadenceBreaks,
    DateTime? lastFrameAt,
  }) {
    return LightCurveActivity(
      hasSeenPhotometry: hasSeenPhotometry ?? this.hasSeenPhotometry,
      lastTargetDesignation:
          lastTargetDesignation ?? this.lastTargetDesignation,
      lastFilter: lastFilter ?? this.lastFilter,
      framesCaptured: framesCaptured ?? this.framesCaptured,
      cadenceBreaks: cadenceBreaks ?? this.cadenceBreaks,
      lastFrameAt: lastFrameAt ?? this.lastFrameAt,
    );
  }

  static const empty = LightCurveActivity();
}

/// Subscribes to the typed run-event stream ([skotiqEventsProvider]) and
/// observes the photometry [ns_events.SequencerEvent] variants emitted by the
/// Science Photometry node: `PhotometryFrame`, `PhotometryCadenceBroken`, and
/// `PhotometrySummary`. Every field this panel needs — target designation,
/// filter, and the authoritative cadence-break counter — survives the FRB
/// boundary as typed data, so there is no detail-string parsing here. The chart
/// proper subscribes separately to the Drift-backed `sessionPhotometryProvider`
/// for the actual measurements.
class _LightCurveActivityNotifier extends StateNotifier<LightCurveActivity> {
  _LightCurveActivityNotifier(this._ref) : super(LightCurveActivity.empty) {
    _wire();
  }

  final Ref _ref;
  ProviderSubscription<AsyncValue<ns_events.SkotiqEvent>>? _subscription;

  void _wire() {
    // Listening to the typed StreamProvider keeps us aligned with the
    // sibling Run Dashboard panels (scheduler / trigger feed) that read the
    // same typed surface, and it transparently follows backend swaps
    // (FFI <-> network) without manual resubscription.
    _subscription = _ref.listen<AsyncValue<ns_events.SkotiqEvent>>(
      skotiqEventsProvider,
      (_, next) => next.whenData(_onEvent),
    );
  }

  void _onEvent(ns_events.SkotiqEvent event) {
    final payload = event.payload;
    if (payload is! EventPayload_Sequencer) return;
    final sequencer = payload.field0;

    // Match on the concrete variant classes re-exported through the core seam.
    // (The freezed `whenOrNull` pattern helpers live in an extension the seam
    // does not re-export, so we destructure the variants directly.) Each branch
    // reads typed fields straight off the variant — no detail-string parsing.

    if (sequencer is SequencerEvent_Started) {
      // New run — reset state so a fresh sequence doesn't render the previous
      // run's curve.
      state = LightCurveActivity.empty;
      return;
    }

    if (sequencer is SequencerEvent_PhotometryFrame) {
      // Graceful fallback: an empty designation / filter on the wire keeps the
      // previously-observed value rather than clobbering it with a blank.
      final target = sequencer.targetDesignation.trim();
      final filter = sequencer.filter.trim();
      state = state.copyWith(
        hasSeenPhotometry: true,
        lastTargetDesignation:
            target.isEmpty ? state.lastTargetDesignation : target,
        lastFilter: filter.isEmpty ? state.lastFilter : filter,
        framesCaptured: state.framesCaptured + 1,
        lastFrameAt: DateTime.now(),
      );
      return;
    }

    if (sequencer is SequencerEvent_PhotometryCadenceBroken) {
      // `cadenceBreaks` is the executor's authoritative running count, so we
      // assign it directly rather than incrementing locally.
      state = state.copyWith(
        cadenceBreaks: sequencer.cadenceBreaks,
        lastFrameAt: DateTime.now(),
      );
      return;
    }

    if (sequencer is SequencerEvent_PhotometrySummary) {
      // Burst complete — keep the activity surface live (panel stays visible)
      // and reconcile the target / filter / break counter with the summary's
      // authoritative values, falling back to the last-observed values when a
      // field is absent.
      final target = sequencer.targetDesignation.trim();
      final filter = sequencer.filter.trim();
      state = state.copyWith(
        hasSeenPhotometry: true,
        lastTargetDesignation:
            target.isEmpty ? state.lastTargetDesignation : target,
        lastFilter: filter.isEmpty ? state.lastFilter : filter,
        cadenceBreaks: sequencer.cadenceBreaks,
        lastFrameAt: DateTime.now(),
      );
      return;
    }
  }

  @override
  void dispose() {
    _subscription?.close();
    super.dispose();
  }
}

/// Most-recent Science Photometry executor activity for the current run.
///
/// The light-curve panel watches this provider to decide whether to
/// render itself, and uses the target / filter values to look up the
/// authoritative DB-backed light-curve point list.
final lightCurveActivityProvider =
    StateNotifierProvider<_LightCurveActivityNotifier, LightCurveActivity>(
        (ref) {
  return _LightCurveActivityNotifier(ref);
});
