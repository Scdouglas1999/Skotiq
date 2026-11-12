import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../tours/tour_target.dart';
import '../../../widgets/sensitivity_field.dart';
import '../../../utils/snackbar_helper.dart';
import 'imaging_view_prefs.dart';
import 'measured_width.dart';
import 'stretch_controls.dart';

/// Whether Loop keeps the frames it captures.
///
/// Loop is a live-view mode, so saving defaults off. A choice to save is
/// remembered across restarts: forgetting it lost the next night's frames
/// without a word.
final loopSavesFramesProvider =
    StateNotifierProvider<PersistedBoolNotifier, bool>(
  (ref) => PersistedBoolNotifier('imaging.loopSavesFrames'),
);

/// Identifies the capture bar's "Save loop frames" toggle for tests.
const loopSaveFramesToggleKey = Key('imaging.loopSaveFramesToggle');

/// The capture bar's MEASURED width, published so the canvas can keep its
/// bottom-right histogram off it.
///
/// The bar is centred and sizes itself to its content, and that content
/// changes with the rig (a filter wheel adds a dropdown, auto-stretch adds a
/// method picker) and with the type scale. Any constant here would be right
/// for one combination and wrong for the rest — which is exactly how two glass
/// panels ended up drawn on top of each other. Zero until the first layout.
final captureBarWidthProvider = StateProvider<double>((ref) => 0);

/// The glass capture bar, docked bottom-centre over the frame (06 §Imaging).
///
/// `[primary Snapshot] [secondary Loop] | [2.0 s] [G 100] [filter] | [Save]
/// Stretch [switch]`, 32 px controls in one [Glass] panel.
///
/// It replaces the full-width bottom banner, which spent a whole row of the
/// window on controls that belong over the image they act on.
class ImagingCaptureBar extends ConsumerStatefulWidget {
  const ImagingCaptureBar({
    super.key,
    required this.isLooping,
    required this.isSingleCapture,
    required this.isSavingCapture,
    required this.isStoppingCapture,
    required this.onSnapshot,
    required this.onToggleLoop,
  });

  final bool isLooping;
  final bool isSingleCapture;
  final bool isSavingCapture;
  final bool isStoppingCapture;
  final VoidCallback onSnapshot;
  final VoidCallback onToggleLoop;

  /// Width of the two mono fields (`mockups/imaging.html`).
  static const double _fieldWidth = 92;

  static const double _filterWidth = 96;

  /// Width of the ISO picker that replaces the gain field for a DSLR: room
  /// for "ISO 25600" and the chevron.
  static const double _isoWidth = 124;

  @override
  ConsumerState<ImagingCaptureBar> createState() => _ImagingCaptureBarState();
}

class _ImagingCaptureBarState extends ConsumerState<ImagingCaptureBar> {
  /// Owns the bar's horizontal scroll so the scrollbar has something to track.
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool get isLooping => widget.isLooping;
  bool get isSingleCapture => widget.isSingleCapture;
  bool get isSavingCapture => widget.isSavingCapture;
  bool get isStoppingCapture => widget.isStoppingCapture;
  VoidCallback get onSnapshot => widget.onSnapshot;
  VoidCallback get onToggleLoop => widget.onToggleLoop;

  static const double _fieldWidth = ImagingCaptureBar._fieldWidth;

  /// The filter the next frame is taken through: the wheel's loaded slot when
  /// a wheel reports one, otherwise the exposure settings' filter.
  String _shownFilter(FilterWheelState wheel, ExposureSettings settings) {
    final loaded = wheel.connectionState == DeviceConnectionState.connected
        ? wheel.currentFilterName
        : null;
    if (loaded != null && wheel.filterNames.contains(loaded)) return loaded;
    final chosen = settings.filter;
    if (chosen != null && wheel.filterNames.contains(chosen)) return chosen;
    return wheel.filterNames.first;
  }

  bool _filterSelectable(FilterWheelState wheel) =>
      wheel.connectionState == DeviceConnectionState.connected &&
      !wheel.isMoving;

  /// Moves the wheel to [name] and records it on the exposure settings, the
  /// same path as the side panel's filter buttons.
  Future<void> _selectFilter(String? name) async {
    if (name == null) return;
    final wheel = ref.read(filterWheelStateProvider);
    final position = wheel.filterNames.indexOf(name);
    if (position < 0 || position == wheel.currentPosition) return;
    if (ref.read(sessionStateProvider).isAutofocusing) {
      context.showErrorSnackBar(
        'Wait for autofocus to finish before changing the filter.',
      );
      return;
    }
    try {
      await ref.read(deviceServiceProvider).setFilterWheelPosition(position);
      ref
          .read(manualExposureSettingsUpdaterProvider)
          .update(ref.read(exposureSettingsProvider).copyWith(filter: name));
    } catch (e) {
      if (mounted) context.showErrorSnackBar('Failed to change filter: ${userFacingError(e)}');
    }
  }

