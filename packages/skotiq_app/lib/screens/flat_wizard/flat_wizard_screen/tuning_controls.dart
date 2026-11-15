part of '../flat_wizard_screen.dart';

/// A slider with its value at the right, in a fixed column so two sliders in
/// one form end at the same place.
class _SliderWithReadout extends StatelessWidget {
  const _SliderWithReadout({
    required this.value,
    required this.min,
    required this.max,
    required this.readout,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final String readout;
  final ValueChanged<double> onChanged;

  static const double _readoutWidth = 48;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      children: [
        Expanded(
          child: SkotiqSlider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        SizedBox(
          width: _readoutWidth,
          child: Text(
            readout,
            textAlign: TextAlign.right,
            style:
                SkotiqTypography.readoutSm.copyWith(color: colors.textPrimary),
          ),
        ),
      ],
    );
  }
}

/// How the exposure for each filter is found: the level to reach, how close
/// counts, and how many test exposures the search may take.
class _ExposurePanel extends ConsumerWidget {
  const _ExposurePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final config = ref.watch(flatCameraConfigProvider);
    final target = state.globalSettings.histogramTarget;

    // The target as an ADU against the camera's detected full scale, so a
    // 12-bit camera reads 4095 and the percentage has a plain meaning.
    final depth = config.bitDepth != null ? ' · ${config.bitDepth}-bit' : '';
    final targetAdu = '~${config.targetAduFor(target).round()} of '
        '${config.maxAdu} ADU$depth';

    return FlatWizardPanel(
      title: 'Exposure',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.mode == FlatWizardMode.skyFlats) ...[
            FormRow(
              label: 'Twilight',
              labelWidth: _formLabelWidth,
              help: state.twilightMode == TwilightMode.dawn
                  ? 'The sky is brightening, so exposures shorten.'
                  : 'The sky is darkening, so exposures lengthen.',
              child: Align(
                alignment: Alignment.centerLeft,
                child: SegmentedControl(
                  segments: const ['Dawn', 'Dusk'],
                  selectedIndex: state.twilightMode.index,
                  semanticLabel: 'Twilight',
                  onSelected: (i) =>
                      notifier.setTwilightMode(TwilightMode.values[i]),
                ),
              ),
            ),
            const SizedBox(height: FormRow.rowGap),
          ],
          FormRow(
            key: TourTarget.flatTargetAdu.key,
            label: 'Histogram target',
            labelWidth: _formLabelWidth,
            help: targetAdu,
            child: _SliderWithReadout(
              value: target,
              min: 10,
              max: 90,
              readout: '${target.toStringAsFixed(0)}%',
              onChanged: notifier.setHistogramTarget,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Tolerance',
            labelWidth: _formLabelWidth,
            child: _SliderWithReadout(
              value: state.globalSettings.tolerancePercent,
              min: 1,
              max: 25,
              readout:
                  '±${state.globalSettings.tolerancePercent.toStringAsFixed(0)}%',
              onChanged: notifier.setTolerance,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          const _CalibrationAttemptsRow(),
        ],
      ),
    );
  }
}

/// The gain, offset and binning the run commands when a filter sets none of
/// its own, with a warning when they differ from the light-frame settings.
///
/// Flats resolve these from the equipment profile and the camera's live
/// values; lights use the exposure settings. When the two differ the flats
/// carry another pedestal and the library matcher refuses them (gain, offset
/// and binning must match exactly), so the numbers are shown before the run.
class _CameraPanel extends ConsumerWidget {
  const _CameraPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(flatCameraConfigProvider);
    final lights = ref.watch(exposureSettingsProvider);

    // "driver default" is a real state: the camera is commanded, with a value
    // this screen did not choose. An unknown value is an em dash.
    const String driverDefault = 'driver default';
    final sensitivity = config.sensitivity;
    final rows = <(String, String)>[
      if (sensitivity.hasGain)
        (
          sensitivity.label,
          config.canSetGain
              ? (config.gain?.toString() ?? driverDefault)
              : kReadoutUnknown,
        ),
      if (sensitivity.hasOffset)
        (
          'Offset',
          config.canSetOffset
              ? (config.offset?.toString() ?? driverDefault)
              : kReadoutUnknown,
        ),
      ('Binning', '${config.binX}×${config.binY}'),
    ];

    final mismatches = <String>[
      if (config.canSetGain &&
          config.gain != null &&
          config.gain != lights.gain)
        '${sensitivity.describe(config.gain!)} vs ${lights.gain}',
      if (config.canSetOffset &&
          config.offset != null &&
          config.offset != lights.offset)
        'offset ${config.offset} vs ${lights.offset}',
      if (config.binX != lights.binningX || config.binY != lights.binningY)
        'binning ${config.binX}×${config.binY} vs '
            '${lights.binningX}×${lights.binningY}',
    ];

