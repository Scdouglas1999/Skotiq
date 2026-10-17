import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/shell/shell_chrome.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Non-blocking autofocus progress overlay that sits at the bottom-right
/// of the screen and shows live V-curve data as autofocus runs.
///
/// This overlay does not block interaction with the rest of the app.
/// It can be minimized, dragged, and dismissed.
///
/// The ONE live focus V-curve surface in the app. Driven by
/// [autofocusOverlayProvider] (which assembles state from the
/// `AutofocusProgress` event stream) and mounted once in `app_shell.dart`, so
/// it floats above whatever screen is active for the duration of a run.
///
/// To show focus data inline on a screen, reuse this overlay and its provider;
/// do not fork a second V-curve chart, which would drift in behaviour and
/// double the event wiring.
///
/// The chart itself now lives in `skotiq_ui` as [VCurvePainter] /
/// [VCurveChart], parameterised over a list of series so the focuser backlash
/// calibration can draw its two approach curves on shared axes through the
/// same code. Anything that needs a V-curve takes it from there.
class AutofocusProgressOverlay extends ConsumerStatefulWidget {
  const AutofocusProgressOverlay({super.key});

  @override
  ConsumerState<AutofocusProgressOverlay> createState() =>
      _AutofocusProgressOverlayState();
}

class _AutofocusProgressOverlayState
    extends ConsumerState<AutofocusProgressOverlay>
    with SingleTickerProviderStateMixin {
  // Drag offset from bottom-right corner (dy clamped to shell chrome in build).
  Offset _offset = const Offset(16, 16);
  bool _offsetInitialized = false;
  late AnimationController _pulseController;

  static const double _expandedWidth = 360.0;
  static const double _expandedHeight = 320.0;
  static const double _minimizedWidth = 200.0;
  static const double _minimizedHeight = 40.0;

  @override
  void initState() {
    super.initState();
    // NOT started here. This overlay is mounted once in the app shell, so it is
    // alive on EVERY screen for the whole session and its State is never
    // disposed. Repeating unconditionally keeps a ticker scheduling a frame on
    // every vsync forever — the app never idles and every screen runs at a
    // degraded framerate — to animate an icon that is only ever built while an
    // autofocus run is in progress. The pulse is started/stopped in build()
    // from the real run state, matching _SequenceIndicator in the status bar.
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_offsetInitialized) return;
    _offsetInitialized = true;
    final useBottomNav =
        ShellChrome.useBottomNavigation(MediaQuery.sizeOf(context).width);
    _offset = Offset(
      16,
      ShellChromeMetrics.floatingOverlayBottomInset(
        context,
        useBottomNav: useBottomNav,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final overlayState = ref.watch(autofocusOverlayProvider);

    // Only pulse while the overlay is actually on screen showing a live run;
    // otherwise hold the controller still so a shell-mounted, invisible overlay
    // does not schedule a frame every vsync for the life of the app.
    if (overlayState.isVisible && overlayState.isRunning) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else if (_pulseController.isAnimating) {
      _pulseController.stop();
    }

    if (!overlayState.isVisible) {
      return const SizedBox.shrink();
    }

    final colors = SkotiqColors.of(context);
    final isMinimized = overlayState.isMinimized;

    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxWidth = math.max(0.0, screenWidth - 16);
    final width =
        math.min(isMinimized ? _minimizedWidth : _expandedWidth, maxWidth);
    final height = isMinimized ? _minimizedHeight : _expandedHeight;
    final useBottomNav =
        ShellChrome.useBottomNavigation(MediaQuery.sizeOf(context).width);
    final minBottomInset = ShellChromeMetrics.floatingOverlayBottomInset(
      context,
      useBottomNav: useBottomNav,
      margin: 0,
    );

    return Positioned(
      right: _offset.dx,
      bottom: _offset.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          final screenSize = MediaQuery.sizeOf(context);
          // Drag range, floored against its own start: a short viewport (the
          // overlay plus the bottom-nav inset taller than the screen) would
          // otherwise invert these bounds and throw out of the drag handler.
          final maxDx = math.max(0.0, screenSize.width - width);
          final maxDy = math.max(minBottomInset, screenSize.height - height);
          setState(() {
            _offset = Offset(
              (_offset.dx - details.delta.dx).clamp(0, maxDx),
              (_offset.dy - details.delta.dy).clamp(minBottomInset, maxDy),
            );
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
            border: Border.all(
              color: overlayState.isRunning
                  ? colors.primary.withValues(alpha: 0.6)
                  : colors.border,
              width: overlayState.isRunning ? 2 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: isMinimized
              ? _buildMinimized(colors, overlayState)
              : _buildExpanded(colors, overlayState),
        ),
      ),
    );
  }

  Widget _buildMinimized(
      SkotiqColors colors, AutofocusOverlayState overlayState) {
    return Material(
      color: Colors.transparent,
      // The tap lived on a bare gesture wrapper, which publishes an action
      // and no role, so assistive tech read a live control as an inert
      // disabled panel. The flags are only published when given.
      child: Semantics(
          button: true,
          enabled: true,
          child: InkWell(
            onTap: () =>
                ref.read(autofocusOverlayProvider.notifier).toggleMinimized(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  if (overlayState.isRunning)
                    AnimatedBuilder(
                      animation: _pulseController,
                      builder: (context, child) {
                        return Icon(
                          LucideIcons.focus,
                          size: 16,
                          color: Color.lerp(
                            colors.primary,
                            colors.primary.withValues(alpha: 0.4),
                            _pulseController.value,
                          ),
                        );
                      },
                    )
                  else
                    Icon(
                      LucideIcons.focus,
                      size: 16,
                      color: overlayState.result != null
                          ? colors.success
                          : colors.textMuted,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      overlayState.isRunning
                          ? 'AF: ${overlayState.currentPoint}/${overlayState.totalPoints}'
                          : (overlayState.result != null
                              ? 'AF: HFR ${overlayState.result!.bestHfr.toStringAsFixed(2)}'
                              : 'AF: ${overlayState.status}'),
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _buildCloseButton(colors, overlayState),
                ],
              ),
            ),
          )),
    );
  }

  Widget _buildExpanded(
      SkotiqColors colors, AutofocusOverlayState overlayState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title bar
        _buildTitleBar(colors, overlayState),

        // V-curve chart area
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Container(
              decoration: BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              ),
              child: overlayState.vcurvePoints.isEmpty
                  ? Center(
                      child: overlayState.isRunning
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor:
                                        AlwaysStoppedAnimation(colors.primary),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Waiting for data...',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colors.textMuted,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              'No data',
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.textMuted,
                              ),
                            ),
                    )
                  : CustomPaint(
                      // The shared V-curve painter (skotiq_ui). One series,
                      // the run accent, best sampled point ringed in success.
                      painter: VCurvePainter(
                        series: [
                          VCurveSeries(
                            points: overlayState.vcurvePoints,
                            color: colors.primary,
                            label: 'Autofocus',
                            vertexPosition: overlayState.result?.bestPosition,
                            vertexColor: colors.success,
                            highlightLatest: overlayState.isRunning,
                          ),
                        ],
                        focusRange: overlayState.focusRange,
                        gridColor: colors.border,
                        textColor: colors.textMuted,
                        repaintTick: overlayState.currentPoint,
                      ),
                      size: Size.infinite,
                    ),
            ),
          ),
        ),

        // Stats row
        _buildStatsRow(colors, overlayState),

        // Progress bar (only while running)
        if (overlayState.isRunning && overlayState.totalPoints > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: LinearProgressIndicator(
              value: overlayState.currentPoint / overlayState.totalPoints,
              backgroundColor: colors.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(colors.primary),
              minHeight: 3,
            ),
          ),

        // Status line
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            overlayState.status,
            style: TextStyle(
              fontSize: 10,
              color: overlayState.hasError ? colors.error : colors.textMuted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildTitleBar(
      SkotiqColors colors, AutofocusOverlayState overlayState) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        border: Border(
          bottom: BorderSide(color: colors.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          if (overlayState.isRunning)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(colors.primary),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                LucideIcons.focus,
                size: 14,
                color: overlayState.result != null
                    ? colors.success
                    : colors.textMuted,
              ),
            ),
          Text(
            'Autofocus',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const Spacer(),
          // Minimize button
          _buildIconButton(
            icon: LucideIcons.minus,
            tooltip: 'Minimize',
            onPressed: () =>
                ref.read(autofocusOverlayProvider.notifier).toggleMinimized(),
            colors: colors,
          ),
          const SizedBox(width: 2),
          // Close button
          _buildCloseButton(colors, overlayState),
        ],
      ),
    );
  }

  Widget _buildStatsRow(
      SkotiqColors colors, AutofocusOverlayState overlayState) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          _StatBadge(
            label: 'Point',
            value: overlayState.totalPoints > 0
                ? '${overlayState.currentPoint}/${overlayState.totalPoints}'
                : '--',
            colors: colors,
          ),
          const SizedBox(width: 8),
          _StatBadge(
            label: 'HFR',
            value: overlayState.currentHfr > 0
                ? overlayState.currentHfr.toStringAsFixed(2)
                : '--',
            colors: colors,
          ),
          const SizedBox(width: 8),
          _StatBadge(
            label: 'Best',
            value: overlayState.bestHfr > 0
                ? overlayState.bestHfr.toStringAsFixed(2)
                : '--',
            colors: colors,
            highlight: true,
          ),
          const SizedBox(width: 8),
          _StatBadge(
            label: 'Stars',
            value:
                overlayState.starCount > 0 ? '${overlayState.starCount}' : '--',
            colors: colors,
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onPressed,
    required SkotiqColors colors,
    String? tooltip,
  }) {
    final button = Material(
      color: Colors.transparent,
      // The tap lived on a bare gesture wrapper, which publishes an action
      // and no role, so assistive tech read a live control as an inert
      // disabled panel. The flags are only published when given.
      child: Semantics(
          button: true,
          enabled: true,
          label: tooltip,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            child: SizedBox(
              width: 24,
              height: 24,
              child: Icon(icon, size: 14, color: colors.textMuted),
            ),
          )),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }

  Widget _buildCloseButton(
    SkotiqColors colors,
    AutofocusOverlayState overlayState,
  ) {
    if (overlayState.isRunning) {
      return _buildIconButton(
        icon: LucideIcons.square,
        tooltip: 'Cancel autofocus',
        onPressed: () {
          unawaited(
            ref.read(deviceServiceProvider).cancelAutofocus().catchError((
              Object error,
            ) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not cancel autofocus: $error')),
                );
              }
            }),
          );
        },
        colors: colors,
      );
    }
    return _buildIconButton(
      icon: LucideIcons.x,
      tooltip: 'Dismiss',
      onPressed: () => ref.read(autofocusOverlayProvider.notifier).dismiss(),
      colors: colors,
    );
  }
}

class _StatBadge extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;
  final bool highlight;

  const _StatBadge({
    required this.label,
    required this.value,
    required this.colors,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: highlight
            ? SkotiqDecorations.emphasisSurface(
                colors.primary,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              )
            : BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                color: colors.textMuted,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: highlight ? colors.primary : colors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
