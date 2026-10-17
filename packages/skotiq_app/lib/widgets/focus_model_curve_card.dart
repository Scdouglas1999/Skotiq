// FocusModelCurveCard — phone-friendly visualization of the temperature
// compensation focus model. Shows a scatter plot of focuser position vs HFR
// coloured by sample temperature, with the fitted temperature-vs-position
// regression line drawn over the points, the current focuser position marked
// on the X axis, and a per-filter offset chip strip below.
//
// Why a custom painter rather than fl_chart for the body: fl_chart already
// ships in the package and we use it elsewhere, but the focus-model display
// has three custom requirements that work better in a single CustomPainter:
//
//   1. Points coloured by a per-point continuous temperature value (cool blue
//      to warm orange). fl_chart's ScatterChart can colour per-point but the
//      symbol/legend story for continuous colour ramps is awkward.
//   2. A fitted line that is *not* a linear best fit through the X axis points
//      (the underlying FocusModel relates position to temperature, not HFR);
//      we project the regression onto the focus-position axis instead.
//   3. A vertical "current focuser position" marker plus a "best focus"
//      vertical line. fl_chart supports lines but adding two overlay layers
//      plus the legend chip plumbing ends up roughly the same code size as a
//      single painter.
//
// The painter is contained: only the points / curve / axes / markers; the
// surrounding chrome (status row, filter chips, action buttons) is plain
// Material/Riverpod widgets so the card composes nicely on phones.
//
// IMPORTANT: the underlying FocusModelService stores temperature-vs-position
// data points. The audit asks for an HFR-vs-position scatter plot — this is
// what the in-progress autofocus run produces (an HFR V-curve / parabola at a
// single temperature). For each persisted FocusHistoryPoint we therefore plot
// `(focusPosition, hfr)` and colour the marker by its `temperatureCelsius`.
// The fitted line is the temperature-model projection — at each focus position
// it asks "what temperature should produce this position?" via the inverse of
// position = intercept + slope * T, and the line is drawn across the full
// temperature span so the user can see drift visually. The minimum of the
// in-progress autofocus parabola lives on `autofocusOverlayProvider.vcurvePoints`;
// if an active run is happening we overlay that parabola as the "live curve"
// in addition to the model trend line.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'focuser_backlash/focuser_backlash_offer.dart';
part 'focus_model_curve_card/chart.dart';
part 'focus_model_curve_card/actions.dart';
part 'focus_model_curve_card/filter_offsets.dart';

/// Visualisation card combining a scatter plot of focus data points with the
/// fitted regression line, per-filter offsets, and the current prediction.
///
/// Set [compact] for the embedded summary preview on the camera tab — that
/// layout drops the action buttons and the offsets row and reduces the chart
/// height so it occupies ~180dp instead of the full 280dp.
class FocusModelCurveCard extends ConsumerStatefulWidget {
  /// When true, render the compact summary suitable for embedding on the
  /// camera tab. The compact card is tappable: it routes to the focus-model
  /// section within Settings. The full layout is non-tappable because it is
  /// already the expanded destination.
  final bool compact;

  /// When non-null, tapping the card body invokes this callback instead of
  /// the default GoRouter navigation. Tests use this to assert tap-to-navigate
  /// without spinning up a router.
  final VoidCallback? onOpenFullScreen;

  const FocusModelCurveCard({
    super.key,
    this.compact = false,
    this.onOpenFullScreen,
  });

  @override
  ConsumerState<FocusModelCurveCard> createState() =>
      _FocusModelCurveCardState();
}

class _FocusModelCurveCardState extends ConsumerState<FocusModelCurveCard> {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final focuserState = ref.watch(focuserStateProvider);
    final activeProfile = ref.watch(activeEquipmentProfileProvider);

    if (activeProfile == null) {
      return _frame(
        colors,
        child: const EmptyState.compact(
          icon: LucideIcons.userCog,
          title: 'No active equipment profile',
          body: 'Select or create a profile in Equipment to view the focus '
              'model.',
        ),
      );
    }

    final profileId = activeProfile.id.toString();
    if (focuserState.connectionState != DeviceConnectionState.connected) {
      return _frame(
        colors,
        child: const EmptyState.compact(
          icon: LucideIcons.focus,
          title: 'Focuser not connected',
          body: 'Connect a focuser from the Devices tab to start collecting '
              'focus-model data.',
        ),
      );
    }