  static const double _filterWidth = ImagingCaptureBar._filterWidth;

  @override
  Widget build(BuildContext context) {
    final exposureSettings = ref.watch(exposureSettingsProvider);
    final cameraState = ref.watch(cameraStateProvider);
    final filterState = ref.watch(filterWheelStateProvider);
    final sensitivity = ref.watch(cameraSensitivityProvider);
    final saveLoopFrames = ref.watch(loopSavesFramesProvider);
    final isConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    final isCapturing = isSingleCapture || isLooping;
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    final hostSuffix = isRemoteMode ? ' (host)' : '';

    final snapshotEnabled = isConnected && !isCapturing;
    final loopEnabled = isConnected && !isSingleCapture && !isStoppingCapture;
    final snapshotLabel = isSingleCapture
        ? (isStoppingCapture
            ? 'Stopping…'
            : isSavingCapture
                ? 'Saving…'
                : 'Taking…')
        : 'Snapshot$hostSuffix';
    final loopLabel = isStoppingCapture
        ? 'Stopping…'
        : isLooping
            ? 'Stop'
            : 'Loop';

    return MeasuredWidth(
      onWidth: (double width) {
        if (ref.read(captureBarWidthProvider) == width) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(captureBarWidthProvider.notifier).state = width;
        });
      },
      child: Glass(
        padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
        // The bar sizes to its content and centres, exactly as mocked up at
        // 1600. On a narrower canvas — a 900 px window still keeps the side
        // panel and the rail — that content is wider than the room it has, and
        // the rule for that is "reduce content or let it scroll" (07 §What NOT
        // to do). Nothing here is optional during a capture, so it scrolls, and
        // the scrollbar is what says so.
        //
        // IntrinsicWidth is what keeps both cases right: it sizes the bar to its
        // content, clamped by the room the canvas gives it, so a wide window
        // gets the centred pill from the mockup and a narrow one gets the same
        // pill full width with a scroll inside.
        child: IntrinsicWidth(
          child: Scrollbar(
            controller: _scrollController,
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  // The screen's two primary actions reached assistive tech as unnamed
                  // generic nodes, so a screen-reader user was never told the shutter
                  // was a button, nor that it was unavailable while the camera was
                  // disconnected. The role and the enabled state are published here so
                  // this bar's contract is pinned by its own test.
                  _BarAction(
                    label: snapshotLabel,
                    enabled: snapshotEnabled,
                    onTap: onSnapshot,
                    child: SkotiqButton(
                      key: TourTarget.imagingSnapshotButton.key,
                      label: snapshotLabel,
                      icon: isSingleCapture
                          ? SkotiqIcons.loading
                          : SkotiqIcons.camera,
                      isLoading: isSingleCapture,
                      semanticsHint: isConnected
                          ? null
                          : 'Connect a camera in Equipment first',
                      onPressed: snapshotEnabled ? onSnapshot : null,
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  _BarAction(
                    label: loopLabel,
                    enabled: loopEnabled,
                    onTap: onToggleLoop,
                    child: SkotiqButton(
                      key: TourTarget.imagingLoopButton.key,
                      label: loopLabel,
                      icon: isStoppingCapture
                          ? SkotiqIcons.loading
                          : isLooping
                              ? SkotiqIcons.stop
                              : SkotiqIcons.repeat,
                      variant: isLooping
                          ? ButtonVariant.destructive
                          : ButtonVariant.secondary,
                      semanticsHint: isConnected
                          ? null
                          : 'Connect a camera in Equipment first',
                      onPressed: loopEnabled ? onToggleLoop : null,
                    ),
                  ),
                  const _BarSeparator(),
                  SizedBox(
                    width: _fieldWidth,
                    child: _ExposureField(
                      hostSuffix: hostSuffix,
                      value: exposureSettings.exposureTime,
                      onChanged: (double parsed) => ref
                          .read(manualExposureSettingsUpdaterProvider)
                          .update(
                            exposureSettings.copyWith(exposureTime: parsed),
                          ),
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  SizedBox(
                    width: sensitivity is IsoSensitivity
                        ? ImagingCaptureBar._isoWidth
                        : _fieldWidth,
                    child: SensitivityField(
                      sensitivity: sensitivity,
                      value: exposureSettings.gain,
                      labelled: true,
                      onChanged: (int gain) => ref
                          .read(manualExposureSettingsUpdaterProvider)
                          .update(exposureSettings.copyWith(gain: gain)),
                      gainField: (_) => _GainField(
                        value: exposureSettings.gain,
                        onChanged: (int gain) => ref
                            .read(manualExposureSettingsUpdaterProvider)
                            .update(exposureSettings.copyWith(gain: gain)),
                      ),
                    ),
                  ),
                  if (filterState.filterNames.isNotEmpty) ...<Widget>[
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    SizedBox(
                      width: _filterWidth,
                      child: Semantics(
                        label: 'Filter',
                        child: SkotiqDropdown(
                          key: TourTarget.imagingFilterSelector.key,
                          value: _shownFilter(filterState, exposureSettings),
                          items: filterState.filterNames,
                          isExpanded: true,
                          onChanged: _filterSelectable(filterState)
                              ? _selectFilter
                              : null,
                        ),
                      ),
                    ),
                  ],
                  const _BarSeparator(),
                  _BarAction(
                    // "Save" alone names neither what is saved nor that it is a
                    // toggle; the accessible name says both.
                    label: 'Save loop frames',
                    enabled: !isLooping && !isStoppingCapture,
                    toggled: saveLoopFrames,
                    onTap: () => ref
                        .read(loopSavesFramesProvider.notifier)
                        .set(!saveLoopFrames),
                    child: SkotiqButton(
                      key: loopSaveFramesToggleKey,
                      label: 'Save',
                      icon: saveLoopFrames
                          ? SkotiqIcons.save
                          : SkotiqIcons.visible,
                      size: ButtonSize.small,
                      variant: ButtonVariant.ghost,
                      semanticsHint: saveLoopFrames
                          ? 'Loop frames are saved to the image folder and counted in '
                              'the session'
                          : 'Loop frames are live view only — not saved, not counted',
                      // Changing it mid-loop would split one run across two
                      // destinations, so it locks while the loop is live.
                      onPressed: isLooping || isStoppingCapture
                          ? null
                          : () => ref
                              .read(loopSavesFramesProvider.notifier)
                              .set(!saveLoopFrames),
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  const StretchControls(compact: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 1 × 20 hairline between the bar's clusters.
class _BarSeparator extends StatelessWidget {
  const _BarSeparator();

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      width: 1,
      height: SkotiqTokens.spaceXl,
      margin: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceMd),
      color: colors.border,
    );
  }
}

/// Publishes the button role + enabled state for one bar action.
///
/// `excludeSemantics` drops the child's own nodes so the tree carries exactly
/// one node per control, and the tap action is republished here because
/// excluding the child's semantics also drops its gesture.
class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.label,
    required this.enabled,
    required this.onTap,
    required this.child,
    this.toggled,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Widget child;

  /// Set for the controls that are on/off rather than momentary, so a screen
  /// reader can say which way they are set.
  final bool? toggled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      toggled: toggled,
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: child,
    );
  }
}

/// Exposure length, in seconds. Commits on submit and on blur.
class _ExposureField extends StatefulWidget {
  const _ExposureField({
    required this.hostSuffix,
    required this.value,
    required this.onChanged,
  });

  final String hostSuffix;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_ExposureField> createState() => _ExposureFieldState();
}

class _ExposureFieldState extends State<_ExposureField> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  String get _formatted => widget.value.toStringAsFixed(1);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _formatted);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_ExposureField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && _formatted != _controller.text) {
      _controller.text = _formatted;
    }
  }

  void _commit() {
    final parsed = double.tryParse(_controller.text);
    if (parsed != null && parsed > 0) {
      widget.onChanged(parsed);
    } else {
      _controller.text = _formatted;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The label is published as semantics rather than drawn above the field:
    // the capture bar is one 32 px row, and a caption over each field would
    // make it two.
    return Semantics(
      label: 'Exposure${widget.hostSuffix}, seconds',
      child: SkotiqTextField(
        key: TourTarget.imagingExposureSlider.key,
        controller: _controller,
        focusNode: _focusNode,
        prefixIcon: SkotiqIcons.clock,
        suffix: 's',
        mono: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

/// Sensor gain. Same commit contract as the exposure field.
class _GainField extends StatefulWidget {
  const _GainField({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_GainField> createState() => _GainFieldState();
}

class _GainFieldState extends State<_GainField> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  String get _formatted => widget.value.toString();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _formatted);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_GainField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && _formatted != _controller.text) {
      _controller.text = _formatted;
    }
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text);
    if (parsed != null && parsed >= 0) {
      widget.onChanged(parsed);
    } else {
      _controller.text = _formatted;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Gain',
      child: SkotiqTextField(
        controller: _controller,
        focusNode: _focusNode,
        prefixIcon: SkotiqIcons.sliders,
        mono: true,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}
