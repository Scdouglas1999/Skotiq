import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/shell/shell_chrome.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'polar_alignment_activity.dart';
import 'polar_alignment_error_format.dart';
import '../../utils/snackbar_helper.dart';
import '../../router/app_routes.dart';

/// A live polar alignment run, floating over every screen but its own.
///
/// A run started from the API or from a linked window used to show on this
/// window only as lines in the log: the frame, the step and the error lived
/// on the polar alignment screen alone. Mounted once in the app shell, this
/// shows the latest frame, what the run is doing and, while adjusting, which
/// way to turn the bolts, wherever the operator is, with the way into the
/// full view and a Stop. On a linked window it reads the same mirrored run.
class PolarAlignmentRunOverlay extends ConsumerStatefulWidget {
  const PolarAlignmentRunOverlay({super.key});

  @override
  ConsumerState<PolarAlignmentRunOverlay> createState() =>
      _PolarAlignmentRunOverlayState();
}

class _PolarAlignmentRunOverlayState
    extends ConsumerState<PolarAlignmentRunOverlay> {
  static const double _width = 320;
  static const double _margin = 16;

  bool _minimized = false;
  bool _stopping = false;

  /// How far the operator has dragged the card from its corner.
  Offset _drag = Offset.zero;

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    try {
      await ref.read(polarAlignmentControllerProvider).stop();
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar(
            'Could not stop polar alignment: ${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(polarAlignmentStateProvider);
    final summary = polarRunSummary(state);
    if (summary == null) {
      // A new run opens expanded again, in its corner.
      _minimized = false;
      _drag = Offset.zero;
      return const SizedBox.shrink();
    }

    final colors = SkotiqColors.of(context);
    final screen = MediaQuery.sizeOf(context);
    final useBottomNav = ShellChrome.useBottomNavigation(screen.width);
    final bottom = ShellChromeMetrics.floatingOverlayBottomInset(
      context,
      useBottomNav: useBottomNav,
    );
    final width = math.min(_width, math.max(0.0, screen.width - 2 * _margin));
    // Bottom right, where the autofocus card also floats; draggable, so it can
    // be moved off whatever it covers on a given screen.
    final right = (_margin - _drag.dx)
        .clamp(0.0, math.max(0.0, screen.width - width))
        .toDouble();
    final lift = (bottom - _drag.dy)
        .clamp(bottom, math.max(bottom, screen.height - 120))
        .toDouble();

    return Positioned(
      right: right,
      bottom: lift,
      width: width,
      child: GestureDetector(
        onPanUpdate: (details) => setState(() => _drag += details.delta),
        child: Semantics(
          container: true,
          label: 'Polar alignment running',
          child: Material(
            color: colors.surface,
            elevation: 6,
            shadowColor: ImageOverlayColors.shadow,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
            clipBehavior: Clip.antiAlias,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                border: Border.all(
                  color: colors.primary.withValues(alpha: 0.6),
                ),
              ),
              child: _minimized
                  ? _buildMinimized(colors, summary)
                  : _buildExpanded(context, colors, state, summary, screen),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(SkotiqColors colors, String summary, {required bool min}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Icon(SkotiqIcons.compass, size: 16, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              min ? 'Polar alignment · $summary' : 'Polar alignment',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SkotiqIconButton(
            icon: min ? SkotiqIcons.chevronUp : SkotiqIcons.chevronDown,
            tooltip: min ? 'Show the alignment' : 'Minimize',
            onPressed: () => setState(() => _minimized = !min),
          ),
        ],
      ),
    );
  }

  Widget _buildMinimized(SkotiqColors colors, String summary) =>
      _buildTitle(colors, summary, min: true);

  Widget _buildExpanded(
    BuildContext context,
    SkotiqColors colors,
    PolarAlignmentState state,
    String summary,
    Size screen,
  ) {
    final error = state.currentError;
    // Short windows get a shorter frame so the card stays on screen.
    final frameHeight = screen.height < 600 ? 120.0 : 180.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTitle(colors, summary, min: false),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            height: frameHeight,
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              border: Border.all(color: colors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: state.hasImage
                ? Image.memory(
                    state.imageData!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  )
                : Center(
                    child: Text(
                      'Waiting for the first frame',
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.textMuted),
                    ),
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Text(
            summary,
            style: SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
          ),
        ),
        if (state.phase == PolarAlignPhase.adjusting && error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
            child: Text(
              'Azimuth ${error.azimuthAdjustment} '
              '${formatPolarError(error.azimuthError.abs())} · '
              'Altitude ${error.altitudeAdjustment} '
              '${formatPolarError(error.altitudeError.abs())}',
              style:
                  SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: SkotiqButton(
                  label: 'Open alignment',
                  size: ButtonSize.small,
                  onPressed: () => context.push(AppRoute.polarAlignment.path),
                ),
              ),
              const SizedBox(width: 8),
              SkotiqButton(
                label: _stopping ? 'Stopping' : 'Stop',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                isLoading: _stopping,
                onPressed: _stopping ? null : () => unawaited(_stop()),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