    final profileData = ref.watch(focusProfileDataProvider(profileId));
    return profileData.when(
      data: (data) => _buildProfileData(
        context: context,
        colors: colors,
        focuserState: focuserState,
        profileId: profileId,
        profileData: data,
      ),
      loading: () => _frame(
        colors,
        child: const EmptyState.compact(
          icon: LucideIcons.loader,
          title: 'Loading focus model',
          body: 'Reading autofocus history from the imaging host…',
        ),
      ),
      error: (_, __) => _frame(
        colors,
        child: const EmptyState.compact(
          icon: LucideIcons.alertTriangle,
          title: 'Could not load focus model',
          body: 'Pull down to refresh the Devices tab and try again.',
        ),
      ),
    );
  }

  Widget _buildProfileData({
    required BuildContext context,
    required SkotiqColors colors,
    required FocuserState focuserState,
    required String profileId,
    required ProfileFocusData? profileData,
  }) {
    final model = profileData?.temperatureModel;
    final dataPoints = profileData?.dataPoints ?? const <FocusHistoryPoint>[];

    if (dataPoints.isEmpty) {
      return _frame(
        colors,
        child: _EmptyDataState(
          compact: widget.compact,
          onRunAutofocus: () => _runAutofocus(context, ref),
        ),
      );
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusRow(
          focuserState: focuserState,
          model: model,
          dataPoints: dataPoints,
          colors: colors,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: widget.compact ? 140 : 220,
          child: _HfrScatterChart(
            points: dataPoints,
            model: model,
            currentPosition: focuserState.position,
            colors: colors,
          ),
        ),
        if (!widget.compact) ...[
          const SizedBox(height: 8),
          _TemperatureLegend(points: dataPoints, colors: colors),
          const SizedBox(height: 12),
          _ActionRow(
            profileId: profileId,
            focuserState: focuserState,
            colors: colors,
            onChanged: () {
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 12),
          _PredictiveAfRow(colors: colors),
          _FilterOffsetsStrip(
            profileId: profileId,
            colors: colors,
          ),
        ],
      ],
    );

    if (widget.compact) {
      // Tappable summary preview on the camera tab.
      final router = GoRouter.maybeOf(context);
      final onOpenFullScreen = widget.onOpenFullScreen;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
          // `focus-model` is a supported Settings alias for the merged
          // Autofocus section. If this package is embedded without a router or
          // callback, leave the InkWell honestly disabled.
          onTap: onOpenFullScreen ??
              (router == null
                  ? null
                  : () => router.go('/settings?section=focus-model')),
          child: _frame(colors, child: content),
        ),
      );
    }
    return _frame(colors, child: content);
  }

  Widget _frame(SkotiqColors colors, {required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      ),
      child: child,
    );
  }

  Future<void> _runAutofocus(BuildContext context, WidgetRef ref) async {
    // The one shared backlash offer (`focuser_backlash_offer.dart`), so the
    // empty state's "Run autofocus" makes the same offer as the focuser strip
    // and the imaging focus panel. Declining continues straight into the run.
    await offerBacklashCalibrationIfDue(context, ref);
    if (!context.mounted) return;

    // We delegate to DeviceService.runAutofocus rather than calling the
    // backend autofocusStart endpoint directly: DeviceService resolves the
    // user's persisted afExposureTime / afStepSize / afInitialOffsetSteps
    // from appSettings, so a "Run autofocus" tap from the empty state
    // behaves identically to the autofocus action elsewhere in the app.
    try {
      final deviceService = ref.read(deviceServiceProvider);
      final messenger = ScaffoldMessenger.of(context);
      // Fire and forget — DeviceService owns the overlay/result lifecycle and
      // the card will rebuild when the new focus sample is persisted.
      // We don't await here because autofocus runs for minutes and we
      // want the empty-state button tap to feel snappy.
      // Settings defaults are read inside runAutofocus().
      unawaited(
        deviceService
            .runAutofocus(
          exposureTime: 3.0,
          stepSize: 50,
          stepsOut: 5,
          useSettingsDefaults: true,
        )
            .then<void>((_) {
          if (messenger.mounted) {
            messenger.showSnackBar(
              const SnackBar(content: Text('Autofocus complete')),
            );
          }
        }).onError<AutofocusCancelledException>((_, __) {
          if (messenger.mounted) {
            messenger.showSnackBar(
              const SnackBar(content: Text('Autofocus cancelled')),
            );
          }
        }).catchError((Object e, StackTrace st) {
          if (messenger.mounted) {
            messenger.showSnackBar(
              SnackBar(content: Text('Autofocus failed: $e')),
            );
          }
        }),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Autofocus started')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start autofocus: $e')),
        );
      }
    }
  }
}

