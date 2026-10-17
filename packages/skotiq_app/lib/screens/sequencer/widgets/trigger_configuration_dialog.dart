import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../accessible_dropdown.dart';

enum TriggerConditionType { guidingRms, hfr, drift }

/// What a trigger does when its condition holds after a burst.
///
/// HFR, guiding RMS and drift are the software's judgment of the frames, and
/// that judgment can be wrong, so a new trigger notifies and keeps imaging
/// (owner decision 2026-10-06: only a risk to the hardware stops a run by
/// itself). Pausing and ending the run stay available for the operator who
/// picks them.
enum TriggerActionType { notify, pauseAndRecalibrate, autofocus, abort }

/// Default threshold for each condition type. Switching condition type in the
/// editor MUST reset the active threshold to the matching default, because the
/// underlying physical unit changes (arcseconds for guiding RMS, pixels for
/// HFR, pixels per axis for drift), so reusing the prior numeric value across a
/// unit boundary silently changes what the trigger means.
///
///   * `guidingRms` 2.0" matches `ExposureTriggerConfig.fromNativeJson`'s
///     fallback below.
///   * `hfr` 4.0 px matches `default_hfr_threshold` in the Rust quality module.
///   * `drift` 3.0 px is PER AXIS: the Rust executor
///     (`TriggerCondition::DriftAbove`) compares each axis independently with
///     OR semantics, so 3 px catches real tracking drift without firing on
///     guider jitter.
const double _kDefaultGuidingRmsArcsec = 2.0;
const double _kDefaultHfrPixels = 4.0;
const double _kDefaultDriftRaPixels = 3.0;
const double _kDefaultDriftDecPixels = 3.0;

double _defaultThresholdFor(TriggerConditionType c) {
  switch (c) {
    case TriggerConditionType.guidingRms:
      return _kDefaultGuidingRmsArcsec;
    case TriggerConditionType.hfr:
      return _kDefaultHfrPixels;
    case TriggerConditionType.drift:
      return _kDefaultDriftRaPixels;
  }
}

/// The operator-facing name of a trigger action.
String triggerActionName(TriggerActionType action) {
  switch (action) {
    case TriggerActionType.notify:
      return 'Notify me and keep imaging';
    case TriggerActionType.pauseAndRecalibrate:
      // The run is held until the operator resumes it; nothing is
      // recalibrated automatically.
      return 'Pause until I resume';
    case TriggerActionType.autofocus:
      return 'Run autofocus';
    case TriggerActionType.abort:
      return 'End the run';
  }
}

class ExposureTriggerConfig {
  final TriggerConditionType condition;

  /// Threshold for guiding RMS (arcsec) or HFR (pixels). Unused — and
  /// intentionally NOT round-tripped — for drift conditions.
  final double threshold;

  /// RA-axis drift threshold (pixels). Only meaningful when
  /// `condition == TriggerConditionType.drift`.
  final double driftRaPx;

  /// Dec-axis drift threshold (pixels). Only meaningful when
  /// `condition == TriggerConditionType.drift`. The Rust executor
  /// (`TriggerCondition::DriftAbove`) compares this independently against the
  /// measured Dec drift, so this MUST round-trip separately from the RA value.
  final double driftDecPx;

  final TriggerActionType action;
  final double debounceSecs;

  ExposureTriggerConfig({
    required this.condition,
    required this.threshold,
    required this.action,
    this.debounceSecs = 10.0,
    double? driftRaPx,
    double? driftDecPx,
  })  : driftRaPx = driftRaPx ?? _kDefaultDriftRaPixels,
        driftDecPx = driftDecPx ?? _kDefaultDriftDecPixels;

  ExposureTriggerConfig copyWith({
    TriggerConditionType? condition,
    double? threshold,
    double? driftRaPx,
    double? driftDecPx,
    TriggerActionType? action,
    double? debounceSecs,
  }) {
    return ExposureTriggerConfig(
      condition: condition ?? this.condition,
      threshold: threshold ?? this.threshold,
      driftRaPx: driftRaPx ?? this.driftRaPx,
      driftDecPx: driftDecPx ?? this.driftDecPx,
      action: action ?? this.action,
      debounceSecs: debounceSecs ?? this.debounceSecs,
    );
  }