    return FlatWizardPanel(
      title: 'Camera',
      note: _cameraDefaultsNote(sensitivity),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mismatches.isNotEmpty) ...[
            SkotiqBanner(
              tone: BannerTone.warning,
              title: 'These differ from the light settings',
              message: '${mismatches.join(', ')}. Set each filter above to '
                  'match the lights it calibrates.',
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
          ],
          KeyValueList(rows: rows),
        ],
      ),
    );
  }
}

/// Editable frame count with stepper controls for small adjustments.
class _FrameCountInput extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _FrameCountInput({
    super.key,
    required this.value,
    required this.onChanged,
    this.minValue = minFrames,
    this.maxValue = maxFrames,
    this.fewerTooltip = 'One fewer frame',
    this.moreTooltip = 'One more frame',
  });

  /// The range `FlatWizardNotifier.setFrameCount` clamps to. Mirrored here so a
  /// typed value is corrected in the field the user is looking at rather than
  /// silently snapping somewhere else.
  static const int minFrames = 1;
  static const int maxFrames = 999;

  /// The range this field accepts; the frame count's unless given.
  final int minValue;
  final int maxValue;
  final String fewerTooltip;
  final String moreTooltip;

  @override
  State<_FrameCountInput> createState() => _FrameCountInputState();
}

class _FrameCountInputState extends State<_FrameCountInput> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.value}');
    _focusNode = FocusNode()..addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _FrameCountInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Never overwrite what the user is mid-way through typing; the steppers and
    // the persisted settings still push their value in when the field is idle.
    if (_focusNode.hasFocus) return;
    if (widget.value != oldWidget.value ||
        int.tryParse(_controller.text) != widget.value) {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) _commit();
  }

  /// Apply the typed text, then normalise the field to whatever survived
  /// clamping — a blank or out-of-range entry snaps back visibly instead of
  /// leaving the field disagreeing with the run it will start.
  void _commit() {
    final typed = int.tryParse(_controller.text.trim());
    final resolved = typed == null
        ? widget.value
        : typed.clamp(widget.minValue, widget.maxValue);
    if (resolved != widget.value) widget.onChanged(resolved);
    if (_controller.text != '$resolved') _controller.text = '$resolved';
  }

  void _step(int delta) {
    final next = (widget.value + delta).clamp(widget.minValue, widget.maxValue);
    if (next == widget.value) return;
    _controller.text = '$next';
    widget.onChanged(next);
  }

  /// Width of the typed count field: three digits plus the field's padding.
  static const double _fieldWidth = 62;

  @override
  Widget build(BuildContext context) {
    // A stepper around a typed field: the count runs to 999.
    //
    // The TapRegion drops focus on a tap anywhere else on every platform
    // (Flutter keeps focus on a touch outside so a phone keyboard stays up),
    // so the field commits before a press on Start reads the count.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqIconButton(
          icon: LucideIcons.minus,
          tooltip: widget.fewerTooltip,
          size: IconButtonSize.sm,
          onPressed: widget.value > widget.minValue ? () => _step(-1) : null,
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        // Flexible: a form row's control column narrows to 72 px on a phone.
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _fieldWidth),
            child: TapRegion(
              onTapOutside: (_) {
                if (_focusNode.hasFocus) _focusNode.unfocus();
              },
              child: SkotiqTextField(
                controller: _controller,
                focusNode: _focusNode,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                dense: true,
                mono: true,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                onSubmitted: (_) => _commit(),
              ),
            ),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        SkotiqIconButton(
          icon: LucideIcons.plus,
          tooltip: widget.moreTooltip,
          size: IconButtonSize.sm,
          onPressed: widget.value < widget.maxValue ? () => _step(1) : null,
        ),
      ],
    );
  }
}

/// How many test exposures each filter's exposure search may take. An app
/// setting, so the imaging computer and a linked desktop share one value and
/// every flat path (sky, panel, a sequence's flat step, an API run) uses it.
class _CalibrationAttemptsRow extends ConsumerWidget {
  const _CalibrationAttemptsRow();

  static const int minAttempts = 1;
  static const int maxAttempts = 100;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attempts = ref.watch(
      appSettingsProvider.select(
        (s) => s.valueOrNull?.flatCalibrationAttempts ?? 20,
      ),
    );
    return FormRow(
      label: FlatWizardService.attemptsSettingName,
      labelWidth: _formLabelWidth,
      child: _FrameCountInput(
        key: const ValueKey('flat-calibration-attempts'),
        value: attempts,
        minValue: minAttempts,
        maxValue: maxAttempts,
        fewerTooltip: 'One fewer attempt',
        moreTooltip: 'One more attempt',
        onChanged: (value) => ref
            .read(appSettingsProvider.notifier)
            .setFlatCalibrationAttempts(value),
      ),
    );
  }
}
