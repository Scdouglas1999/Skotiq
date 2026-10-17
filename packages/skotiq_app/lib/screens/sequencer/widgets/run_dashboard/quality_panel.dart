import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'hfr_sparkline.dart';

/// Run Dashboard Quality Panel (Image Grading).
///
/// Subscribes to the active backend's event stream and reads the typed
/// `FrameAccepted` / `FrameRejected` payloads produced by the typed
/// bridge dispatch (`SequencerEvent::FrameAccepted` / `FrameRejected`).
///
/// Every metric the panel needs (HFR, eccentricity, star count, reject reason,
/// consecutive-reject counter) arrives as typed data via
/// [FrameGradeEvent.fromTypedData]; nothing here parses
/// `InstructionProgress.detail` strings.
///
/// Hidden when grading is disabled in settings AND no events have arrived
/// (an idle dashboard stays clean).
///
/// The panel also surfaces the most recent sky-brightness
/// adaptive-exposure decision so the user sees live sky brightness +
/// nominal/adapted exposure pair on the dashboard.
class RunDashboardQualityPanel extends ConsumerWidget {
  const RunDashboardQualityPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final summary = ref.watch(runDashboardQualitySummaryProvider);
    final adaptive = ref.watch(runDashboardAdaptiveExposureProvider);

    // Hidden when no grading has happened yet AND no adaptive event has
    // landed — keeps an idle dashboard uncluttered. The panel auto-
    // appears the moment the Rust path emits its first event.
    if (summary.total == 0 && adaptive == null) {
      return const SizedBox.shrink();
    }
    // If only adaptive-exposure has fired (grading off / not yet
    // active), render a slim adaptive-only banner.
    if (summary.total == 0 && adaptive != null) {
      return _AdaptiveExposureBanner(event: adaptive, colors: colors);
    }

