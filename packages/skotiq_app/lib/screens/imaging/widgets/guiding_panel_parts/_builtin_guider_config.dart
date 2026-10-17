// Built-in guider configuration section, form and input row.
part of '../guiding_panel.dart';

/// Collapsible configuration panel for the built-in multi-star guider.
/// Only displayed when the built-in guider is the active guider device.
class _BuiltinGuiderConfigSection extends ConsumerWidget {
  final SkotiqColors colors;
  final bool isExpanded;
  final VoidCallback onToggle;

  const _BuiltinGuiderConfigSection({
    required this.colors,
    required this.isExpanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(builtinGuiderConfigProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with collapse toggle
        GestureDetector(
          onTap: onToggle,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Row(
              children: [
                Icon(
                  isExpanded
                      ? SkotiqIcons.chevronDown
                      : SkotiqIcons.chevronRight,
                  size: 14,
                  color: colors.textPrimary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Guider Configuration',
                  style:
                      SkotiqTypography.h6.copyWith(color: colors.textPrimary),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: SkotiqDecorations.tintedBadge(
                    colors.primary,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                  ),
                  child: Text(
                    'Built-in',
                    style: SkotiqTypography.caption.copyWith(
                        fontWeight: FontWeight.w600, color: colors.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (isExpanded) ...[
          const SizedBox(height: 12),
          configAsync.when(
            loading: () => SkotiqCard(
              padding: const EdgeInsets.all(14),
              borderRadius: SkotiqTokens.radiusLg,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
            error: (error, _) => Container(
              padding: const EdgeInsets.all(14),
              decoration: SkotiqDecorations.emphasisSurface(
                colors.error,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
              ),
              child: Text(
                'Failed to load guider config: $error',
                style: SkotiqTypography.caption.copyWith(color: colors.error),
              ),
            ),
            data: (config) => _BuiltinGuiderConfigForm(
              colors: colors,
              config: config,
            ),
          ),
        ],
      ],
    );
  }
}

/// The actual config form with editable fields.
class _BuiltinGuiderConfigForm extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final BuiltinGuiderConfig config;

  const _BuiltinGuiderConfigForm({
    required this.colors,
    required this.config,
  });

  @override
  ConsumerState<_BuiltinGuiderConfigForm> createState() =>
      _BuiltinGuiderConfigFormState();
}

class _BuiltinGuiderConfigFormState
    extends ConsumerState<_BuiltinGuiderConfigForm> {
  late TextEditingController _exposureController;
  late TextEditingController _gainController;
  late TextEditingController _calibrationMsController;
  late TextEditingController _minPulseController;
  late TextEditingController _maxPulseController;
  late TextEditingController _settleSleepController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _exposureController =
        TextEditingController(text: widget.config.exposureSecs.toString());
    _gainController =
        TextEditingController(text: widget.config.gain.toString());
    _calibrationMsController =
        TextEditingController(text: widget.config.calibrationMs.toString());
    _minPulseController =
        TextEditingController(text: widget.config.minPulseMs.toString());
    _maxPulseController =
        TextEditingController(text: widget.config.maxPulseMs.toString());
    _settleSleepController =
        TextEditingController(text: widget.config.settleSleepMs.toString());
  }

  @override
  void didUpdateWidget(_BuiltinGuiderConfigForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) {
      _exposureController.text = widget.config.exposureSecs.toString();
      _gainController.text = widget.config.gain.toString();
      _calibrationMsController.text = widget.config.calibrationMs.toString();
      _minPulseController.text = widget.config.minPulseMs.toString();
      _maxPulseController.text = widget.config.maxPulseMs.toString();
      _settleSleepController.text = widget.config.settleSleepMs.toString();
    }
  }

  @override
  void dispose() {
    _exposureController.dispose();
    _gainController.dispose();
    _calibrationMsController.dispose();
    _minPulseController.dispose();
    _maxPulseController.dispose();
    _settleSleepController.dispose();
    super.dispose();
  }

  /// Default pulse-guide bounds used when the connected mount does not report
  /// a min/max pulse-guide capability (or when no mount is connected).
  ///
  /// These mirror the conservative defaults the built-in guider assumes when a
  /// mount cannot describe its own pulse-guide envelope.
  static const double _defaultPulseMinMs = 75.0;
  static const double _defaultPulseMaxMs = 1200.0;

  /// Resolves the active mount's pulse-guide bounds from its reported
  /// capabilities, falling back to [_defaultPulseMinMs]/[_defaultPulseMaxMs]
  /// when the mount is absent or does not advertise the range.
  ///
  /// These bounds constrain ONLY the editor inputs — they never mutate the
  /// [BuiltinGuiderConfig], which carries the guider's real operating clamps
  /// from Rust.
  ({double min, double max}) _pulseBounds(MountCapabilities? caps) {
    final pulseMin = caps?.minPulseGuideMs ?? _defaultPulseMinMs;
    final pulseMax = caps?.maxPulseGuideMs ?? _defaultPulseMaxMs;
    return (min: pulseMin, max: pulseMax);
  }

  Future<void> _applyConfig(MountCapabilities? mountCaps) async {
    if (_saving) return;
    final exposure = double.tryParse(_exposureController.text);
    final gain = int.tryParse(_gainController.text);
    final calibrationMs = int.tryParse(_calibrationMsController.text);
    final minPulse = double.tryParse(_minPulseController.text);
    final maxPulse = double.tryParse(_maxPulseController.text);
    final settleSleep = int.tryParse(_settleSleepController.text);

    if (exposure == null ||
        gain == null ||
        calibrationMs == null ||
        minPulse == null ||
        maxPulse == null ||
        settleSleep == null) {
      context.showErrorSnackBar('Invalid config value');
      return;
    }

    // Bound the entered pulse range to the connected mount's reported
    // pulse-guide envelope: surface the rejection and block the save rather
    // than silently clamping to a value the mount cannot honor.
    final bounds = _pulseBounds(mountCaps);
    if (minPulse < bounds.min) {
      context.showErrorSnackBar(
        'Min pulse ${minPulse.toStringAsFixed(0)} ms is below the mount '
        'minimum of ${bounds.min.toStringAsFixed(0)} ms',
      );
      return;
    }
    if (maxPulse > bounds.max) {
      context.showErrorSnackBar(
        'Max pulse ${maxPulse.toStringAsFixed(0)} ms exceeds the mount '
        'maximum of ${bounds.max.toStringAsFixed(0)} ms',
      );
      return;
    }
    if (minPulse > maxPulse) {
      context.showErrorSnackBar(
        'Min pulse ${minPulse.toStringAsFixed(0)} ms cannot exceed max pulse '
        '${maxPulse.toStringAsFixed(0)} ms',
      );
      return;
    }

    final newConfig = widget.config.copyWith(
      exposureSecs: exposure,
      gain: gain,
      calibrationMs: calibrationMs,
      minPulseMs: minPulse,
      maxPulseMs: maxPulse,
      settleSleepMs: settleSleep,
    );

    setState(() => _saving = true);
    try {
      await ref
          .read(builtinGuiderConfigProvider.notifier)
          .updateConfig(newConfig);
    } catch (e) {
      if (mounted) context.showErrorSnackBar('Failed to apply settings: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetDefaults() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(builtinGuiderConfigProvider.notifier).resetToDefaults();
      if (mounted) context.showSuccessSnackBar('Guider defaults restored');
    } catch (e) {
      if (mounted) context.showErrorSnackBar('Failed to reset settings: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Resolve the connected mount's pulse-guide capability envelope. When no
    // mount is connected (or it reports no device id), capabilities resolve to
    // null and the conservative built-in defaults apply.
    final mountState = ref.watch(mountStateProvider);
    final mountDeviceId =
        mountState.connectionState == DeviceConnectionState.connected
            ? mountState.deviceId
            : null;
    final MountCapabilities? mountCaps =
        (mountDeviceId != null && mountDeviceId.isNotEmpty)
            ? ref.watch(mountCapabilitiesProvider(mountDeviceId)).valueOrNull
            : null;
    final pulseBounds = _pulseBounds(mountCaps);

    // Helper hint shown on the pulse fields only when the mount actually
    // reports a range (honest-None: don't fabricate a range from defaults).
    final String? pulseRangeHint =
        mountCaps?.minPulseGuideMs != null && mountCaps?.maxPulseGuideMs != null
            ? 'Mount supports ${pulseBounds.min.toStringAsFixed(0)}-'
                '${pulseBounds.max.toStringAsFixed(0)} ms'
            : null;

    return SkotiqCard(
      padding: const EdgeInsets.all(14),
      borderRadius: SkotiqTokens.radiusLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ConfigInputRow(
            label: 'Exposure',
            controller: _exposureController,
            suffix: 's',
            colors: widget.colors,
            onSubmitted: (_) => _applyConfig(mountCaps),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 10),
          _ConfigInputRow(
            label: 'Gain',
            controller: _gainController,
            colors: widget.colors,
            onSubmitted: (_) => _applyConfig(mountCaps),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(height: 10),
          _ConfigInputRow(
            label: 'Cal. Pulse',
            controller: _calibrationMsController,
            suffix: 'ms',
            colors: widget.colors,
            onSubmitted: (_) => _applyConfig(mountCaps),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(height: 10),
          _ConfigInputRow(
            label: 'Min pulse',
            controller: _minPulseController,
            suffix: 'ms',
            helperText: pulseRangeHint,
            helpId: FieldHelpId.guideMinPulse,
            colors: widget.colors,
            onSubmitted: (_) => _applyConfig(mountCaps),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 10),
          _ConfigInputRow(
            label: 'Max pulse',
            controller: _maxPulseController,
            suffix: 'ms',
            helperText: pulseRangeHint,
            colors: widget.colors,
            onSubmitted: (_) => _applyConfig(mountCaps),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 10),
          _ConfigInputRow(
            label: 'Settle sleep',
            controller: _settleSleepController,
            suffix: 'ms',
            colors: widget.colors,
            onSubmitted: (_) => _applyConfig(mountCaps),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SmallButton(
                  label: 'Apply',
                  icon: SkotiqIcons.check,
                  colors: widget.colors,
                  isEnabled: !_saving,
                  onTap: () => _applyConfig(mountCaps),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SmallButton(
                  label: 'Reset defaults',
                  icon: SkotiqIcons.undo,
                  isOutline: true,
                  colors: widget.colors,
                  isEnabled: !_saving,
                  onTap: _resetDefaults,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A single config input row with label, text field, and optional suffix.
class _ConfigInputRow extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? suffix;

  /// Optional helper hint rendered beneath the input (e.g. the supported
  /// pulse-guide range reported by the connected mount).
  final String? helperText;

  /// Optional field-level help. When supplied, a [helpAffordance] icon hugs the
  /// label text showing the rich tooltip from [helpFor]. Used for genuinely
  /// non-obvious built-in-guider parameters (e.g. the millisecond min-pulse).
  final FieldHelpId? helpId;
  final SkotiqColors colors;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  const _ConfigInputRow({
    required this.label,
    required this.controller,
    this.suffix,
    this.helperText,
    this.helpId,
    required this.colors,
    this.onSubmitted,
    this.keyboardType,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    final labelStyle =
        SkotiqTypography.caption.copyWith(color: colors.textSecondary);
    final id = helpId;
    final Widget labelWidget = id == null
        ? Text(label, style: labelStyle)
        : Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(child: Text(label, style: labelStyle)),
              const SizedBox(width: SkotiqTokens.spaceXs),
              Builder(
                builder: (context) {
                  final copy = helpFor(id);
                  return helpAffordance(
                    context,
                    title: copy.title,
                    body: copy.body,
                  );
                },
              ),
            ],
          );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: labelWidget,
          ),
        ),
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                  border: Border.all(color: colors.border),
                ),
                child: TextField(
                  controller: controller,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textPrimary),
                  decoration: InputDecoration(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: InputBorder.none,
                    isDense: true,
                    suffixText: suffix,
                    suffixStyle: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                  ),
                  keyboardType: keyboardType,
                  inputFormatters: inputFormatters,
                  onSubmitted: onSubmitted,
                ),
              ),
              if (helperText != null) ...[
                const SizedBox(height: 4),
                Text(
                  helperText!,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textMuted),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