  Map<String, dynamic> toNativeJson() {
    final conditionJson = switch (condition) {
      TriggerConditionType.guidingRms => {'GuidingRmsAbove': threshold},
      TriggerConditionType.hfr => {'HfrAbove': threshold},
      TriggerConditionType.drift => {
          // J-X2: RA and Dec are serialised independently to match the Rust
          // `TriggerCondition::DriftAbove { ra_px, dec_px }` shape, which
          // compares each axis with its own threshold (OR semantics, see
          // sequencer/src/node/instructions/expose.rs).
          'DriftAbove': {'ra_px': driftRaPx, 'dec_px': driftDecPx},
        },
    };
    final actionJson = switch (action) {
      TriggerActionType.notify => 'Notify',
      TriggerActionType.pauseAndRecalibrate => 'PauseAndRecalibrate',
      TriggerActionType.autofocus => 'Autofocus',
      TriggerActionType.abort => 'Abort',
    };
    return {
      'condition': conditionJson,
      'action': actionJson,
      'debounce_secs': debounceSecs,
    };
  }

  factory ExposureTriggerConfig.fromNativeJson(Map<String, dynamic> json) {
    final conditionJson = json['condition'] as Map?;
    final conditionKey = conditionJson == null || conditionJson.isEmpty
        ? null
        : conditionJson.keys.first;
    final conditionValue =
        conditionKey == null ? null : conditionJson![conditionKey];
    final condition = switch (conditionKey) {
      'HfrAbove' => TriggerConditionType.hfr,
      'DriftAbove' => TriggerConditionType.drift,
      _ => TriggerConditionType.guidingRms,
    };

    // J-X2: parse RA and Dec separately, tolerating older payloads that
    // only included one of the two fields by falling back to the per-axis
    // default. The general `threshold` field is only meaningful for guiding
    // RMS / HFR conditions.
    double driftRa = _kDefaultDriftRaPixels;
    double driftDec = _kDefaultDriftDecPixels;
    double threshold;
    if (conditionKey == 'DriftAbove') {
      final driftMap = conditionValue as Map?;
      driftRa =
          (driftMap?['ra_px'] as num?)?.toDouble() ?? _kDefaultDriftRaPixels;
      driftDec =
          (driftMap?['dec_px'] as num?)?.toDouble() ?? _kDefaultDriftDecPixels;
      // Keep `threshold` populated with the RA value for any consumer that
      // still reads the legacy scalar (e.g. labels with a single number);
      // the canonical drift values live in driftRaPx/driftDecPx.
      threshold = driftRa;
    } else {
      threshold = (conditionValue as num?)?.toDouble() ??
          _defaultThresholdFor(condition);
    }

    // A stored action is the operator's choice and is kept. Only a payload
    // with no action this build knows gets the default for a new trigger.
    final action = switch (json['action'] as String?) {
      'PauseAndRecalibrate' => TriggerActionType.pauseAndRecalibrate,
      'Autofocus' => TriggerActionType.autofocus,
      'Abort' => TriggerActionType.abort,
      _ => TriggerActionType.notify,
    };
    return ExposureTriggerConfig(
      condition: condition,
      threshold: threshold,
      driftRaPx: driftRa,
      driftDecPx: driftDec,
      action: action,
      debounceSecs: (json['debounce_secs'] as num?)?.toDouble() ?? 10.0,
    );
  }

  String get conditionLabel {
    switch (condition) {
      case TriggerConditionType.guidingRms:
        return 'Guiding RMS > $threshold"';
      case TriggerConditionType.hfr:
        return 'HFR > $threshold px';
      case TriggerConditionType.drift:
        // J-X2: show both thresholds so a user with asymmetric values can
        // tell at a glance which axis would fire first.
        if (driftRaPx == driftDecPx) {
          return 'Drift > $driftRaPx px (both axes)';
        }
        return 'Drift > RA $driftRaPx px / Dec $driftDecPx px';
    }
  }

  String get actionLabel => triggerActionName(action);

  IconData get conditionIcon {
    switch (condition) {
      case TriggerConditionType.guidingRms:
        return SkotiqIcons.target;
      case TriggerConditionType.hfr:
        return SkotiqIcons.crosshair;
      case TriggerConditionType.drift:
        return SkotiqIcons.move;
    }
  }

  Color conditionColor(SkotiqColors colors) {
    switch (condition) {
      case TriggerConditionType.guidingRms:
        return colors.warning;
      case TriggerConditionType.hfr:
        return colors.info;
      case TriggerConditionType.drift:
        return colors.error;
    }
  }
}

class TriggerConfigurationDialog extends ConsumerStatefulWidget {
  final List<ExposureTriggerConfig> initialTriggers;

