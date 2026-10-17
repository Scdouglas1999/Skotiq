// Rotation field, its state and the rotation step button.
part of '../framing_controls.dart';

/// The framing frame-rotation control: a snapped slider PLUS exact numeric
/// entry and coarse/fine step buttons.
///
/// Rotation is the number an imager dials into a rotator's position angle, so it
/// has to be settable EXACTLY. A bare [FramingSliderField] is a ~117 px track
/// spanning 360° — about 3.1° per pixel — with a read-only degree label, so no
/// specific angle is reachable. This widget keeps the slider for coarse
/// dragging but:
///
///  * snaps it to whole degrees (`divisions: 360`), which also gives the slider
///    a 1° arrow-key nudge once focused (Flutter derives the keyboard step from
///    the division size; without divisions it is (max-min)/10 = 36°);
///  * adds a numeric field that accepts a typed angle (commit on Enter or on
///    focus loss);
///  * adds -90 / -1 / +1 / +90 buttons so the cardinal angles are one tap away.
///
/// Values are handed to [onChanged] unnormalized; the framing notifier owns the
/// canonical [-180, 180) wrap, so 270 typed here becomes -90.
class FramingRotationField extends StatefulWidget {
  final double value;
  final SkotiqColors colors;

  /// Null disables the whole control (no equipment configured).
  final ValueChanged<double>? onChanged;

  const FramingRotationField({
    super.key,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  @override
  State<FramingRotationField> createState() => _FramingRotationFieldState();
}

class _FramingRotationFieldState extends State<FramingRotationField> {
  late final TextEditingController _controller =
      TextEditingController(text: _format(widget.value));
  late final FocusNode _focusNode = FocusNode();

  /// The slider's own focus node. Held here (rather than left implicit) so
  /// interacting with the track takes keyboard focus — the reported gap was that
  /// Left/Right did nothing *after clicking the track*, because the slider was
  /// never focused and so never received the key events.
  late final FocusNode _sliderFocusNode =
      FocusNode(debugLabel: 'FramingRotationSlider');

  static String _format(double value) => value.round().toString();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(FramingRotationField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Mirror an external change (slider drag, canvas rotation handle) into the
    // field — but never while the user is mid-edit in it.
    if (widget.value != oldWidget.value && !_focusNode.hasFocus) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _sliderFocusNode.dispose();
    super.dispose();
  }

  /// Parse and apply the typed angle. Unparseable text reverts to the live
  /// value rather than silently applying a wrong rotation.
  ///
  /// Idempotent: committing a value that is already current emits nothing. This
  /// matters because a commit happens on BOTH Enter and focus loss, so a submit
  /// runs it twice — without the guard the second pass re-applied the value the
  /// first pass had just reverted to, turning "reverted" into a real write.
  void _commit() {
    final onChanged = widget.onChanged;
    final parsed = double.tryParse(_controller.text.trim());
    if (onChanged == null || parsed == null || !parsed.isFinite) {
      _controller.text = _format(widget.value);
      return;
    }
    final wrapped = _wrap(parsed);
    if ((wrapped - _wrap(widget.value)).abs() < 1e-9) {
      // Already there — normalize the text only.
      _controller.text = _format(widget.value);
      return;
    }
    onChanged(parsed);
    // Re-render from the notifier's normalized value (e.g. 270 -> -90).
    _controller.text = _format(wrapped);
  }

  /// The same [-180, 180) fold the framing notifier applies, so the field shows
  /// what the rest of the app will hold.
  static double _wrap(double degrees) {
    var normalized = degrees % 360;
    if (normalized >= 180) {
      normalized -= 360;
    } else if (normalized < -180) {
      normalized += 360;
    }
    return normalized;
  }

  void _step(double delta) {
    final onChanged = widget.onChanged;
    if (onChanged == null) return;
    onChanged(widget.value + delta);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final enabled = widget.onChanged != null;
    // The slider domain is [-180, 180); the notifier never holds exactly 180, so
    // clamp defensively rather than letting Slider assert on a stale value.
    final sliderValue = widget.value.clamp(-180.0, 180.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Rotation',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary),
              ),
            ),
            SizedBox(
              width: 76,
              child: SkotiqTextField(
                key: const Key('framing_rotation_input'),
                controller: _controller,
                focusNode: _focusNode,
                enabled: enabled,
                suffix: '°',
                textAlign: TextAlign.right,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]')),
                ],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _commit(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            _RotationStepButton(
              label: '-90',
              colors: colors,
              onTap: enabled ? () => _step(-90) : null,
            ),
            _RotationStepButton(
              label: '-1',
              colors: colors,
              onTap: enabled ? () => _step(-1) : null,
            ),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  activeTrackColor: colors.primary,
                  inactiveTrackColor: colors.border,
                  thumbColor: colors.primary,
                  overlayColor: colors.primary.withValues(alpha: 0.1),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  // 360 divisions would otherwise draw 361 tick marks.
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                  showValueIndicator: ShowValueIndicator.onlyForDiscrete,
                ),
                child: Slider(
                  value: sliderValue,
                  min: -180,
                  max: 180,
                  // Whole-degree snapping: makes a drag land on an exact degree
                  // and gives the focused slider a 1° arrow-key step.
                  divisions: 360,
                  label: '${sliderValue.round()}°',
                  focusNode: _sliderFocusNode,
                  // Take keyboard focus on ANY track interaction, so the arrow
                  // keys work straight after a click. This has to be
                  // onChangeStart, not onChanged: a tap that lands on the
                  // thumb's current position changes nothing and so never fires
                  // onChanged, which is exactly the "clicked the track, arrows
                  // still dead" case.
                  onChangeStart: enabled
                      ? (_) {
                          if (!_sliderFocusNode.hasFocus) {
                            _sliderFocusNode.requestFocus();
                          }
                        }
                      : null,
                  onChanged:
                      enabled ? (value) => widget.onChanged!(value) : null,
                ),
              ),
            ),
            _RotationStepButton(
              label: '+1',
              colors: colors,
              onTap: enabled ? () => _step(1) : null,
            ),
            _RotationStepButton(
              label: '+90',
              colors: colors,
              onTap: enabled ? () => _step(90) : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// A compact ±step button for [FramingRotationField].
class _RotationStepButton extends StatelessWidget {
  final String label;
  final SkotiqColors colors;
  final VoidCallback? onTap;

  const _RotationStepButton({
    required this.label,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: 'Nudge rotation by $label°',
      child: InkWell(
        onTap: onTap,
        borderRadius: SkotiqTokens.borderRadiusInline4,
        child: Container(
          width: 30,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: SkotiqTokens.borderRadiusInline4,
            border: Border.all(color: colors.border),
          ),
          child: Text(
            label,
            style: SkotiqTypography.caption.copyWith(
                color: enabled ? colors.textPrimary : colors.textMuted,
                fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}
