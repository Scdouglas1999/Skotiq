import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../accessible_dropdown.dart';
import 'glass_card.dart';

class CaptureSettingsCard extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const CaptureSettingsCard({super.key, required this.colors});

  @override
  ConsumerState<CaptureSettingsCard> createState() =>
      _CaptureSettingsCardState();
}

class _CaptureSettingsCardState extends ConsumerState<CaptureSettingsCard> {
  bool _isLooping = false;
  bool _isChangingFilter = false;
  bool _captureInFlight = false;
  int _loopGeneration = 0;
  ProviderSubscription<ImagingService>? _imagingSubscription;
  ProviderSubscription<DeviceService>? _deviceSubscription;

  @override
  void initState() {
    super.initState();
    _imagingSubscription = ref.listenManual<ImagingService>(
      imagingServiceProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        _loopGeneration++;
        if (mounted && (_isLooping || _captureInFlight)) {
          setState(() {
            _isLooping = false;
            _captureInFlight = false;
          });
        }
      },
    );
    _deviceSubscription = ref.listenManual<DeviceService>(
      deviceServiceProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        if (mounted && _isChangingFilter) {
          setState(() => _isChangingFilter = false);
        }
      },
    );
  }

  @override
  void dispose() {
    _loopGeneration++;
    _imagingSubscription?.close();
    _deviceSubscription?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final exposureSettings = ref.watch(exposureSettingsProvider);
    final exposureProgress = ref.watch(exposureProgressProvider);
    final cameraState = ref.watch(cameraStateProvider);
    final filterWheelState = ref.watch(filterWheelStateProvider);
    final autofocusRunning = ref.watch(
      sessionStateProvider.select((session) => session.isAutofocusing),
    );
    final binningOptions = ref.watch(
      cameraBinningOptionsProvider(cameraState.deviceId ?? ''),
    );

    final isConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    final isCapturing = _captureInFlight ||
        cameraState.isExposing ||
        exposureProgress.percent > 0 ||
        exposureProgress.isDownloading;
    final captureBlocked = isCapturing ||
        _isChangingFilter ||
        filterWheelState.isMoving ||
        autofocusRunning;
    final isFilterWheelConnected =
        filterWheelState.connectionState == DeviceConnectionState.connected;

    // Get actual filter names from connected filter wheel, or use defaults
    final filterNames = filterWheelState.filterNames.isNotEmpty
        ? filterWheelState.filterNames
        : const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'];

    // Current filter - use filter wheel position if connected, else from settings
    final currentFilterIndex = filterWheelState.currentPosition;
    final currentFilterName = isFilterWheelConnected &&
            currentFilterIndex != null &&
            currentFilterIndex >= 0 &&
            currentFilterIndex < filterNames.length
        ? filterNames[currentFilterIndex]
        : (exposureSettings.filter != null &&
                filterNames.contains(exposureSettings.filter)
            ? exposureSettings.filter!
            : filterNames.first);

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.camera,
            title: 'Capture',
            accent: colors.primary,
          ),
          const SizedBox(height: DashboardCardStyle.headerGap),
          // Settings - use Wrap for responsive layout
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Exposure
              _CompactSettingField(
                label: 'Exp',
                value: exposureSettings.exposureTime.toString(),
                suffix: 's',
                colors: colors,
                onChanged: (v) {
                  final parsed = double.tryParse(v);
                  if (parsed != null && parsed > 0) {
                    ref.read(manualExposureSettingsUpdaterProvider).update(
                          exposureSettings.copyWith(exposureTime: parsed),
                        );
                  }
                },
              ),
              // Gain
              _CompactSettingField(
                label: 'Gain',
                value: exposureSettings.gain.toString(),
                colors: colors,
                onChanged: (v) {
                  final parsed = int.tryParse(v);
                  if (parsed != null && parsed >= 0) {
                    ref.read(manualExposureSettingsUpdaterProvider).update(
                          exposureSettings.copyWith(gain: parsed),
                        );
                  }
                },
              ),
              // Binning dropdown
              _CompactDropdown(
                label: 'Bin',
                value: binningOptions.contains(exposureSettings.binning)
                    ? exposureSettings.binning
                    : binningOptions.first,
                items: binningOptions,
                colors: colors,
                onChanged: (v) {
                  if (v != null) {
                    final parts = v.split('x');
                    ref.read(manualExposureSettingsUpdaterProvider).update(
                          exposureSettings.copyWith(
                            binningX: int.parse(parts[0]),
                            binningY: int.parse(parts[1]),
                          ),
                        );
                  }
                },
              ),
              // Filter dropdown - uses actual filter names from connected filter wheel
              _CompactDropdown(
                label: 'Filter',
                value: currentFilterName,
                items: filterNames,
                colors: colors,
                highlight: true,
                onChanged: (_isChangingFilter ||
                        filterWheelState.isMoving ||
                        autofocusRunning ||
                        isCapturing ||
                        _isLooping)
                    ? null
                    : (v) => _onFilterChanged(v, filterNames),
              ),
              // Frame type dropdown
              _CompactDropdown(
                label: 'Frame',
                value: exposureSettings.frameType.displayName,
                items: FrameType.values.map((t) => t.displayName).toList(),
                colors: colors,
                onChanged: (v) {
                  if (v != null) {
                    final type = FrameType.values.firstWhere(
                      (t) => t.displayName == v,
                      orElse: () => FrameType.light,
                    );
                    ref.read(manualExposureSettingsUpdaterProvider).update(
                          exposureSettings.copyWith(frameType: type),
                        );
                  }
                },
              ),
              // Progress indicator when capturing
              if (isCapturing)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        value: (exposureProgress.percent / 100).clamp(0.0, 1.0),
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(colors.primary),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${exposureProgress.percent.clamp(0.0, 100.0).toInt()}%',
                      style: SkotiqTypography.labelStrongSm.copyWith(
                        color: colors.primary,
                      ),
                    ),
                  ],
                )
              else if (!isConnected)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: SkotiqDecorations.tintedBadge(
                    colors.warning,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                  ),
                  child: Text(
                    'No Camera',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.warning),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // Capture buttons row - compact
          Row(
            children: [
              Expanded(
                flex: 2,
                child: SkotiqButton(
                  label: isCapturing
                      ? (exposureProgress.isDownloading
                          ? 'Downloading...'
                          : 'Capturing...')
                      : 'Capture',
                  icon: isCapturing ? LucideIcons.loader2 : LucideIcons.camera,
                  size: ButtonSize.small,
                  onPressed:
                      (!isConnected || captureBlocked) ? null : _captureImage,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SkotiqButton(
                  label: _isLooping ? 'Stop Loop' : 'Loop',
                  icon: LucideIcons.repeat,
                  variant: _isLooping
                      ? ButtonVariant.primary
                      : ButtonVariant.outline,
                  size: ButtonSize.small,
                  // Stopping the loop must remain available while its current
                  // exposure is in flight. Abort is the separate action that
                  // cancels that exposure immediately.
                  onPressed: _isLooping
                      ? _toggleLoop
                      : (!isConnected || captureBlocked)
                          ? null
                          : _toggleLoop,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SkotiqButton(
                  label: 'Abort',
                  icon: LucideIcons.x,
                  variant: ButtonVariant.outline,
                  size: ButtonSize.small,
                  onPressed: (isCapturing || _isLooping) ? _abortCapture : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Capture one KEEPER frame for the Capture button.
  ///
  /// [ImagingService.captureImage] is the keeper-only entry point
  /// (`persistFrame: true`): the frame is written into the operator's
  /// light-frame folder under the naming pattern and indexed in
  /// `captured_images`. That is what a deliberate single capture should do —
  /// and exactly what Loop must not do. See [_captureLoopFrame].
  Future<bool> _captureImage() async {
    if (_captureInFlight) return false;
    if (!_requireConnectedCamera()) return false;
    final ImagingService imagingService = ref.read(imagingServiceProvider);
    setState(() => _captureInFlight = true);
    try {
      final settings = ref.read(exposureSettingsProvider);
      final result = await imagingService.captureImage(settings: settings);
      // ImagingService owns currentImage publication, including the later raw
      // pixel upgrade. Re-publishing its early return here can overwrite that
      // newer raw-ready image with a stale preview-only copy.
      return result != null && _isCurrentImagingService(imagingService);
    } catch (e) {
      if (mounted && _isCurrentImagingService(imagingService)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
      return false;
    } finally {
      if (_isCurrentImagingService(imagingService)) {
        setState(() => _captureInFlight = false);
      }
    }
  }

  /// Capture ONE live-view frame for the Loop button.
  ///
  /// Loop is framing/focusing, not acquisition, so it must not run
  /// [ImagingService.captureImage]: that entry point is keeper-only, so this
  /// card's Loop wrote every framing frame full-size into the operator's
  /// light-frame folder and indexed it as a light — roughly 27 GB an hour at
  /// 5 s subs, from a button that only claims to be a live view.
  /// [ImagingService.startLoopCapture] with `saveFrames: false` reuses one
  /// scratch file per camera instead, so the preview, annotation and
  /// plate-solve paths still find a frame on disk while nothing is kept and
  /// nothing enters the session totals.
  ///
  /// Frames are never kept from here: the opt-in "save loop frames" control
  /// lives on the Imaging screen beside a banner that states which mode is
  /// active. A card with no such indicator must not silently fill the
  /// light-frame folder.
  ///
  /// Why one frame per call rather than handing the whole run to the service:
  /// Stop Loop on this card ends the run *after* the exposure already in
  /// flight, and Abort is the separate immediate cancel. The service-side loop
  /// can only be stopped with `cancelExposure()`, which would collapse both
  /// controls onto the same behaviour.
  Future<bool> _captureLoopFrame(ImagingService imagingService) async {
    if (_captureInFlight) return false;
    if (!_requireConnectedCamera()) return false;
    if (!_isCurrentImagingService(imagingService)) return false;
    setState(() => _captureInFlight = true);
    var framesCaptured = 0;
    String? failure;
    try {
      await imagingService.startLoopCapture(
        settings: ref.read(exposureSettingsProvider),
        targetName: ref.read(sessionStateProvider).targetName,
        maxFrames: 1,
        saveFrames: false,
        onImageCaptured: (_) => framesCaptured++,
        onError: (error) => failure ??= error,
      );
    } catch (e) {
      failure ??= e.toString();
    } finally {
      if (_isCurrentImagingService(imagingService)) {
        setState(() => _captureInFlight = false);
      }
    }
    if (!_isCurrentImagingService(imagingService)) return false;
    if (failure != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $failure')),
        );
      }
      return false;
    }
    return framesCaptured > 0;
  }

  bool _requireConnectedCamera() {
    final cameraState = ref.read(cameraStateProvider);
    if (cameraState.connectionState == DeviceConnectionState.connected) {
      return true;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera not connected')),
      );
    }
    return false;
  }

  void _toggleLoop() async {
    if (_isLooping) {
      _loopGeneration++;
      setState(() => _isLooping = false);
      return;
    }
    final imagingService = ref.read(imagingServiceProvider);
    final generation = ++_loopGeneration;
    setState(() => _isLooping = true);
    while (_isLooping &&
        mounted &&
        generation == _loopGeneration &&
        _isCurrentImagingService(imagingService)) {
      final captured = await _captureLoopFrame(imagingService);
      if (!_isCurrentImagingService(imagingService) ||
          generation != _loopGeneration) {
        break;
      }
      if (!captured) {
        break;
      }
      if (_isLooping && mounted) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    if (mounted && generation == _loopGeneration) {
      setState(() => _isLooping = false);
    }
  }

  void _abortCapture() {
    _loopGeneration++;
    setState(() => _isLooping = false);
    final imagingService = ref.read(imagingServiceProvider);
    // Abort stays enabled for the whole loop, including the pause between
    // frames, so it is reachable with nothing to cancel. Dispatching anyway is
    // not free: it sends AbortExposure to a driver whose exposure already
    // ended, and it latches the service's cancel flag — which
    // [ImagingService.startLoopCapture] tests BEFORE its first frame, so the
    // next Loop press would start and stop without ever exposing.
    if (_captureInFlight || imagingService.isCapturing) {
      imagingService.cancelExposure();
    }
  }

  /// Handle filter selection - updates settings AND moves the physical filter wheel
  Future<void> _onFilterChanged(
    String? filterName,
    List<String> filterNames,
  ) async {
    if (filterName == null) return;

    // Find the position index for this filter name
    final position = filterNames.indexOf(filterName);
    if (position < 0) return;

    // If filter wheel is connected, actually move it
    final filterWheelState = ref.read(filterWheelStateProvider);
    if (filterWheelState.connectionState == DeviceConnectionState.connected) {
      // Capture the long-lived controllers before awaiting hardware. The card
      // may be removed while a slow wheel is still moving; reading `ref` after
      // that point would throw and lose the metadata update for a move that
      // physically succeeded.
      final deviceService = ref.read(deviceServiceProvider);
      final providerContainer =
          ProviderScope.containerOf(context, listen: false);
      final exposureUpdater =
          providerContainer.read(manualExposureSettingsUpdaterProvider);
      setState(() => _isChangingFilter = true);
      try {
        await deviceService.setFilterWheelPosition(position);
        if (identical(
          providerContainer.read(deviceServiceProvider),
          deviceService,
        )) {
          exposureUpdater.update(
            providerContainer
                .read(exposureSettingsProvider)
                .copyWith(filter: filterName),
          );
        }
      } catch (e) {
        if (mounted &&
            identical(
              providerContainer.read(deviceServiceProvider),
              deviceService,
            )) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to change filter: $e'),
              backgroundColor: widget.colors.error,
            ),
          );
        }
      } finally {
        if (mounted &&
            identical(
              providerContainer.read(deviceServiceProvider),
              deviceService,
            )) {
          setState(() => _isChangingFilter = false);
        }
      }
    } else {
      final exposureSettings = ref.read(exposureSettingsProvider);
      ref.read(manualExposureSettingsUpdaterProvider).update(
            exposureSettings.copyWith(filter: filterName),
          );
    }
  }

  bool _isCurrentImagingService(ImagingService service) =>
      mounted && identical(ref.read(imagingServiceProvider), service);
}

/// Compact text field for inline settings editing
class _CompactSettingField extends StatefulWidget {
  final String label;
  final String value;
  final String? suffix;
  final SkotiqColors colors;
  final ValueChanged<String> onChanged;

  const _CompactSettingField({
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
    this.suffix,
  });

  @override
  State<_CompactSettingField> createState() => _CompactSettingFieldState();
}

class _CompactSettingFieldState extends State<_CompactSettingField> {
  late TextEditingController _controller;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(_CompactSettingField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only update if the value changed externally (not from user input)
    if (oldWidget.value != widget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Commit on blur, then force the box back onto the committed value.
  ///
  /// Committing only on Enter leaves the box showing a number the rig was never
  /// told about when the user tabs away — or clicks Capture, which unfocuses the
  /// field on desktop. Re-syncing after the commit makes the box truthful in
  /// BOTH directions: a good edit renormalises ("2" -> "2.0") and an unparseable
  /// one snaps back to the value actually in force.
  void _onFocusChanged() {
    if (_focusNode.hasFocus) return;
    final typed = _controller.text;
    if (typed != widget.value) {
      widget.onChanged(typed);
    }
    // The commit lands in a provider, so the authoritative value only reaches
    // us on the next build; re-read `widget.value` after that frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusNode.hasFocus) return;
      if (_controller.text != widget.value) {
        _controller.text = widget.value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${widget.label}:',
          style:
              SkotiqTypography.caption.copyWith(color: widget.colors.textMuted),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 50,
          height: 28,
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            style: SkotiqTypography.caption
                .copyWith(color: widget.colors.textPrimary),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              filled: true,
              fillColor: widget.colors.surfaceAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
                borderSide: BorderSide(color: widget.colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
                borderSide: BorderSide(
                    color: widget.colors.border.withValues(alpha: 0.5)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
                borderSide: BorderSide(color: widget.colors.primary),
              ),
            ),
            onSubmitted: widget.onChanged,
          ),
        ),
        if (widget.suffix != null) ...[
          const SizedBox(width: 2),
          Text(widget.suffix!,
              style: SkotiqTypography.caption
                  .copyWith(color: widget.colors.textMuted)),
        ],
      ],
    );
  }
}