class _StatusRow extends StatelessWidget {
  final FocuserState focuserState;
  final FocusModel? model;
  final List<FocusHistoryPoint> dataPoints;
  final SkotiqColors colors;

  const _StatusRow({
    required this.focuserState,
    required this.model,
    required this.dataPoints,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final temp = focuserState.temperature ??
        (dataPoints.isNotEmpty ? dataPoints.last.temperatureCelsius : null);
    final position = focuserState.position;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _MetricCell(
            icon: LucideIcons.thermometer,
            label: 'Temp',
            value: temp != null ? '${temp.toStringAsFixed(1)} °C' : '—',
            colors: colors,
          ),
        ),
        Expanded(
          child: _MetricCell(
            icon: LucideIcons.focus,
            label: 'Position',
            value: position?.toString() ?? '—',
            colors: colors,
          ),
        ),
        Expanded(
          child: _ModelStatus(
              model: model, dataPoints: dataPoints, colors: colors),
        ),
      ],
    );
  }
}

class _MetricCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final SkotiqColors colors;

  const _MetricCell({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 12, color: colors.textMuted),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(fontSize: 10, color: colors.textMuted)),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _ModelStatus extends StatelessWidget {
  final FocusModel? model;
  final List<FocusHistoryPoint> dataPoints;
  final SkotiqColors colors;

  const _ModelStatus({
    required this.model,
    required this.dataPoints,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    if (model == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.info, size: 12, color: colors.textMuted),
              const SizedBox(width: 4),
              Text('Model',
                  style: TextStyle(fontSize: 10, color: colors.textMuted)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            dataPoints.isEmpty ? 'No data' : 'Building…',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.warning,
            ),
          ),
        ],
      );
    }

    final quality = model!.rSquared;
    final color = quality >= 0.9
        ? colors.success
        : quality >= 0.7
            ? colors.success
            : quality >= 0.5
                ? colors.warning
                : colors.error;
    final label = quality >= 0.9
        ? 'Excellent'
        : quality >= 0.7
            ? 'Good'
            : quality >= 0.5
                ? 'Fair'
                : 'Poor';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.activity, size: 12, color: colors.textMuted),
            const SizedBox(width: 4),
            Text('Model',
                style: TextStyle(fontSize: 10, color: colors.textMuted)),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          // Why include R² in this single label: phone widths can't fit two
          // separate cells for "quality" and "R²"; combining them keeps the
          // information density high without truncation.
          '$label · R²=${quality.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// Empty-state body shown when no focus data has been collected. The expanded
/// card offers autofocus directly; the compact card opens autofocus settings.
class _EmptyDataState extends StatelessWidget {
  final bool compact;
  final VoidCallback onRunAutofocus;
  const _EmptyDataState({required this.compact, required this.onRunAutofocus});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    if (compact) {
      return Row(
        children: [
          Icon(LucideIcons.activity, size: 16, color: colors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'No focus data yet — tap for autofocus settings',
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
          Icon(LucideIcons.chevronRight, size: 14, color: colors.textMuted),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.activity, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Text(
              'Focus model',
              style: TextStyle(
                fontSize: 14,
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              children: [
                Icon(LucideIcons.barChart, size: 48, color: colors.textMuted),
                const SizedBox(height: 12),
                Text(
                  'No focus data yet',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Run an autofocus to start building the temperature '
                  'compensation curve.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
                const SizedBox(height: 16),
                SkotiqButton(
                  label: 'Run autofocus',
                  icon: LucideIcons.zap,
                  onPressed: onRunAutofocus,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
