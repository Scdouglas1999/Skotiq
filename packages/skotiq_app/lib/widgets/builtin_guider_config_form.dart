import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../utils/snackbar_helper.dart';
import 'help/field_help_copy.dart';
import 'help/field_help_label.dart';

/// The built-in guider's settings, edited together and sent to the guider in
/// one go when Apply is pressed: they are interdependent and the guider may
/// be running. What is typed and not yet sent is marked as such.
class BuiltinGuiderConfigForm extends ConsumerStatefulWidget {
  const BuiltinGuiderConfigForm({super.key});

  @override
  ConsumerState<BuiltinGuiderConfigForm> createState() =>
      _BuiltinGuiderConfigFormState();
}

class _Field {
  const _Field(this.key, this.label, this.subtitle, this.read,
      {this.decimal = false, this.suffix, this.helpId});

  final String key;
  final String label;
  final String subtitle;
  final num Function(BuiltinGuiderConfig config) read;
  final bool decimal;
  final String? suffix;
  final FieldHelpId? helpId;
}

const _exposure = _Field(
  'builtin-guider-exposure',
  'Exposure',
  'Guide-frame length. Longer averages out seeing; shorter reacts faster.',
  _exposureOf,
  decimal: true,
  suffix: 's',
);
const _gain = _Field(
  'builtin-guider-gain',
  'Gain',
  'Guide-camera gain. Raise to find stars in poor seeing.',
  _gainOf,
);
const _offset = _Field(
  'builtin-guider-offset',
  'Offset',
  'Guide-camera offset (black-level pedestal).',
  _offsetOf,
);
const _binning = _Field(
  'builtin-guider-binning',
  'Binning',
  'Combine pixels to boost star SNR at the cost of resolution.',
  _binningOf,
);
const _calibration = _Field(
  'builtin-guider-calibration-ms',
  'Calibration pulse',
  'Mount move per calibration step. Longer for short focal lengths.',
  _calibrationOf,
  suffix: 'ms',
);
const _minPulse = _Field(
  'builtin-guider-min-pulse',
  'Min pulse',
  'Corrections shorter than this are skipped to avoid chasing seeing.',
  _minPulseOf,
  decimal: true,
  suffix: 'ms',
  helpId: FieldHelpId.guideMinPulse,
);
const _maxPulse = _Field(
  'builtin-guider-max-pulse',
  'Max pulse',
  'Corrections are clamped to this so one bad frame cannot lurch the mount.',
  _maxPulseOf,
  decimal: true,
  suffix: 'ms',
);
const _settleSleep = _Field(
  'builtin-guider-settle-sleep',
  'Settle sleep',
  'Wait between settle checks after a dither or slew.',
  _settleSleepOf,
  suffix: 'ms',
);

num _exposureOf(BuiltinGuiderConfig c) => c.exposureSecs;
num _gainOf(BuiltinGuiderConfig c) => c.gain;
num _offsetOf(BuiltinGuiderConfig c) => c.offset;
num _binningOf(BuiltinGuiderConfig c) => c.binning;
num _calibrationOf(BuiltinGuiderConfig c) => c.calibrationMs;
num _minPulseOf(BuiltinGuiderConfig c) => c.minPulseMs;
num _maxPulseOf(BuiltinGuiderConfig c) => c.maxPulseMs;
num _settleSleepOf(BuiltinGuiderConfig c) => c.settleSleepMs;

const _fields = [
  _exposure,
  _gain,
  _offset,
  _binning,
  _calibration,
  _minPulse,
  _maxPulse,
  _settleSleep,
];

