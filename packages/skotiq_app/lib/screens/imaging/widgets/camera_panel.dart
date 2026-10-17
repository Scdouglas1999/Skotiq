import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/help/field_help_copy.dart';
import 'panel_widgets.dart';

class CameraPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  /// When false, the panel renders its content without its own
  /// [SingleChildScrollView] so a parent can host a single unified scroll —
  /// e.g. the Camera tab stacks this panel above the calibration section in one
  /// scroll view, so the Cooling controls keep their natural height instead of
  /// being squeezed into a cramped region above a pinned calibration card.
  final bool scrollable;

  const CameraPanel({super.key, required this.colors, this.scrollable = true});

  @override
  ConsumerState<CameraPanel> createState() => _CameraPanelState();
}

class _CameraPanelState extends ConsumerState<CameraPanel> {
  bool _isCooling = false; // Only for UI loading state
  bool _isChangingReadoutMode = false;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        if (mounted && (_isCooling || _isChangingReadoutMode)) {
          setState(() {
            _isCooling = false;
            _isChangingReadoutMode = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  bool _isCurrentAuthority(SkotiqBackend authority) =>
      mounted && identical(ref.read(backendProvider), authority);

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cameraStateProvider);
    final coolingSettings = ref.watch(coolingSettingsProvider);
    final coolingStatus = ref.watch(coolingStatusProvider);
    final exposureSettings = ref.watch(exposureSettingsProvider);
    // Use target temp from provider (persists across navigation)
    final targetTemp = cameraState.targetTemp;

    final isConnected =
        cameraState.connectionState == DeviceConnectionState.connected;

    // Watch camera capabilities to gate UI features
    final capabilitiesAsync =
        ref.watch(cameraCapabilitiesProvider(cameraState.deviceId ?? ''));
    final capabilities = capabilitiesAsync.valueOrNull;
    final capabilitiesLoading = capabilitiesAsync.isLoading;
    final hasCoolingTelemetry = cameraState.temperature != null ||
        cameraState.coolerPower != null ||
        cameraState.isCooling;
    // Show cooling controls when support is known, still loading, or live
    // telemetry confirms cooling is active.
    final showCoolingSection = isConnected &&
        (capabilitiesLoading ||
            (capabilities?.canSetCcdTemperature == true) ||
            hasCoolingTelemetry);
    // Cooler target-temperature slider range. Prefer the camera's reported
    // operating range; fall back to a conservative -30..20°C window when caps
    // are unknown or when a driver reports a nonsensical range (min >= max).
    const double kDefaultCoolerMinTempC = -30;
    const double kDefaultCoolerMaxTempC = 20;
    final double? capCoolerMin = capabilities?.coolerMinTempC;
    final double? capCoolerMax = capabilities?.coolerMaxTempC;
    // Only honor the reported range when both bounds are present AND sane
    // (min < max). A nonsensical range from buggy driver data falls back to
    // the conservative default window rather than feeding the slider an
    // inverted range.
    final bool hasValidCoolerRange = capCoolerMin != null &&
        capCoolerMax != null &&
        capCoolerMin < capCoolerMax;
    final double coolerMinTempC =
        hasValidCoolerRange ? capCoolerMin : kDefaultCoolerMinTempC;
    final double coolerMaxTempC =
        hasValidCoolerRange ? capCoolerMax : kDefaultCoolerMaxTempC;

    // If capabilities are unavailable, infer controls from live camera telemetry
    // to avoid blocking devices that omit explicit capability reporting.
    final canSetGain = capabilities?.canSetGain ?? (cameraState.gain != null);
    final canSetOffset =
        capabilities?.canSetOffset ?? (cameraState.offset != null);

    // Get binning options based on camera capabilities
    final binningOptions = ref.watch(
      cameraBinningOptionsProvider(cameraState.deviceId ?? ''),
    );

    // Ensure current binning value is valid for available options
    final currentBinning = binningOptions.contains(exposureSettings.binning)
        ? exposureSettings.binning
        : binningOptions.first;

    // The SidePanel already pads its content by 16 (05 §15).
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Connection status
        if (!isConnected)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: SkotiqDecorations.emphasisSurface(
              widget.colors.warning,
              borderRadius:
                  BorderRadius.circular(SkotiqTokens.radiusInline8),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.alertCircle,
                    size: 16, color: widget.colors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No camera connected',
                    style: SkotiqTypography.caption
                        .copyWith(color: widget.colors.warning),
                  ),
                ),
              ],
            ),
          ),

        // Cooling Section - show if camera supports cooling or while loading capabilities
        if (showCoolingSection)
          PanelSection(
            title: 'Cooling',
            colors: widget.colors,
            child: Column(
              children: [
                // Current temperature display
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Current',
                        style: SkotiqTypography.caption
                            .copyWith(color: widget.colors.textSecondary)),
                    Row(
                      children: [
                        Text(
                          isConnected && cameraState.temperature != null
                              ? '${cameraState.temperature!.toStringAsFixed(1)}°C'
                              : '\u2014',
                          style: SkotiqTypography.readoutSm.copyWith(
                            color: isConnected
                                ? widget.colors.textPrimary
                                : widget.colors.textMuted,
                          ),
                        ),
                        if (isConnected && coolingStatus.isCooling)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Icon(
                              coolingStatus.isAtTarget
                                  ? LucideIcons.checkCircle2
                                  : SkotiqIcons.arrowDown,
                              size: 14,
                              color: coolingStatus.isAtTarget
                                  ? widget.colors.success
                                  : widget.colors.primary,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Power',
                        style: SkotiqTypography.caption
                            .copyWith(color: widget.colors.textSecondary)),
                    Text(
                      isConnected && cameraState.coolerPower != null
                          ? '${cameraState.coolerPower!.toStringAsFixed(0)}%'
                          : '\u2014',
                      style: SkotiqTypography.readoutSm.copyWith(
                        color: isConnected
                            ? widget.colors.textPrimary
                            : widget.colors.textMuted,
                      ),
                    ),
                  ],
                ),
                if (isConnected && coolingStatus.isCooling)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Target',
                            style: SkotiqTypography.caption
                                .copyWith(color: widget.colors.textSecondary)),
                        Text(
                          '${coolingStatus.targetTemp.toStringAsFixed(1)}°C',
                          style: SkotiqTypography.caption
                              .copyWith(color: widget.colors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),

                // Target temperature slider
                SliderRowInteractive(
                  label: 'Target temperature',
                  value: targetTemp.clamp(coolerMinTempC, coolerMaxTempC),
                  min: coolerMinTempC,
                  max: coolerMaxTempC,
                  suffix: '°C',
                  colors: widget.colors,
                  onChanged: isConnected
                      ? (value) {
                          // Update provider so value persists across navigation
                          ref
                              .read(cameraStateProvider.notifier)
                              .setTargetTemp(value);
                          // Also update settings provider for consistency
                          ref.read(coolingSettingsProvider.notifier).state =
                              coolingSettings.copyWith(targetTemp: value);
                        }
                      : null,
                ),
                const SizedBox(height: 16),
                AdaptiveColumns(
                  cells: [
                    AdaptiveCell(
                      minWidth: SmallButton.measureWidth(
                        context,
                        label: _isCooling ? 'Setting...' : 'Cool down',
                      ),
                      child: SmallButton(
                        label: _isCooling ? 'Setting...' : 'Cool down',
                        icon: SkotiqIcons.frost,
                        colors: widget.colors,
                        isEnabled: isConnected &&
                            !_isCooling &&
                            !cameraState.isWarming,
                        onTap: () async {
                          if (_isCooling) return;
                          final authority = ref.read(backendProvider);
                          final service = ref.read(deviceServiceProvider);
                          setState(() => _isCooling = true);
                          try {
                            await service.setCameraCooling(
                              enabled: true,
                              targetTemp: targetTemp,
                            );

                            if (_isCurrentAuthority(authority)) {
                              // Update settings state
                              ref.read(coolingSettingsProvider.notifier).state =
                                  coolingSettings.copyWith(
                                enabled: true,
                                targetTemp: targetTemp,
                              );
                              // Update camera state
                              ref
                                  .read(cameraStateProvider.notifier)
                                  .setCooling(true);
                            }
                          } catch (e) {
                            if (context.mounted &&
                                _isCurrentAuthority(authority)) {
                              context.showErrorSnackBar(
                                  'Failed to set cooling: $e');
                            }
                          } finally {
                            if (_isCurrentAuthority(authority)) {
                              setState(() => _isCooling = false);
                            }
                          }
                        },
                      ),
                    ),
                    AdaptiveCell(
                      minWidth: SmallButton.measureWidth(
                        context,
                        label: cameraState.isWarming
                            ? 'Cancel warm-up'
                            : 'Warm up',
                      ),
                      child: SmallButton(
                        label: cameraState.isWarming
                            ? 'Cancel warm-up'
                            : 'Warm up',
                        icon: LucideIcons.flame,
                        isOutline: true,
                        colors: widget.colors,
                        isEnabled: isConnected && !_isCooling,
                        onTap: () async {
                          final service = ref.read(deviceServiceProvider);
                          if (cameraState.isWarming) {
                            service.cancelWarmCamera();
                            return;
                          }
                          if (_isCooling) return;
                          final authority = ref.read(backendProvider);
                          setState(() => _isCooling = true);
                          try {
                            // Warm-up is a gradual set-point ramp. Turning
                            // the cooler off immediately here contradicts
                            // the label and can cause condensation or
                            // thermal shock.
                            await service.warmCamera();
                          } catch (e) {
                            if (context.mounted &&
                                _isCurrentAuthority(authority)) {
                              context.showErrorSnackBar(
                                'Failed to warm up: $e',
                              );
                            }
                          } finally {
                            if (_isCurrentAuthority(authority)) {
                              setState(() => _isCooling = false);
                            }
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        // Show "not supported" message when camera is connected and capabilities confirm no cooling support
        if (isConnected &&
            !capabilitiesLoading &&
            !capabilitiesAsync.hasError &&
            capabilities != null &&
            !capabilities.canSetCcdTemperature)
          PanelSection(
            title: 'Cooling',
            colors: widget.colors,
            child: Text(
              'Cooling not supported by this camera',
              style: SkotiqTypography.caption.copyWith(
                  color: widget.colors.textSecondary,
                  fontStyle: FontStyle.italic),
            ),
          ),
        const SizedBox(height: 20),

        // Sensor Settings
        PanelSection(
          title: 'Sensor',
          colors: widget.colors,
          child: Column(
            children: [
              DropdownRow(
                label: 'Binning',
                value: currentBinning,
                items: binningOptions,
                colors: widget.colors,
                onChanged: isConnected
                    ? (value) {
                        if (value != null) {
                          final parts = value.split('x');
                          ref
                              .read(manualExposureSettingsUpdaterProvider)
                              .update(
                                exposureSettings.copyWith(
                                  binningX: int.parse(parts[0]),
                                  binningY: int.parse(parts[1]),
                                ),
                              );
                        }
                      }
                    : null,
              ),
              // Read Mode is driver-reported. Hide the row entirely when the
              // camera exposes no readout modes (matches the hide-when-
              // unsupported pattern used for unsupported device features);
              // there is intentionally no synthetic binary fallback.
              if ((capabilities?.readoutModes ?? const []).isNotEmpty) ...[
                const SizedBox(height: 12),
                Builder(
                  builder: (context) {
                    final readoutModes = capabilities!.readoutModes;
                    final selectedIndex = exposureSettings
                        .resolveReadoutModeIndex(readoutModes.length);
                    final selectedMode = selectedIndex >= 0 &&
                            selectedIndex < readoutModes.length
                        ? readoutModes[selectedIndex]
                        : null;
                    return DropdownRow(
                      label: 'Read mode',
                      helpId: FieldHelpId.cameraReadoutMode,
                      value: selectedMode,
                      items: readoutModes,
                      colors: widget.colors,
                      onChanged: isConnected && !_isChangingReadoutMode
                          ? (value) async {
                              if (value == null) return;
                              final idx = readoutModes.indexOf(value);
                              if (idx < 0) return;
                              final deviceId = cameraState.deviceId;
                              if (deviceId == null) return;
                              final authority = ref.read(backendProvider);
                              final deviceBackend =
                                  ref.read(deviceBackendProvider);
                              final exposureUpdater = ref.read(
                                manualExposureSettingsUpdaterProvider,
                              );
                              setState(() => _isChangingReadoutMode = true);
                              try {
                                await deviceBackend.cameraSetReadoutMode(
                                  deviceId,
                                  idx,
                                );
                                if (_isCurrentAuthority(authority)) {
                                  final latestSettings =
                                      ref.read(exposureSettingsProvider);
                                  exposureUpdater.update(
                                    latestSettings.copyWith(
                                      readoutModeIndex: idx,
                                      fastReadout:
                                          idx == readoutModes.length - 1,
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (context.mounted &&
                                    _isCurrentAuthority(authority)) {
                                  context.showErrorSnackBar(
                                    'Failed to set read mode: $e',
                                  );
                                }
                              } finally {
                                if (_isCurrentAuthority(authority)) {
                                  setState(
                                    () => _isChangingReadoutMode = false,
                                  );
                                }
                              }
                            }
                          : null,
                    );
                  },
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Gain/Offset - only show if camera supports these features
        if (canSetGain || canSetOffset)
          PanelSection(
            title: 'Gain / Offset',
            colors: widget.colors,
            child: Column(
              children: [
                // Only show gain control if camera supports it
                if (canSetGain)
                  InputRowEditable(
                    label:
                        'Gain${capabilities?.gainMin != null ? ' (${capabilities!.gainMin}-${capabilities.gainMax})' : ''}',
                    helpId: FieldHelpId.cameraGain,
                    value: exposureSettings.gain.toString(),
                    colors: widget.colors,
                    onChanged: (value) {
                      final parsed = int.tryParse(value);
                      if (parsed != null && parsed >= 0) {
                        // Clamp to valid range if capabilities available
                        final clamped = capabilities?.gainMin != null
                            ? parsed.clamp(
                                capabilities!.gainMin!, capabilities.gainMax!)
                            : parsed;
                        ref.read(manualExposureSettingsUpdaterProvider).update(
                              exposureSettings.copyWith(gain: clamped),
                            );
                      }
                    },
                  ),
                if (canSetGain && canSetOffset) const SizedBox(height: 12),
                // Only show offset control if camera supports it
                if (canSetOffset)
                  InputRowEditable(
                    label:
                        'Offset${capabilities?.offsetMin != null ? ' (${capabilities!.offsetMin}-${capabilities.offsetMax})' : ''}',
                    helpId: FieldHelpId.cameraOffset,
                    value: exposureSettings.offset.toString(),
                    colors: widget.colors,
                    onChanged: (value) {
                      final parsed = int.tryParse(value);
                      if (parsed != null && parsed >= 0) {
                        // Clamp to valid range if capabilities available
                        final clamped = capabilities?.offsetMin != null
                            ? parsed.clamp(capabilities!.offsetMin!,
                                capabilities.offsetMax!)
                            : parsed;
                        ref.read(manualExposureSettingsUpdaterProvider).update(
                              exposureSettings.copyWith(offset: clamped),
                            );
                      }
                    },
                  ),
              ],
            ),
          ),
      ],
    );
    if (!widget.scrollable) return content;
    return SingleChildScrollView(child: content);
  }
}