/// Compact dropdown for inline settings
class _CompactDropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<String> items;
  final SkotiqColors colors;
  final bool highlight;
  final ValueChanged<String?>? onChanged;

  const _CompactDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.colors,
    this.onChanged,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final isEnabled = onChanged != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label:',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
        const SizedBox(width: 4),
        Opacity(
          opacity: isEnabled ? 1.0 : 0.5,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: highlight
                ? SkotiqDecorations.emphasisSurface(
                    colors.primary,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                  )
                : BoxDecoration(
                    color: colors.surfaceAlt,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                    border: Border.all(
                      color: colors.border.withValues(alpha: 0.5),
                    ),
                  ),
            child: DropdownButtonHideUnderline(
              child: IgnorePointer(
                ignoring: !isEnabled,
                child: AccessibleDropdown<String>(
                  value: value,
                  isDense: true,
                  style: SkotiqTypography.caption.copyWith(
                      color: highlight ? colors.primary : colors.textPrimary),
                  dropdownColor: colors.surface,
                  icon: Icon(
                    LucideIcons.chevronDown,
                    size: 12,
                    color: colors.textMuted,
                  ),
                  items: items
                      .map(
                        (item) => DropdownMenuItem(
                          value: item,
                          child: Text(item),
                        ),
                      )
                      .toList(),
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
