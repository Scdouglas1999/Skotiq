import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/help/field_help_copy.dart';
import '../../../widgets/help/field_help_label.dart';
import 'panel_widgets.dart';

part 'guiding_panel_parts/_builtin_guider_config.dart';
part 'guiding_panel_parts/_guide_graph_and_stars.dart';

class GuidingPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const GuidingPanel({super.key, required this.colors});

  @override
  ConsumerState<GuidingPanel> createState() => _GuidingPanelState();
}

class _GuidingPanelState extends ConsumerState<GuidingPanel> {
  // UI-only transient state (doesn't need to persist)
  bool _isStartingGuiding = false;
  bool _isDithering = false;
  bool _configExpanded = false;
  ProviderSubscription<DeviceService>? _serviceSubscription;

  @override
  void initState() {
    super.initState();
    _serviceSubscription = ref.listenManual<DeviceService>(
      deviceServiceProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        if (mounted) {
          setState(() {
            _isStartingGuiding = false;
            _isDithering = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _serviceSubscription?.close();
    super.dispose();
  }

  Future<void> _startGuiding() async {
    if (_isStartingGuiding) return;
    final deviceService = ref.read(deviceServiceProvider);
    setState(() => _isStartingGuiding = true);
    final ditherSettings = ref.read(ditherSettingsProvider);
    try {
      await deviceService.startGuiding(
        settlePixels: ditherSettings.settlePixels,
        settleTime: ditherSettings.settleTime,
      );
      if (_isCurrentService(deviceService)) {
        ref.read(sessionStateProvider.notifier).setGuiding(true);
      }
    } catch (e) {
      if (mounted && _isCurrentService(deviceService)) {
        context.showErrorSnackBar('Failed to start guiding: $e');
      }
    } finally {
      if (_isCurrentService(deviceService)) {
        setState(() => _isStartingGuiding = false);
      }
    }
  }

  Future<void> _stopGuiding() async {
    final deviceService = ref.read(deviceServiceProvider);
    try {
      await deviceService.stopGuiding();
      if (_isCurrentService(deviceService)) {
        ref.read(sessionStateProvider.notifier).setGuiding(false);
      }
    } catch (e) {
      if (mounted && _isCurrentService(deviceService)) {
        context.showErrorSnackBar('Failed to stop guiding: $e');
      }
    }
  }

  Future<void> _dither() async {
    if (_isDithering) return;
    final deviceService = ref.read(deviceServiceProvider);
    setState(() => _isDithering = true);
    ref.read(sessionStateProvider.notifier).setDithering(true);
    final ditherSettings = ref.read(ditherSettingsProvider);
    try {
      await deviceService.dither(
        amount: ditherSettings.ditherAmount,
        settlePixels: ditherSettings.settlePixels,
        settleTime: ditherSettings.settleTime,
      );
    } catch (e) {
      if (mounted && _isCurrentService(deviceService)) {
        context.showErrorSnackBar('Dither failed: $e');
      }
    } finally {
      if (_isCurrentService(deviceService)) {
        setState(() => _isDithering = false);
        ref.read(sessionStateProvider.notifier).setDithering(false);
      }
    }
  }

  bool _isCurrentService(DeviceService service) =>
      mounted && identical(ref.read(deviceServiceProvider), service);

  /// Strips stacked `Exception:` / `Operation failed:` prefixes so a guider
  /// failure reads as English. The raw chain arrives as
  /// "Exception: Guiding stopped: Operation failed: Calibration star match
  /// failed" — each layer adds its own label on the way up from Rust.
  static String _cleanErrorText(String raw) {
    var text = raw.trim();
    final prefixes = RegExp(
      r'^(Exception|_Exception|StateError|Operation failed|SkotiqException(\([^)]*\))?)\s*:\s*',
      caseSensitive: false,
    );
    // Peel repeatedly: the chain nests more than one label deep.
    for (var i = 0; i < 4; i++) {
      final stripped = text.replaceFirst(prefixes, '').trim();
      if (stripped == text || stripped.isEmpty) break;
      text = stripped;
    }
    return text.isEmpty ? raw.trim() : text;
  }

  /// One guide-error readout (RMS or Peak).
  ///
  /// Every `Phd2GuideStats` error field defaults to 0.0, which on screen is
  /// indistinguishable from a real, perfect measurement: "RA Peak 0.00" with no
  /// guider connected is a claim of flawless guiding. Until at least one guide
  /// step has been measured (`frameCount > 0`, zeroed again by
  /// `GuidingStopped`) there is nothing to report, so render the same em dash
  /// the Guiding screen, Equipment card and Dashboard already use.
  ///
  /// PHD2 and the built-in guider both report residuals in guide-camera
  /// PIXELS. Convert only when a pixel scale is actually known; otherwise say
  /// px rather than mislabelling pixels as arcseconds (at a 0.78"/px guide
  /// scale the bare suffix swap understates a 0.53 px error by ~28%).
  static String _guideErrorText(
    double value, {
    required bool hasSamples,
    required double pixelScale,
  }) {
    if (!hasSamples) return '—';
    if (pixelScale > 0) return '${(value * pixelScale).toStringAsFixed(2)}"';
    return '${value.toStringAsFixed(2)} px';
  }

  @override
  Widget build(BuildContext context) {
    final guiderState = ref.watch(guiderStateProvider);
    final ditherSettings = ref.watch(ditherSettingsProvider);
    final isConnected =
        guiderState.connectionState == DeviceConnectionState.connected;
    final isGuiding = guiderState.isGuiding;
    final isBuiltinGuider = ref.watch(isBuiltinGuiderProvider);

    // All six error readouts below come from ONE source, the rolling guide
    // stats, so RMS and Peak cannot disagree about the same window. `guiderState`
    // carries a copy of the three RMS values (controller.dart mirrors them via
    // `updateRms`) but not the peaks, and the copy is not cleared on
    // `GuidingStopped` the way `GuideStatsNotifier.reset()` clears the source.
    //
    // Peak is the worst single-frame excursion over the window — a useful
    // complement to RMS for spotting transient seeing spikes or a flexing /
    // bumped axis that an averaged figure would smooth away.
    final guideStats = ref.watch(guideStatsProvider);
    final hasGuideSamples = guideStats.frameCount > 0;
    final pixelScale = guideStats.pixelScale;
    final rmsRa = _guideErrorText(
      guideStats.rmsRa,
      hasSamples: hasGuideSamples,
      pixelScale: pixelScale,
    );
    final rmsDec = _guideErrorText(
      guideStats.rmsDec,
      hasSamples: hasGuideSamples,
      pixelScale: pixelScale,
    );
    final rmsTotal = _guideErrorText(
      guideStats.rmsTotal,
      hasSamples: hasGuideSamples,
      pixelScale: pixelScale,
    );
    final peakRa = _guideErrorText(
      guideStats.peakRa,
      hasSamples: hasGuideSamples,
      pixelScale: pixelScale,
    );
    final peakDec = _guideErrorText(
      guideStats.peakDec,
      hasSamples: hasGuideSamples,
      pixelScale: pixelScale,
    );

    return SingleChildScrollView(
      // The SidePanel already pads its content by 16 (05 §15).
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Connection status.
          //
          // A guider that FAILED must not be reported as absent. The built-in
          // guider connects fine and then its task can die asynchronously
          // ("Built-in guider task failed: Calibration star match failed" was
          // reproduced with the simulator camera), which leaves this panel
          // non-connected. Saying "No guider connected" then sends the operator
          // to re-check cables and device selection for what is really a
          // calibration/guiding failure the log already named. Show the error.
          if (!isConnected)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: SkotiqDecorations.emphasisSurface(
                guiderState.lastError != null
                    ? widget.colors.error
                    : widget.colors.warning,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.alertCircle,
                      size: 16,
                      color: guiderState.lastError != null
                          ? widget.colors.error
                          : widget.colors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      guiderState.lastError != null
                          ? 'Guider error: ${_cleanErrorText(guiderState.lastError!.message)}'
                          : (guiderState.deviceId != null
                              ? 'Guider ${guiderState.deviceName ?? guiderState.deviceId!} is not connected'
                              : 'No guider connected'),
                      style: SkotiqTypography.caption.copyWith(
                          color: guiderState.lastError != null
                              ? widget.colors.error
                              : widget.colors.warning),
                    ),
                  ),
                ],
              ),
            ),

          // Guiding graph with real data
          CompactGuidingGraph(
            colors: widget.colors,
            data: ref.watch(guideGraphProvider),
            isGuiding: isGuiding,
            isConnected: isConnected,
          ),
          const SizedBox(height: 16),

          // RMS Stats
          Row(
            children: [
              GuideStat(label: 'RA RMS', value: rmsRa, colors: widget.colors),
              GuideStat(label: 'Dec RMS', value: rmsDec, colors: widget.colors),
              GuideStat(label: 'Total', value: rmsTotal, colors: widget.colors),
            ],
          ),
          const SizedBox(height: 12),

          // Peak Stats — per-axis worst-case excursion over the rolling window.
          // The trailing spacer keeps both axes left-aligned under their RMS
          // counterparts instead of stretching across the full row.
          Row(
            children: [
              GuideStat(label: 'RA Peak', value: peakRa, colors: widget.colors),
              GuideStat(
                label: 'Dec peak',
                value: peakDec,
                colors: widget.colors,
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 20),

          // Tracked-star list — only the built-in multi-star guider reports a
          // per-star list (PHD2 tracks a single lock star). Reuses the same
          // guiding status path that feeds the graph above.
          if (isBuiltinGuider) ...[
            GuideStarList(colors: widget.colors),
            const SizedBox(height: 20),
          ],

          // Control Section
          PanelSection(
            title: 'Control',
            colors: widget.colors,
            child: Column(
              children: [
                Builder(
                  builder: (BuildContext context) {
                    final startLabel = _isStartingGuiding
                        ? 'Starting...'
                        : isGuiding
                            ? 'Guiding'
                            : 'Start';
                    return AdaptiveColumns(
                      cells: [
                        AdaptiveCell(
                          minWidth: SmallButton.measureWidth(
                            context,
                            label: startLabel,
                          ),
                          child: SmallButton(
                            label: startLabel,
                            icon: isGuiding
                                ? SkotiqIcons.activity
                                : SkotiqIcons.play,
                            colors: widget.colors,
                            isEnabled: isConnected &&
                                !isGuiding &&
                                !_isStartingGuiding,
                            onTap: _startGuiding,
                          ),
                        ),
                        AdaptiveCell(
                          minWidth: SmallButton.measureWidth(
                            context,
                            label: 'Stop',
                          ),
                          child: SmallButton(
                            label: 'Stop',
                            icon: SkotiqIcons.stop,
                            isOutline: true,
                            colors: widget.colors,
                            isEnabled: isConnected && isGuiding,
                            onTap: _stopGuiding,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SmallButton(
                    label: _isDithering ? 'Dithering...' : 'Dither',
                    icon: _isDithering
                        ? SkotiqIcons.loading
                        : LucideIcons.shuffle,
                    isOutline: true,
                    colors: widget.colors,
                    isEnabled: isConnected && isGuiding && !_isDithering,
                    onTap: _dither,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Built-in Guider Configuration (only when built-in guider is active)
          if (isBuiltinGuider) ...[
            _BuiltinGuiderConfigSection(
              colors: widget.colors,
              isExpanded: _configExpanded,
              onToggle: () =>
                  setState(() => _configExpanded = !_configExpanded),
            ),
            const SizedBox(height: 20),
          ],

          // Dithering Settings
          PanelSection(
            title: 'Dither settings',
            colors: widget.colors,
            child: Column(
              children: [
                SliderRowInteractive(
                  label: 'Amount',
                  helpId: FieldHelpId.ditherAmount,
                  value: ditherSettings.ditherAmount,
                  min: 1,
                  max: 20,
                  suffix: 'px',
                  colors: widget.colors,
                  onChanged: (value) => ref
                      .read(ditherSettingsProvider.notifier)
                      .state = ditherSettings.copyWith(ditherAmount: value),
                ),
                const SizedBox(height: 12),
                SliderRowInteractive(
                  label: 'Settle threshold',
                  helpId: FieldHelpId.settleThreshold,
                  value: ditherSettings.settlePixels,
                  min: 0.3,
                  max: 3.0,
                  suffix: '"',
                  colors: widget.colors,
                  onChanged: (value) => ref
                      .read(ditherSettingsProvider.notifier)
                      .state = ditherSettings.copyWith(settlePixels: value),
                ),
                const SizedBox(height: 12),
                SliderRowInteractive(
                  label: 'Settle time',
                  helpId: FieldHelpId.settleTime,
                  value: ditherSettings.settleTime,
                  min: 5,
                  max: 30,
                  suffix: 's',
                  colors: widget.colors,
                  onChanged: (value) => ref
                      .read(ditherSettingsProvider.notifier)
                      .state = ditherSettings.copyWith(settleTime: value),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