  /// Which nodes the saved triggers will be written to, e.g. "Applies to all
  /// 3 exposure nodes in this sequence".
  ///
  /// Triggers are stored ON exposure nodes, not on the sequence, so a dialog
  /// that names no owner lets the user believe a safety trigger was attached to
  /// whatever they had selected. The caller resolves the owners and states them
  /// here.
  final String? appliesTo;

  const TriggerConfigurationDialog({
    this.initialTriggers = const [],
    this.appliesTo,
    super.key,
  });

  @override
  ConsumerState<TriggerConfigurationDialog> createState() =>
      _TriggerConfigurationDialogState();
}

class _TriggerConfigurationDialogState
    extends ConsumerState<TriggerConfigurationDialog> {
  late List<ExposureTriggerConfig> _triggers;

  @override
  void initState() {
    super.initState();
    _triggers = List.from(widget.initialTriggers);
  }

  void _addTrigger() {
    setState(() {
      _triggers.add(ExposureTriggerConfig(
        condition: TriggerConditionType.guidingRms,
        threshold: _kDefaultGuidingRmsArcsec,
        action: TriggerActionType.notify,
      ));
    });
  }

  void _removeTrigger(int index) {
    setState(() => _triggers.removeAt(index));
  }

  void _editTrigger(int index) {
    showDialog(
      context: context,
      builder: (context) => _TriggerEditDialog(
        trigger: _triggers[index],
        onSave: (trigger) {
          setState(() => _triggers[index] = trigger);
          Navigator.of(context).pop();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);

    // Footer needs custom alignment (Add Trigger left, Cancel/Save right), so
    // we pass a single Row as the action slot. SkotiqDialog's footer is
    // a Wrap, which hands its children a bounded maxWidth — the Row (default
    // MainAxisSize.max) therefore fills the footer and the Spacer pushes
    // Cancel/Save right. Do NOT wrap this Row in Expanded: flex parent-data
    // widgets are invalid inside a Wrap and throw "Incorrect use of
    // ParentDataWidget" at mount.
    return SkotiqDialog(
      title: 'Exposure triggers',
      icon: SkotiqIcons.notifications,
      width: 600,
      height: 500,
      scrollableBody: false,
      bodyPadding: EdgeInsets.zero,
      actions: [
        SizedBox(
          width: double.maxFinite,
          child: Row(
            children: [
              SkotiqButton(
                onPressed: _addTrigger,
                icon: SkotiqIcons.add,
                label: 'Add trigger',
                variant: ButtonVariant.outline,
              ),
              const Spacer(),
              SkotiqButton(
                onPressed: () => Navigator.of(context).pop(),
                label: 'Cancel',
                variant: ButtonVariant.ghost,
              ),
              const SizedBox(width: 12),
              SkotiqButton(
                onPressed: () => Navigator.of(context).pop(_triggers),
                label: 'Save',
                variant: ButtonVariant.primary,
              ),
            ],
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.appliesTo != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              color: colors.surfaceAlt,
              child: Row(
                children: [
                  Icon(SkotiqIcons.info, size: 16, color: colors.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.appliesTo!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: _buildBody(colors, theme)),
        ],
      ),
    );
  }

  Widget _buildBody(SkotiqColors colors, ThemeData theme) {
    return _triggers.isEmpty
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  SkotiqIcons.notificationsOff,
                  size: 64,
                  color: colors.textSecondary.withValues(alpha: 0.3),
                ),
                const SizedBox(height: 16),
                Text(
                  'No triggers configured',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Add a trigger to automatically respond to conditions',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.all(24),
            // ListTile w/ subtitle (~72) + 12 bottom margin = 84.
            itemExtent: 84,
            itemCount: _triggers.length,
            itemBuilder: (context, index) {
              final trigger = _triggers[index];
              return _buildTriggerCard(trigger, index, colors, theme);
            },
          );
  }

  Widget _buildTriggerCard(
    ExposureTriggerConfig trigger,
    int index,
    SkotiqColors colors,
    ThemeData theme,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: SkotiqDecorations.tintedBadge(
            trigger.conditionColor(colors),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          ),
          child: Icon(
            trigger.conditionIcon,
            color: trigger.conditionColor(colors),
          ),
        ),
        title: Text(trigger.conditionLabel),
        subtitle: Text(
          '→ ${trigger.actionLabel}',
          style: TextStyle(color: colors.textSecondary),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(SkotiqIcons.edit),
              onPressed: () => _editTrigger(index),
              tooltip: 'Edit',
            ),
            IconButton(
              icon: const Icon(SkotiqIcons.delete),
              color: colors.error,
              onPressed: () => _removeTrigger(index),
              tooltip: 'Delete',
            ),
          ],
        ),
      ),
    );
  }
}