    final rejectPct = (summary.rejectRate * 100).clamp(0.0, 100.0);
    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(LucideIcons.filter, size: 14, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'IMAGE QUALITY',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: colors.textMuted,
                ),
              ),
              const Spacer(),
              Text(
                '${summary.total} graded',
                style: SkotiqTypography.withTabular(
                  SkotiqTypography.labelQuiet.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Headline: accept / reject counts + percentage.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${summary.rejected}',
                style: SkotiqTypography.telemetryLg.copyWith(
                  fontWeight: FontWeight.w700,
                  color: summary.rejected > 0
                      ? colors.warning
                      : colors.textPrimary,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              Text(
                'rejected of ${summary.total} graded',
                style: SkotiqTypography.withTabular(
                  SkotiqTypography.labelSm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
              const Spacer(),
              if (summary.total > 0)
                Text(
                  '${rejectPct.toStringAsFixed(0)}%',
                  style: SkotiqTypography.withTabular(
                    SkotiqTypography.label.copyWith(
                      fontWeight: FontWeight.w600,
                      color: summary.rejectRate > 0.2
                          ? colors.warning
                          : colors.textPrimary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),

          // Progress bar (filled = rejected fraction).
          SkotiqProgressBar(
            value: summary.rejectRate.clamp(0.0, 1.0),
            height: 4,
          ),

          if (summary.recent.isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            Divider(height: 1, color: colors.border),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Text(
              'RECENT',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            // Up to the 6 most-recent decisions, newest at the top.
            for (final event in summary.recent.reversed.take(6))
              _GradeRow(event: event, colors: colors),
          ],

          if (summary.hfrSparkline.length >= 3) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            Row(
              children: [
                Text(
                  'HFR',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: colors.textMuted,
                  ),
                ),
                const Spacer(),
                Text(
                  '${summary.hfrSparkline.reduce((a, b) => a < b ? a : b).toStringAsFixed(2)}'
                  '–${summary.hfrSparkline.reduce((a, b) => a > b ? a : b).toStringAsFixed(2)} px',
                  style: SkotiqTypography.withTabular(
                    SkotiqTypography.labelSm.copyWith(color: colors.textMuted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceXs),
            SizedBox(
              height: 40,
              child: CustomPaint(
                painter: HfrSparklinePainter(
                  values: summary.hfrSparkline,
                  accepted: summary.hfrSparklineAccepted,
                  color: colors.primary,
                  rejectColor: colors.warning,
                ),
                size: Size.infinite,
              ),
            ),
          ],
          // Adaptive-exposure status row. Embedded
          // inside the quality panel so the user has one place to look
          // for "is the rig adapting tonight?".
          if (adaptive != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            Divider(height: 1, color: colors.border),
            const SizedBox(height: SkotiqTokens.spaceMd),
            _AdaptiveExposureInline(event: adaptive, colors: colors),
          ],
        ],
      ),
    );
  }
}

/// Slim banner used when adaptive-exposure has fired
/// but no image-grading events have arrived yet (e.g. grading disabled).
class _AdaptiveExposureBanner extends StatelessWidget {
  const _AdaptiveExposureBanner({required this.event, required this.colors});

  final AdaptiveExposureEvent event;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: _AdaptiveExposureInline(event: event, colors: colors),
    );
  }
}

/// The inline body that renders the live adaptive-
/// exposure state for the quality panel.
class _AdaptiveExposureInline extends StatelessWidget {
  const _AdaptiveExposureInline({
    required this.event,
    required this.colors,
  });

  final AdaptiveExposureEvent event;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final isAdjusted = event.isNontrivialAdjustment;
    final tone = switch (event.reason) {
      AdaptiveExposureReason.clampedMin ||
      AdaptiveExposureReason.clampedMax ||
      AdaptiveExposureReason.outOfNominalBounds =>
        colors.warning,
      AdaptiveExposureReason.unavailable ||
      AdaptiveExposureReason.disabled =>
        colors.textMuted,
      AdaptiveExposureReason.adapted ||
      AdaptiveExposureReason.unknown =>
        isAdjusted ? colors.primary : colors.textPrimary,
    };
    final skyLabel = event.skyBrightnessMag != null
        ? '${event.skyBrightnessMag!.toStringAsFixed(2)} mag/arcsec²'
        : 'sky brightness unavailable';
    final filterLabel = event.filter == null ? '' : '${event.filter} · ';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(LucideIcons.lineChart, size: 14, color: tone),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Text(
              'ADAPTIVE EXPOSURE',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: colors.textMuted,
              ),
            ),
            const Spacer(),
            Text(
              event.reason.label,
              style: SkotiqTypography.labelStrongSm.copyWith(color: tone),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          '$filterLabel${event.adaptedSecs.toStringAsFixed(0)}s '
          '(nominal ${event.nominalSecs.toStringAsFixed(0)}s)',
          style: SkotiqTypography.withTabular(
            SkotiqTypography.label.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Sky brightness: $skyLabel',
          style: SkotiqTypography.withTabular(
            SkotiqTypography.labelQuiet.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _GradeRow extends StatelessWidget {
  const _GradeRow({required this.event, required this.colors});

  final FrameGradeEvent event;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final isReject = event.isReject;
    final icon = isReject ? LucideIcons.x : LucideIcons.check;
    final iconColor = isReject ? colors.warning : colors.primary;
    // The typed payload carries HFR / star count directly, so the
    // dashboard surfaces them on every row instead of swallowing them into
    // a parsed reason string.
    final metricChips = <String>[];
    if (event.hfr != null) {
      metricChips.add('HFR ${event.hfr!.toStringAsFixed(2)}');
    }
    if (event.eccentricity != null) {
      metricChips.add('ecc ${event.eccentricity!.toStringAsFixed(2)}');
    }
    if (event.starCount != null) {
      metricChips.add('${event.starCount} stars');
    }
    final metricSuffix =
        metricChips.isEmpty ? '' : '  (${metricChips.join(', ')})';
    final label = isReject
        ? 'Frame ${event.frame}: ${event.reason}$metricSuffix'
        : 'Frame ${event.frame}: accepted$metricSuffix';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 12, color: iconColor),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Provider — accumulates grading events into a per-run summary.

/// Maximum recent events retained for the dashboard. Older events scroll
/// off the bottom of the list; the totals stay accurate.
const int _kQualityRecentLimit = 50;

class _QualityNotifier extends StateNotifier<FrameGradeRunSummary> {
  _QualityNotifier(this._ref) : super(FrameGradeRunSummary.empty) {
    _wireBackendEvents();
  }

  final Ref _ref;
  StreamSubscription<SkotiqEvent>? _subscription;
  ProviderSubscription<DiagnosticsBackend>? _backendSubscription;
  int _backendGeneration = 0;

  void _wireBackendEvents() {
    void resubscribe(DiagnosticsBackend backend, {required bool clear}) {
      final generation = ++_backendGeneration;
      final previous = _subscription;
      if (clear) state = FrameGradeRunSummary.empty;
      _subscription = backend.eventStream.listen((event) {
        if (generation != _backendGeneration) return;
        _onEvent(event);
      });
      previous?.cancel();
    }

    resubscribe(_ref.read(diagnosticsBackendProvider), clear: false);
    _backendSubscription = _ref.listen<DiagnosticsBackend>(
        diagnosticsBackendProvider, (previous, next) {
      if (identical(previous, next)) return;
      // Per-run totals from host A are meaningless on host B, even when B is
      // idle and therefore emits no fresh Started event to clear them.
      resubscribe(next, clear: true);
    });
  }

  void _onEvent(SkotiqEvent event) {
    if (event.category != EventCategory.sequencer) return;
    // 'Started' resets per-run counters.
    if (event.eventType == 'Started') {
      state = FrameGradeRunSummary.empty;
      return;
    }
    // Only the typed grading variants drive the panel.
    if (event.eventType != 'FrameAccepted' &&
        event.eventType != 'FrameRejected') {
      return;
    }
    final grade = FrameGradeEvent.fromTypedData(event.eventType, event.data);
    if (grade == null) return;

    final nextRecent = List<FrameGradeEvent>.from(state.recent)..add(grade);
    if (nextRecent.length > _kQualityRecentLimit) {
      nextRecent.removeRange(0, nextRecent.length - _kQualityRecentLimit);
    }

    // The sparkline tracks ALL graded frames, rejected included. A focus
    // collapse that drives rejections is exactly the trend the user needs
    // to see — recording only accepted frames hid the evidence until
    // acceptance resumed. Rejected samples render distinctly (dots).
    final nextSparkline = List<double>.from(state.hfrSparkline);
    final nextSparklineAccepted = List<bool>.from(state.hfrSparklineAccepted);
    if (grade.hfr != null) {
      nextSparkline.add(grade.hfr!);
      nextSparklineAccepted.add(grade.decision == FrameGradeDecision.accepted);
      // Cap the sparkline to a reasonable window so memory + paint cost
      // stay bounded across long sessions.
      if (nextSparkline.length > 200) {
        nextSparkline.removeRange(0, nextSparkline.length - 200);
        nextSparklineAccepted.removeRange(
            0, nextSparklineAccepted.length - 200);
      }
    }

    // The typed event always carries the authoritative running counts.
    // No fall-back-to-local-increment branch needed.
    state = FrameGradeRunSummary(
      accepted: grade.acceptedTotal,
      rejected: grade.rejectedTotal,
      recent: nextRecent,
      hfrSparkline: nextSparkline,
      hfrSparklineAccepted: nextSparklineAccepted,
    );
  }

  @override
  void dispose() {
    _backendGeneration++;
    _subscription?.cancel();
    _backendSubscription?.close();
    super.dispose();
  }
}

/// Per-run quality summary fed by the backend event stream.
///
/// Removed the duplicate `ref.onDispose(notifier.dispose)` —
/// Riverpod's StateNotifierProvider already auto-disposes the notifier
/// when the container shuts down, so the manual hook was triggering
/// `Bad state: Tried to use _QualityNotifier after dispose was called`
/// under tests that dispose deterministically.
final runDashboardQualitySummaryProvider =
    StateNotifierProvider<_QualityNotifier, FrameGradeRunSummary>((ref) {
  return _QualityNotifier(ref);
});

// Sky-brightness adaptive exposure surface
//
// Mirrors the `_QualityNotifier` pattern: subscribe to the active backend
// event stream, watch for `ExposureAdjusted`, and expose the most recent
// decision via a StateNotifierProvider so the dashboard panel can re-paint
// without holding the backend reference itself.

class _AdaptiveExposureNotifier extends StateNotifier<AdaptiveExposureEvent?> {
  _AdaptiveExposureNotifier(this._ref) : super(null) {
    _wireBackendEvents();
  }

  final Ref _ref;
  StreamSubscription<SkotiqEvent>? _subscription;
  ProviderSubscription<DiagnosticsBackend>? _backendSubscription;
  int _backendGeneration = 0;

  void _wireBackendEvents() {
    void resubscribe(DiagnosticsBackend backend, {required bool clear}) {
      final generation = ++_backendGeneration;
      final previous = _subscription;
      if (clear) state = null;
      _subscription = backend.eventStream.listen((event) {
        if (generation != _backendGeneration) return;
        _onEvent(event);
      });
      previous?.cancel();
    }

    resubscribe(_ref.read(diagnosticsBackendProvider), clear: false);
    _backendSubscription = _ref.listen<DiagnosticsBackend>(
        diagnosticsBackendProvider, (previous, next) {
      if (identical(previous, next)) return;
      resubscribe(next, clear: true);
    });
  }

  void _onEvent(SkotiqEvent event) {
    if (event.category != EventCategory.sequencer) return;
    // 'Started' clears the last-seen value so a fresh run doesn't
    // surface a stale decision from the previous run.
    if (event.eventType == 'Started') {
      state = null;
      return;
    }
    if (event.eventType != 'ExposureAdjusted') return;
    final parsed = AdaptiveExposureEvent.fromTypedData(
      event.eventType,
      event.data,
    );
    if (parsed != null) {
      state = parsed;
    }
  }

  @override
  void dispose() {
    _backendGeneration++;
    _subscription?.cancel();
    _backendSubscription?.close();
    super.dispose();
  }
}

/// Most-recent sky-brightness adaptive exposure decision from the
/// executor, or `null` when none has been emitted in this run.
final runDashboardAdaptiveExposureProvider =
    StateNotifierProvider<_AdaptiveExposureNotifier, AdaptiveExposureEvent?>(
        (ref) {
  return _AdaptiveExposureNotifier(ref);
});
