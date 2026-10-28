part of '../flat_wizard_screen.dart';

class _HistogramTargetSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  /// Effective, capability-resolved camera config. The target is shown as an
  /// absolute ADU against the DETECTED full scale (e.g. 4095 for a 12-bit
  /// camera) so the operator never targets an impossible level.
  final FlatCaptureConfig config;

  const _HistogramTargetSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.config,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;

    final targetAdu = config.targetAduFor(value).round();
    final depthLabel =
        config.bitDepth != null ? ' · ${config.bitDepth}-bit' : '';
    // "of the detected range": target ADU shown against the effective full
    // scale, so the percentage's real meaning is explicit for any bit depth.
    final aduLabel = '~$targetAdu / ${config.maxAdu} ADU$depthLabel';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // The value is a readout, not a 24px bold heading: numbers are
            // loud and labels are quiet, and the unit rides on the number
            // (02 rule 3).
            Readout(
              value: value.toStringAsFixed(0),
              unit: '%',
              size: ReadoutSize.sm,
            ),
            const Spacer(),
            Flexible(
              child: Text(
                aduLabel,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: SkotiqTypography.monoCaption.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ),
          ],
        ),
        // The kit slider, so the track, thumb and disabled state come from the
        // tokens instead of a per-call-site SliderTheme.
        SkotiqSlider(
          value: value,
          min: 10,
          max: 90,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// The gain / offset / binning the wizard will actually command, plus an
/// explicit warning when they disagree with the light-frame settings.
///
/// The flat wizard resolves its capture config from the equipment profile and
/// the camera's live values (`FlatWizardService.resolveCaptureConfig`), while
/// light frames use the app-settings exposure defaults. When those two sources
/// disagree the flats carry a different bias pedestal from the lights and the
/// library matcher rejects them outright (`flat_library_dao.dart`: "gain,
/// offset, and binning must match exactly"), so the numbers are shown here
/// rather than left to surface as a rejected calibration library.
class _CaptureConfigSummary extends ConsumerWidget {
  const _CaptureConfigSummary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(flatCameraConfigProvider);
    final lights = ref.watch(exposureSettingsProvider);

    // An unknown value is an em dash, never 'n/a' (02 rule 3). 'driver
    // default' stays: it is a real, distinct state — the camera WILL be
    // commanded, just not with a number this screen chose.
    const String driverDefault = 'driver default';
    final rows = <(String, String)>[
      (
        'Gain',
        config.canSetGain
            ? (config.gain?.toString() ?? driverDefault)
            : kReadoutUnknown,
      ),
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
        'gain ${config.gain} vs ${lights.gain}',
      if (config.canSetOffset &&
          config.offset != null &&
          config.offset != lights.offset)
        'offset ${config.offset} vs ${lights.offset}',
      if (config.binX != lights.binningX || config.binY != lights.binningY)
        'binning ${config.binX}×${config.binY} vs '
            '${lights.binningX}×${lights.binningY}',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Key/value rows, not one run-on mono line reading
        // "Gain n/a · Offset n/a · Bin 1×1".
        KeyValueList(rows: rows),
        if (mismatches.isNotEmpty) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          // The one banner style (05 §11), not a bespoke emphasis surface.
          SkotiqBanner(
            tone: BannerTone.warning,
            title: 'Inherited settings differ from current light settings',
            message: '${mismatches.join(', ')}. Set per-filter overrides above '
                'to match the lights you want to calibrate.',
          ),
        ],
      ],
    );
  }
}

class _ToleranceSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _ToleranceSlider({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Readout(
          value: '±${value.toStringAsFixed(0)}',
          unit: '%',
          size: ReadoutSize.sm,
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: SkotiqSlider(
            value: value,
            min: 1,
            max: 25,
            onChanged: onChanged,
          ),
        ),
      ],
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
  });

  /// The range `FlatWizardNotifier.setFrameCount` clamps to. Mirrored here so a
  /// typed value is corrected in the field the user is looking at rather than
  /// silently snapping somewhere else.
  static const int minFrames = 1;
  static const int maxFrames = 999;

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
        : typed.clamp(_FrameCountInput.minFrames, _FrameCountInput.maxFrames);
    if (resolved != widget.value) widget.onChanged(resolved);
    if (_controller.text != '$resolved') _controller.text = '$resolved';
  }

  void _step(int delta) {
    final next = (widget.value + delta)
        .clamp(_FrameCountInput.minFrames, _FrameCountInput.maxFrames);
    if (next == widget.value) return;
    _controller.text = '$next';
    widget.onChanged(next);
  }

  /// Width of the typed count field: three digits plus the field's padding.
  static const double _fieldWidth = 62;

  @override
  Widget build(BuildContext context) {
    // A stepper around a typed field: the count runs to 999, so the buttons
    // alone would be 998 clicks. The label lives in the FormRow that wraps
    // this, so the "Frames:" caption is gone.
    //
    // Flutter's default only drops focus on a tap outside on DESKTOP:
    // `_EditableTextTapOutsideAction` deliberately ignores a touch on
    // Android/iOS so a mobile keyboard stays up. That default is wrong for a
    // numeric field the operator types into and then reaches straight for
    // "Start capture": the tap would never unfocus, the commit would never
    // fire, and the run would use the old count while the field on screen
    // showed the new one. The TapRegion drops focus on every platform, so what
    // the field says is what the run gets.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqIconButton(
          icon: LucideIcons.minus,
          tooltip: 'One fewer frame',
          size: IconButtonSize.sm,
          onPressed: widget.value > _FrameCountInput.minFrames
              ? () => _step(-1)
              : null,
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        // Flexible, not a fixed width: FormRow squeezes its control column to
        // 72px on a 360px phone, and a rigid field overflowed the row by 43px.
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
          tooltip: 'One more frame',
          size: IconButtonSize.sm,
          onPressed:
              widget.value < _FrameCountInput.maxFrames ? () => _step(1) : null,
        ),
      ],
    );
  }
}

class _TwilightModeSelector extends StatelessWidget {
  final TwilightMode mode;
  final ValueChanged<TwilightMode> onChanged;

  const _TwilightModeSelector({
    required this.mode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;

    return Row(
      children: [
        Expanded(
          child: _TwilightOption(
            icon: LucideIcons.sunrise,
            label: 'Dawn',
            description: 'Brightening sky',
            isSelected: mode == TwilightMode.dawn,
            onTap: () => onChanged(TwilightMode.dawn),
            colors: colors,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _TwilightOption(
            icon: LucideIcons.sunset,
            label: 'Dusk',
            description: 'Darkening sky',
            isSelected: mode == TwilightMode.dusk,
            onTap: () => onChanged(TwilightMode.dusk),
            colors: colors,
          ),
        ),
      ],
    );
  }
}

class _TwilightOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final bool isSelected;
  final VoidCallback onTap;
  final SkotiqColors colors;

  const _TwilightOption({
    required this.icon,
    required this.label,
    required this.description,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        decoration: BoxDecoration(
          color: isSelected ? colors.surfaceHover : colors.well,
          borderRadius: SkotiqTokens.borderRadiusSm,
          border: Border.all(
            color: isSelected ? colors.primary : colors.borderHighlight,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: SkotiqTokens.iconMd,
              color: isSelected ? colors.primary : colors.textMuted,
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              label,
              style: SkotiqTypography.bodyStrong.copyWith(
                color: isSelected ? colors.textPrimary : colors.textSecondary,
              ),
            ),
            Text(
              description,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