class _TriggerEditDialog extends StatefulWidget {
  final ExposureTriggerConfig trigger;
  final ValueChanged<ExposureTriggerConfig> onSave;

  const _TriggerEditDialog({
    required this.trigger,
    required this.onSave,
  });

  @override
  State<_TriggerEditDialog> createState() => _TriggerEditDialogState();
}

class _TriggerEditDialogState extends State<_TriggerEditDialog> {
  late TriggerConditionType _condition;
  late double _threshold;
  late double _driftRaPx;
  late double _driftDecPx;
  late TriggerActionType _action;
  late double _debounce;

  /// Set to a human-readable message when the threshold(s) were auto-reset
  /// because the user switched condition type. Displayed below the field
  /// until the next mutation. J-X3.
  String? _resetHint;

  @override
  void initState() {
    super.initState();
    _condition = widget.trigger.condition;
    _threshold = widget.trigger.threshold;
    _driftRaPx = widget.trigger.driftRaPx;
    _driftDecPx = widget.trigger.driftDecPx;
    _action = widget.trigger.action;
    _debounce = widget.trigger.debounceSecs;
  }

  void _onConditionChanged(TriggerConditionType? next) {
    if (next == null || next == _condition) return;
    setState(() {
      _condition = next;
      // J-X3: the threshold's *unit* changes with the condition (arcsec /
      // pixels / pixels-per-axis). Carrying over the raw numeric value would
      // silently reinterpret 2.0" as 2.0px (or worse). Reset to the new
      // type's sensible default and tell the user we did so.
      switch (next) {
        case TriggerConditionType.guidingRms:
          _threshold = _kDefaultGuidingRmsArcsec;
          break;
        case TriggerConditionType.hfr:
          _threshold = _kDefaultHfrPixels;
          break;
        case TriggerConditionType.drift:
          _driftRaPx = _kDefaultDriftRaPixels;
          _driftDecPx = _kDefaultDriftDecPixels;
          // Keep `_threshold` in sync with RA for any legacy consumer; the
          // executor reads driftRaPx/driftDecPx specifically.
          _threshold = _kDefaultDriftRaPixels;
          break;
      }
      _resetHint = 'Threshold reset for ${_conditionName(next)}.';
    });
  }

  String _conditionName(TriggerConditionType c) {
    switch (c) {
      case TriggerConditionType.guidingRms:
        return 'Guiding RMS';
      case TriggerConditionType.hfr:
        return 'HFR';
      case TriggerConditionType.drift:
        return 'Drift';
    }
  }

  String _getThresholdUnit() {
    switch (_condition) {
      case TriggerConditionType.guidingRms:
        return 'arcsec';
      case TriggerConditionType.hfr:
      case TriggerConditionType.drift:
        return 'pixels';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return SkotiqDialog(
      title: 'Edit trigger',
      icon: SkotiqIcons.edit,
      width: 440,
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
        ),
        SkotiqButton(
          onPressed: () {
            widget.onSave(ExposureTriggerConfig(
              condition: _condition,
              threshold: _threshold,
              driftRaPx: _driftRaPx,
              driftDecPx: _driftDecPx,
              action: _action,
              debounceSecs: _debounce,
            ));
          },
          label: 'Save',
          variant: ButtonVariant.primary,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AccessibleDropdownFormField<TriggerConditionType>(
            key: const ValueKey('trigger_condition_dropdown'),
            initialValue: _condition,
            decoration: const InputDecoration(labelText: 'Condition'),
            items: TriggerConditionType.values.map((c) {
              return DropdownMenuItem(
                value: c,
                child: Text(_conditionName(c)),
              );
            }).toList(),
            onChanged: _onConditionChanged,
          ),
          const SizedBox(height: 16),
          // Threshold field(s): drift uses two side-by-side inputs (RA / Dec),
          // every other condition uses the single `_threshold` field.
          if (_condition == TriggerConditionType.drift) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _StableNumberField(
                    key: const ValueKey('trigger_drift_ra_field'),
                    value: _driftRaPx,
                    label: 'RA drift threshold',
                    suffix: 'pixels',
                    onChanged: (v) {
                      _driftRaPx = v;
                      if (_resetHint != null) {
                        setState(() => _resetHint = null);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StableNumberField(
                    key: const ValueKey('trigger_drift_dec_field'),
                    value: _driftDecPx,
                    label: 'Dec drift threshold',
                    suffix: 'pixels',
                    onChanged: (v) {
                      _driftDecPx = v;
                      if (_resetHint != null) {
                        setState(() => _resetHint = null);
                      }
                    },
                  ),
                ),
              ],
            ),
          ] else
            _StableNumberField(
              key: const ValueKey('trigger_threshold_field'),
              value: _threshold,
              label: 'Threshold',
              suffix: _getThresholdUnit(),
              onChanged: (v) {
                _threshold = v;
                if (_resetHint != null) {
                  setState(() => _resetHint = null);
                }
              },
            ),
          if (_resetHint != null) ...[
            const SizedBox(height: 6),
            Text(
              _resetHint!,
              key: const ValueKey('trigger_threshold_reset_hint'),
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.warning,
              ),
            ),
          ],
          const SizedBox(height: 16),
          AccessibleDropdownFormField<TriggerActionType>(
            initialValue: _action,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Action',
              helperText: 'Checked after each exposure node. Notify tells '
                  'you once each time the condition starts to hold, and the '
                  'run keeps imaging.',
              helperMaxLines: 3,
            ),
            items: TriggerActionType.values.map((a) {
              return DropdownMenuItem(
                value: a,
                child: Text(triggerActionName(a)),
              );
            }).toList(),
            onChanged: (v) => setState(() => _action = v!),
          ),
          const SizedBox(height: 16),
          _StableNumberField(
            key: const ValueKey('trigger_debounce_field'),
            value: _debounce,
            label: 'Debounce time',
            suffix: 'seconds',
            helperText: 'Wait time before triggering again',
            onChanged: (v) => _debounce = v,
          ),
        ],
      ),
    );
  }
}

