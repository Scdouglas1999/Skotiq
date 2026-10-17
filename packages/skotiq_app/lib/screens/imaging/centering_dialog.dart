import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../utils/snackbar_helper.dart';
import '../../utils/authority_bound_dialog.dart';
import '../../widgets/plate_solver_required_banner.dart';

part 'centering_dialog/image_canvas.dart';
part 'centering_dialog/presentation.dart';

part 'centering_dialog/section_builders.dart';

/// Dialog for automated target centering with live image preview
class CenteringDialog extends ConsumerStatefulWidget {
  final double? targetRa;
  final double? targetDec;
  final String? targetName;
  final ValueChanged<CenteringResult?>? onClose;

  const CenteringDialog({
    super.key,
    this.targetRa,
    this.targetDec,
    this.targetName,
    this.onClose,
  });

  @override
  ConsumerState<CenteringDialog> createState() => _CenteringDialogState();
}

class _CenteringDialogState extends ConsumerState<CenteringDialog> {
  bool _isCentering = false;
  bool _isMinimized = false;
  // Latched while CenteringService.stop() is in flight so the user can't
  // double-click Abort and queue up two abortMountSlew calls.
  bool _abortInFlight = false;
  CenteringResult? _result;
  // Set when `_startCentering` detects no plate solver is configured.
  // Drives the inline `PlateSolverRequiredBanner` — the centering dialog
  // catches `SolverNotAvailableError` from `PlateSolveService` rather than
  // letting it surface as a generic snackbar.
  String? _solverMissingMessage;
  // Inline validation error for the "Solve exposure" field. Set when Start is
  // pressed with a blank, unparseable, non-finite, or out-of-bounds entry;
  // cleared when the user edits the field or a run starts. Its presence is
  // what keeps a bad entry from silently firing a fallback exposure.
  String? _exposureError;
  late final TextEditingController _exposureController;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next) || !mounted) return;
        if (widget.onClose != null) {
          widget.onClose!(null);
        } else {
          closeAuthorityBoundDialog(context);
        }
      },
    );
    final profile = ref.read(activeEquipmentProfileProvider);
    final defaultExposure = profile?.defaultCenteringExposure ?? 5.0;
    _exposureController = TextEditingController(
      text: defaultExposure.toString(),
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    _exposureController.dispose();
    super.dispose();
  }

  /// Canonical safe bounds for the "Solve exposure" field, in seconds.
  ///
  /// These mirror the headless centering endpoint (`POST /framing/center`,
  /// which validates `exposureTime` with `min: 0.01, max: 600`) so the same
  /// value is accepted or rejected whether centering is driven from this
  /// dialog or over the headless API. Do not invent tighter/looser limits here
  /// without changing both call sites in lockstep.
  static const double _minExposureSeconds = 0.01;
  static const double _maxExposureSeconds = 600.0;

  /// Centering convergence tolerance in arcseconds. A fixed constant, kept out
  /// of the (user-editable) exposure field so the live offset bar can reference
  /// it during a run without reparsing — and never mixed up with the exposure.
  static const double _toleranceArcsec = 30.0;

  /// Parse the "Solve exposure" field into a finite exposure in seconds inside
  /// the canonical [`_minExposureSeconds`, `_maxExposureSeconds`] bounds.
  ///
  /// Returns null and surfaces an inline [_exposureError] when the entry is
  /// blank, unparseable, non-finite (NaN/Infinity), or out of range. This
  /// deliberately does NOT fall back to a default: pressing Start with a bad
  /// value must fail visibly rather than silently issue a fixed-length exposure
  /// the user never requested.
  double? _parseValidExposureSeconds() {
    final raw = _exposureController.text.trim();
    if (raw.isEmpty) {
      _setExposureError('Enter a solve exposure between $_minExposureSeconds '
          'and ${_maxExposureSeconds.toStringAsFixed(0)} s.');
      return null;
    }
    final parsed = double.tryParse(raw);
    if (parsed == null || !parsed.isFinite) {
      _setExposureError('Solve exposure must be a number in seconds.');
      return null;
    }
    if (parsed < _minExposureSeconds || parsed > _maxExposureSeconds) {
      _setExposureError('Solve exposure must be between $_minExposureSeconds '
          'and ${_maxExposureSeconds.toStringAsFixed(0)} s.');
      return null;
    }
    return parsed;
  }

  void _setExposureError(String message) {
    setState(() => _exposureError = message);
  }

  /// Build the centering config from an already-validated [exposureTime]. The
  /// caller is responsible for validating the exposure via
  /// [_parseValidExposureSeconds] first; this method never substitutes a
  /// default for a bad value.
  /// Settings this run depends on (solver path/timeout plus the centering mount
  /// sync), awaited rather than read cold: a run started before the provider
  /// resolves would silently use an empty solver path and the built-in
  /// defaults instead of the operator's configuration.
  Future<AppSettingsState?> _resolvedAppSettings() async {
    try {
      return await ref.read(appSettingsProvider.future);
    } catch (_) {
      return ref.read(appSettingsProvider).valueOrNull;
    }
  }

  CenteringConfig _buildCenteringConfig(
    double exposureTime,
    AppSettingsState? settings,
  ) {
    final profile = ref.read(activeEquipmentProfileProvider);
    return CenteringConfig(
      maxIterations: 5,
      toleranceArcsec: _toleranceArcsec,
      exposureTime: exposureTime,
      binning: profile?.defaultBinX ?? 2,
      gain: profile?.defaultGain,
      offset: profile?.defaultOffset,
      // Settings → Plate Solving → "Sync mount when centering". Without the
      // sync each correction re-issues the slew that produced the mis-pointed
      // frame, so the offset never changes and the run ends on max iterations.
      syncMount: settings?.centeringSyncMount ?? true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final centeringStatus = ref.watch(centeringStatusProvider);
    if (_isMinimized) {
      return _buildMinimized(centeringStatus, context.skotiqColors);
    }
    final currentImage = ref.watch(currentImageProvider);
    final theme = Theme.of(context);
    final colors = context.skotiqColors;
    final sideBySide = MediaQuery.sizeOf(context).width >= 760;

    // Dismissal must not abandon a running operation; minimizing keeps it mounted.
    final isWideLayout = _isCentering ||
        _result != null ||
        centeringStatus.iterationHistory.isNotEmpty;

    final dialog = PopScope(
      canPop: !_isCentering,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        child: ConstrainedBox(
          constraints: Responsive.dialogConstraints(
            context,
            preferredWidth: isWideLayout ? 900 : 600,
            maxWidthPercent: 0.95,
            maxHeightPercent: 0.85,
            minWidth: 320,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            width: double.infinity,
            padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 600 ? 16 : 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                _buildHeader(theme, colors),
                const SizedBox(height: 16),

                // Plate-solver missing banner. Surfaced when
                // `_startCentering` catches `SolverNotAvailableError`
                // before kicking off the centering loop. The banner exposes
                // a "Set up plate solver" CTA that go_routes to
                // /settings/plate-solving — clicking it pops this dialog and
                // hands the user off to the dedicated setup page.
                if (_solverMissingMessage != null) ...[
                  PlateSolverRequiredBanner(
                    contextMessage: _solverMissingMessage,
                    onBeforeNavigate: widget.onClose == null ? null : _close,
                  ),
                  const SizedBox(height: 16),
                ],

                // Main content area
                if (_isCentering ||
                    _result != null ||
                    centeringStatus.iterationHistory.isNotEmpty)
                  Flexible(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Left: Image preview
                        if (sideBySide &&
                            currentImage != null &&
                            (_isCentering || _result != null))
                          Expanded(
                            flex: 1,
                            child:
                                _buildImagePreview(currentImage, colors, theme),
                          ),
                        if (sideBySide &&
                            currentImage != null &&
                            (_isCentering || _result != null))
                          const SizedBox(width: 16),

                        // Right: Status and info
                        Expanded(
                          flex: 1,
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (!sideBySide && currentImage != null) ...[
                                  _buildImagePreview(
                                      currentImage, colors, theme),
                                  const SizedBox(height: 12),
                                ],
                                // Coordinates
                                if (widget.targetRa != null &&
                                    widget.targetDec != null)
                                  _buildCoordinatesCompact(
                                      centeringStatus, colors, theme),

                                if (widget.targetRa != null &&
                                    widget.targetDec != null)
                                  const SizedBox(height: 12),

                                // Exposure settings
                                _buildExposureSettings(colors, theme),
                                const SizedBox(height: 12),

                                // Status section
                                if (_isCentering)
                                  _buildStatusSection(centeringStatus, colors),

                                // Result section
                                if (_result != null && !_isCentering)
                                  _buildResultSection(_result!, colors),

                                // Iteration history
                                if (centeringStatus
                                    .iterationHistory.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  _buildIterationHistory(
                                      centeringStatus.iterationHistory, colors),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else ...[
                  // Pre-centering: simple vertical layout
                  if (widget.targetRa != null && widget.targetDec != null) ...[
                    _buildCoordinatesCompact(centeringStatus, colors, theme),
                    const SizedBox(height: 16),
                  ],
                  _buildExposureSettings(colors, theme),
                ],

                const SizedBox(height: 16),

                // Action buttons
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (_isCentering)
                      SkotiqButton(
                        label: 'Abort',
                        icon: LucideIcons.octagon,
                        onPressed: _abortInFlight ? null : _abortCentering,
                        isLoading: _abortInFlight,
                        variant: ButtonVariant.destructive,
                      )
                    else ...[
                      SkotiqButton(
                        label: 'Close',
                        onPressed: _close,
                        variant: ButtonVariant.outline,
                      ),
                      SkotiqButton(
                        label: 'Start centering',
                        icon: SkotiqIcons.target,
                        onPressed: _startCentering,
                        variant: ButtonVariant.primary,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.onClose == null) return dialog;
    return Stack(children: [
      const ModalBarrier(dismissible: false, color: Colors.black54),
      FocusScope(
        autofocus: true,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape):
                _isCentering ? _minimize : _close,
          },
          child: Focus(autofocus: true, child: dialog),
        ),
      ),
    ]);
  }

  Widget _buildStatusSection(CenteringStatus status, SkotiqColors colors) {
    final theme = Theme.of(context);

    String stateText;
    IconData stateIcon;
    Color stateColor;

    switch (status.state) {
      case CenteringState.exposing:
        stateText = 'Capturing...';
        stateIcon = SkotiqIcons.camera;
        stateColor = colors.accent;
        break;
      case CenteringState.solving:
        stateText = 'Plate solving...';
        stateIcon = SkotiqIcons.sparkle;
        stateColor = colors.accent;
        break;
      case CenteringState.slewing:
        stateText = 'Correcting...';
        stateIcon = LucideIcons.moveHorizontal;
        stateColor = colors.accent;
        break;
      case CenteringState.verifying:
        stateText = 'Verifying...';
        stateIcon = SkotiqIcons.success;
        stateColor = colors.accent;
        break;
      case CenteringState.completed:
        stateText = 'Centered!';
        stateIcon = SkotiqIcons.success;
        stateColor = colors.success;
        break;
      case CenteringState.error:
        stateText = 'Error';
        stateIcon = LucideIcons.alertCircle;
        stateColor = colors.error;
        break;
      default:
        stateText = 'Ready';
        stateIcon = SkotiqIcons.circle;
        stateColor = colors.textMuted;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: SkotiqDecorations.statusChip(
        stateColor,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(stateIcon, color: stateColor, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  stateText,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: stateColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${status.currentIteration}/${status.maxIterations}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                  fontFeatures: [const FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (status.currentOffsetArcmin != null) ...[
            const SizedBox(height: 8),
            // Offset bar
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                    child: LinearProgressIndicator(
                      value: (status.currentOffsetArcsec! / _toleranceArcsec)
                              .clamp(0.0, 2.0) /
                          2.0,
                      backgroundColor: colors.surfaceAlt,
                      color: status.currentOffsetArcsec! <= _toleranceArcsec
                          ? colors.success
                          : colors.accent,
                      minHeight: 6,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${status.currentOffsetArcmin!.toStringAsFixed(2)}\'',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontFeatures: [const FontFeature.tabularFigures()],
                    color: status.currentOffsetArcsec! <= _toleranceArcsec
                        ? colors.success
                        : colors.textPrimary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // Abort path: latch _abortInFlight so the button disables immediately and
  // a second tap can't queue a duplicate stop() (which would also issue a
  // duplicate abortMountSlew). The centering loop's own _abortRequested
  // poll surfaces the cancellation as a CenteringResult.failure('Aborted by
  // user'), which _startCentering's normal completion path renders.
  Future<void> _abortCentering() async {
    setState(() => _abortInFlight = true);
    try {
      await ref.read(centeringServiceProvider).stop();
    } catch (e) {
      // Surface the failure rather than swallow it: a silent abort failure
      // leaves the mount slewing after the user thinks they aborted.
      if (mounted) {
        context.showErrorSnackBar('Abort failed: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _abortInFlight = false);
      }
    }
  }

  Future<void> _startCentering() async {
    // Double-submit / in-flight guard. `_isCentering` is set synchronously
    // below before the first `await`, so a second tap that lands before the
    // button rebuilds away (rapid double-click) is rejected here rather than
    // kicking off a second centering run — and a second throwaway exposure.
    if (_isCentering) return;

    if (widget.targetRa == null || widget.targetDec == null) {
      if (mounted) {
        context.showErrorSnackBar('No target coordinates specified');
      }
      return;
    }

    // Validate the user's typed exposure BEFORE any solver detection, camera
    // work, or a misleading "running" state. A blank, unparseable, non-finite,
    // or out-of-bounds entry surfaces an inline error, keeps the typed text
    // editable, and does no work — it must never silently fall back to a
    // default and fire an exposure the user did not request.
    final exposureTime = _parseValidExposureSeconds();
    if (exposureTime == null) return;

    setState(() {
      _isCentering = true;
      _result = null;
      _solverMissingMessage = null;
      _exposureError = null;
    });

    final centeringService = ref.read(centeringServiceProvider);

    // Pre-flight the user's actual selection (including ASTAP's catalog), not
    // merely whether any solver happens to be installed.
    final solveService = ref.read(plateSolveServiceProvider);
    try {
      await solveService.ensureSolverAvailable();
    } on SolverNotAvailableError catch (e) {
      if (mounted) {
        setState(() {
          _isCentering = false;
          _solverMissingMessage = e.message;
        });
      }
      return;
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCentering = false;
          _solverMissingMessage = 'Plate-solver detection failed: $e';
        });
      }
      return;
    }

    final appSettings = await _resolvedAppSettings();
    if (!mounted) return;
    final solverConfig = PlateSolverConfig(
      type: PlateSolverType.astap,
      executablePath: appSettings?.astapPath ?? '',
      timeoutSeconds: appSettings?.plateSolveTimeout ?? 60,
      searchRadius: appSettings?.plateSolveSearchRadius,
    );

    try {
      final result = await centeringService.centerOnTarget(
        targetRa: widget.targetRa!,
        targetDec: widget.targetDec!,
        solverConfig: solverConfig,
        config: _buildCenteringConfig(exposureTime, appSettings),
        onStatusUpdate: (status) {
          if (mounted) {
            ref.read(centeringStatusProvider.notifier).state = status;
          }
        },
      );

      if (mounted) {
        setState(() {
          _result = result;
          _isCentering = false;
        });

        ref.read(lastCenteringResultProvider.notifier).state = result;
      }
    } on SolverNotAvailableError catch (e) {
      // Path the centering service can throw if a deeper layer surfaces
      // the missing-solver case after we already passed our pre-flight.
      // Render the same banner rather than a generic snackbar.
      if (mounted) {
        setState(() {
          _isCentering = false;
          _solverMissingMessage = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = CenteringResult.failure(
            errorMessage: 'Centering error: $e',
            iterations: 0,
            iterationHistory: [],
          );
          _isCentering = false;
        });

        context.showErrorSnackBar('Centering failed: $e');
      }
    }
  }

  String _formatRa(double raHours) =>
      CoordinateFormat.ra(raHours, seconds: SecondsPrecision.oneDecimalPadded);

  String _formatDec(double decDegrees) => CoordinateFormat.dec(
        decDegrees,
        seconds: SecondsPrecision.oneDecimalPadded,
      );
}