class _BuiltinGuiderConfigFormState
    extends ConsumerState<BuiltinGuiderConfigForm> {
  late final Map<_Field, TextEditingController> _controllers = {
    for (final field in _fields) field: TextEditingController(),
  };

  /// The configuration the guider runs, as last read or applied; null until
  /// the first read.
  BuiltinGuiderConfig? _running;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final loaded = ref.read(builtinGuiderConfigProvider).valueOrNull;
    if (loaded != null) {
      _running = loaded;
      _show(loaded);
    }
    for (final controller in _controllers.values) {
      controller.addListener(_onEdited);
    }
    // Values typed for one host are never sent to, or kept for, another.
    ref.listenManual<SkotiqBackend>(backendProvider, (previous, next) {
      if (identical(previous, next)) return;
      setState(() {
        _running = null;
        _saving = false;
      });
    });
    // A read that lands while the operator is typing updates what is
    // running and leaves the typed values alone.
    ref.listenManual<AsyncValue<BuiltinGuiderConfig>>(
      builtinGuiderConfigProvider,
      (previous, next) {
        final config = next.valueOrNull;
        if (config == null || _saving) return;
        final running = _running;
        final editing = running != null && _differs(running);
        setState(() => _running = config);
        if (!editing) _show(config);
      },
    );
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onEdited() {
    if (mounted) setState(() {});
  }

  void _show(BuiltinGuiderConfig config) {
    for (final field in _fields) {
      _controllers[field]!.text = field.read(config).toString();
    }
  }

  /// Compared as numbers: "1500" typed into a decimal field is the 1500.0 the
  /// guider runs. Text that is not a number yet counts as an edit.
  bool _differs(BuiltinGuiderConfig running) => _fields.any((field) {
        final typed = num.tryParse(_controllers[field]!.text.trim());
        return typed == null || typed != field.read(running);
      });

  double? _double(_Field field) =>
      double.tryParse(_controllers[field]!.text.trim());

  int? _int(_Field field) => int.tryParse(_controllers[field]!.text.trim());

  BuiltinGuiderConfig? _typed() {
    final exposure = _double(_exposure);
    final gain = _int(_gain);
    final offset = _int(_offset);
    final binning = _int(_binning);
    final calibration = _int(_calibration);
    final minPulse = _double(_minPulse);
    final maxPulse = _double(_maxPulse);
    final settleSleep = _int(_settleSleep);
    if (exposure == null ||
        gain == null ||
        offset == null ||
        binning == null ||
        calibration == null ||
        minPulse == null ||
        maxPulse == null ||
        settleSleep == null) {
      return null;
    }
    return BuiltinGuiderConfig(
      exposureSecs: exposure,
      gain: gain,
      offset: offset,
      binning: binning,
      calibrationMs: calibration,
      minPulseMs: minPulse,
      maxPulseMs: maxPulse,
      settleSleepMs: settleSleep,
    );
  }

  Future<void> _send(BuiltinGuiderConfig config, String failure) async {
    final host = ref.backendScope(alive: () => mounted);
    setState(() => _saving = true);
    try {
      await ref.read(builtinGuiderConfigProvider.notifier).updateConfig(config);
      if (host.isStale || !mounted) return;
      _running = config;
      _show(config);
    } catch (e) {
      if (host.isStale || !mounted) return;
      context.showErrorSnackBar('$failure: ${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _apply(({double min, double max})? mountRange) async {
    if (_saving) return;
    final config = _typed();
    if (config == null) {
      context.showErrorSnackBar('Every guider setting needs a number.');
      return;
    }
    final problem = config.problem(mountPulseRangeMs: mountRange);
    if (problem != null) {
      context.showErrorSnackBar(problem);
      return;
    }
    await _send(config, 'Could not apply the guider settings');
  }

  Future<void> _reset() async {
    if (_saving) return;
    await _send(
      BuiltinGuiderConfig.defaults,
      'Could not reset the guider settings',
    );
  }

  /// The pulse-guide range the connected mount reports, or null when no
  /// mount is connected or it reports none.
  ({double min, double max})? _mountPulseRange() {
    final mount = ref.watch(mountStateProvider);
    final id = mount.connectionState == DeviceConnectionState.connected
        ? mount.deviceId
        : null;
    if (id == null || id.isEmpty) return null;
    final caps = ref.watch(mountCapabilitiesProvider(id)).valueOrNull;
    final min = caps?.minPulseGuideMs;
    final max = caps?.maxPulseGuideMs;
    return min == null || max == null ? null : (min: min, max: max);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final configAsync = ref.watch(builtinGuiderConfigProvider);
    final running = _running;
    if (running == null) {
      if (configAsync.hasError) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Could not read the guider settings: '
              '${userFacingError(configAsync.error!)}',
              style: SkotiqTypography.caption.copyWith(color: colors.error),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            SkotiqButton(
              key: const ValueKey('builtin-guider-retry'),
              label: 'Retry',
              icon: SkotiqIcons.refresh,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () =>
                  ref.read(builtinGuiderConfigProvider.notifier).fetch(),
            ),
          ],
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(child: SkotiqSpinner(size: 18, color: colors.primary)),
      );
    }

    final mountRange = _mountPulseRange();
    final pending = _differs(running);
    final rangeHint = mountRange == null
        ? null
        : 'Mount supports ${mountRange.min.round()}-'
            '${mountRange.max.round()} ms';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in _fields) ...[
          _FieldRow(
            field: field,
            controller: _controllers[field]!,
            hint: field == _minPulse || field == _maxPulse ? rangeHint : null,
            enabled: !_saving,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
        ],
        Row(
          children: [
            Expanded(
              child: SkotiqButton(
                key: const ValueKey('builtin-guider-reset'),
                label: 'Reset',
                icon: SkotiqIcons.refresh,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: _saving ? null : _reset,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: SkotiqButton(
                key: const ValueKey('builtin-guider-apply'),
                label: 'Apply',
                icon: SkotiqIcons.check,
                size: ButtonSize.small,
                isLoading: _saving,
                onPressed:
                    !_saving && pending ? () => _apply(mountRange) : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        if (pending)
          Text(
            key: const ValueKey('builtin-guider-pending'),
            'Not applied yet — press Apply to send these to the guider.',
            style: SkotiqTypography.caption
                .copyWith(fontWeight: FontWeight.w600, color: colors.warning),
          ),
        Text(
          key: const ValueKey('builtin-guider-last-applied'),
          'Last applied: exp ${running.exposureSecs}s, gain ${running.gain}, '
          'bin ${running.binning}, cal ${running.calibrationMs}ms',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.field,
    required this.controller,
    required this.hint,
    required this.enabled,
  });

  final _Field field;
  final TextEditingController controller;
  final String? hint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final helpId = field.helpId;
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            field.label,
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
        ),
        if (helpId != null) ...[
          const SizedBox(width: SkotiqTokens.spaceXs),
          Builder(builder: (context) {
            final copy = helpFor(helpId);
            return helpAffordance(context, title: copy.title, body: copy.body);
          }),
        ],
      ],
    );
    final description = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        label,
        const SizedBox(height: 2),
        Text(
          hint == null ? field.subtitle : '${field.subtitle} $hint.',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
    final input = SizedBox(
      width: 110,
      child: SkotiqTextField(
        key: ValueKey(field.key),
        controller: controller,
        enabled: enabled,
        dense: true,
        suffix: field.suffix,
        textAlign: TextAlign.right,
        keyboardType: TextInputType.numberWithOptions(decimal: field.decimal),
        inputFormatters: [
          FilteringTextInputFormatter.allow(
            field.decimal ? RegExp(r'[0-9.]') : RegExp(r'[0-9]'),
          ),
        ],
      ),
    );
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 260) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            description,
            const SizedBox(height: SkotiqTokens.spaceXs),
            input,
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: description),
          const SizedBox(width: SkotiqTokens.spaceMd),
          input,
        ],
      );
    });
  }
}