/// Numeric `TextField` whose controller survives rebuilds — fixes J-X1.
///
/// A fresh `TextEditingController(text: ...)` constructed inline in `build()`
/// destroys the cursor position and drops characters during fast typing,
/// because every rebuild swaps the controller and the framework treats the
/// new instance as a clean slate. This widget owns the controller across
/// rebuilds and only resynchronises `.text` from the externally-supplied
/// `value` when (a) the field doesn't have focus, i.e. the user isn't
/// actively editing, and (b) the new value actually differs from the parsed
/// current text.
///
/// Modelled on `_NumberInput` in
/// `packages/skotiq_app/lib/screens/sequencer/widgets/node_properties_panel.dart`.
class _StableNumberField extends StatefulWidget {
  final double value;
  final String label;
  final String suffix;
  final String? helperText;
  final ValueChanged<double> onChanged;

  const _StableNumberField({
    required this.value,
    required this.label,
    required this.suffix,
    required this.onChanged,
    this.helperText,
    super.key,
  });

  @override
  State<_StableNumberField> createState() => _StableNumberFieldState();
}

class _StableNumberFieldState extends State<_StableNumberField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.value));
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  static String _format(double v) {
    // Render integers without a trailing ".0" and other values with up to
    // ~3 significant fractional digits. Keeping the formatting tight avoids
    // jarring "2.0" -> "2.000000000000004" round-trips when the user only
    // wanted an integer threshold.
    if (v == v.roundToDouble()) {
      return v.toStringAsFixed(1); // "2.0" — preserves "this is a double".
    }
    return v.toString();
  }

  void _onFocusChange() {
    final hadFocus = _hasFocus;
    _hasFocus = _focusNode.hasFocus;
    // When the user leaves the field, re-canonicalise the displayed text so a
    // partially-typed value like "2." snaps back to a parseable form.
    if (hadFocus && !_hasFocus) {
      final canonical = _format(widget.value);
      if (_controller.text != canonical) {
        _controller.text = canonical;
      }
    }
  }

  @override
  void didUpdateWidget(_StableNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only resynchronise from the parent when the field is NOT focused — if
    // it IS focused, the user is mid-keystroke and overwriting their input
    // would re-introduce the original J-X1 bug.
    if (!_hasFocus && oldWidget.value != widget.value) {
      final newText = _format(widget.value);
      final parsedCurrent = double.tryParse(_controller.text);
      if (parsedCurrent == null || parsedCurrent != widget.value) {
        _controller.text = newText;
      }
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      decoration: InputDecoration(
        labelText: widget.label,
        suffix: Text(widget.suffix),
        helperText: widget.helperText,
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (v) {
        final parsed = double.tryParse(v);
        if (parsed != null) widget.onChanged(parsed);
      },
    );
  }
}
