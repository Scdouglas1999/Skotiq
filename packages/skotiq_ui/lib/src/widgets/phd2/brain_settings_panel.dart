import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../theme/skotiq_colors.dart';

/// A parameter value in the PHD2 Brain
class BrainParam {
  final String name;
  final double value;
  final double? min;
  final double? max;
  final String? description;

  const BrainParam({
    required this.name,
    required this.value,
    this.min,
    this.max,
    this.description,
  });

  BrainParam copyWith({double? value}) {
    return BrainParam(
      name: name,
      value: value ?? this.value,
      min: min,
      max: max,
      description: description,
    );
  }
}

/// Panel for viewing and editing PHD2 Brain guide algorithm parameters
class BrainSettingsPanel extends StatefulWidget {
  /// RA axis parameters
  final List<BrainParam> raParams;

  /// Dec axis parameters
  final List<BrainParam> decParams;

  /// Whether the panel is in edit mode
  final bool isEditing;

  /// Writes one changed parameter when Apply is pressed. Changes are kept as
  /// local drafts while the user types so partial numbers and rapid keystrokes
  /// never become out-of-order hardware commands.
  final Future<void> Function(String axis, String name, double value)?
  onParamChanged;

  /// Callback when Apply is pressed
  final Future<void> Function()? onApply;

  /// Callback when Reset is pressed
  final Future<void> Function()? onReset;

  /// Whether changes are being applied
  final bool isApplying;

  const BrainSettingsPanel({
    super.key,
    required this.raParams,
    required this.decParams,
    this.isEditing = false,
    this.onParamChanged,
    this.onApply,
    this.onReset,
    this.isApplying = false,
  });

  @override
  State<BrainSettingsPanel> createState() => _BrainSettingsPanelState();
}

class _BrainSettingsPanelState extends State<BrainSettingsPanel> {
  final Map<String, TextEditingController> _controllers = {};
  bool _hasChanges = false;
  bool _applying = false;
  String? _errorText;

  bool get _isBusy => widget.isApplying || _applying;

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  void _initControllers() {
    for (final param in widget.raParams) {
      _controllers['ra_${param.name}'] = TextEditingController(
        text: param.value.toStringAsFixed(2),
      );
    }
    for (final param in widget.decParams) {
      _controllers['dec_${param.name}'] = TextEditingController(
        text: param.value.toStringAsFixed(2),
      );
    }
  }

  @override
  void didUpdateWidget(BrainSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final expectedKeys = <String>{};
    for (final param in widget.raParams) {
      final key = 'ra_${param.name}';
      expectedKeys.add(key);
      _controllers.putIfAbsent(
        key,
        () => TextEditingController(text: param.value.toStringAsFixed(2)),
      );
    }
    for (final param in widget.decParams) {
      final key = 'dec_${param.name}';
      expectedKeys.add(key);
      _controllers.putIfAbsent(
        key,
        () => TextEditingController(text: param.value.toStringAsFixed(2)),
      );
    }
    for (final key in _controllers.keys.toList()) {
      if (!expectedKeys.contains(key)) _controllers.remove(key)?.dispose();
    }

    // Update controllers if params changed externally.
    if (!_hasChanges) {
      _restoreControllers();
    }
  }

  void _restoreControllers() {
    for (final param in widget.raParams) {
      _controllers['ra_${param.name}']?.text = param.value.toStringAsFixed(2);
    }
    for (final param in widget.decParams) {
      _controllers['dec_${param.name}']?.text = param.value.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          _buildHeader(colors),
          // Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildAxisSection('RA', widget.raParams, 'ra', colors),
                  const SizedBox(height: 20),
                  _buildAxisSection('Dec', widget.decParams, 'dec', colors),
                ],
              ),
            ),
          ),
          // Actions
          if (_hasChanges) _buildActions(colors),
        ],
      ),
    );
  }

  Widget _buildHeader(SkotiqColors colors) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Compact layout for narrow panels
        final isCompact = constraints.maxWidth < 280;
        final iconSize = isCompact ? 14.0 : 16.0;
        final iconPadding = isCompact ? 4.0 : 6.0;
        final titleFontSize = isCompact ? 12.0 : 14.0;
        final horizontalPadding = isCompact ? 10.0 : 16.0;

        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.all(iconPadding),
                decoration: BoxDecoration(
                  color: colors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  LucideIcons.brain,
                  color: colors.warning,
                  size: iconSize,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'PHD2 Brain',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: titleFontSize,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                ),
              ),
              if (_isBusy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(colors.primary),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAxisSection(
    String label,
    List<BrainParam> params,
    String axis,
    SkotiqColors colors,
  ) {
    final axisColor = axis == 'ra' ? Colors.redAccent : colors.info;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 16,
              decoration: BoxDecoration(
                color: axisColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$label Axis',
              style: TextStyle(
                color: axisColor,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceAlt.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border.withValues(alpha: 0.5)),
          ),
          child: Column(
            children: params
                .map((param) => _buildParamRow(param, axis, colors))
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildParamRow(
    BrainParam param,
    String axis,
    SkotiqColors colors,
  ) {
    final controller = _controllers['${axis}_${param.name}']!;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Tooltip(
              message: param.description ?? param.name,
              child: Text(
                _formatParamName(param.name),
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 1,
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: controller,
                readOnly: !widget.isEditing || _isBusy,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: colors.primary, width: 1.5),
                  ),
                  fillColor: colors.surface,
                  filled: true,
                ),
                onChanged: (value) {
                  setState(() {
                    _hasChanges = true;
                    _errorText = null;
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
        border: Border(
          top: BorderSide(color: colors.border.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_errorText != null) ...[
            Icon(LucideIcons.alertTriangle, size: 15, color: colors.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _errorText!,
                style: TextStyle(color: colors.error, fontSize: 11),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
          ] else
            const Spacer(),
          _buildActionButton(
            label: 'Reset',
            icon: LucideIcons.rotateCcw,
            color: colors.textSecondary,
            colors: colors,
            isOutline: true,
            onPressed: _isBusy ? null : () => unawaited(_resetChanges()),
          ),
          if (widget.onParamChanged != null || widget.onApply != null) ...[
            const SizedBox(width: 10),
            _buildActionButton(
              label: 'Apply',
              icon: LucideIcons.check,
              color: colors.primary,
              colors: colors,
              isPrimary: true,
              onPressed: _isBusy ? null : () => unawaited(_applyChanges()),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _applyChanges() async {
    if (_isBusy) return;
    final changes = <({String axis, String name, double value})>[];

    bool collect(String axis, List<BrainParam> params) {
      for (final param in params) {
        final raw = _controllers['${axis}_${param.name}']?.text.trim() ?? '';
        final value = double.tryParse(raw);
        if (value == null || !value.isFinite) {
          setState(() {
            _errorText = '${_formatParamName(param.name)} must be a number.';
          });
          return false;
        }
        if (value != param.value) {
          changes.add((axis: axis, name: param.name, value: value));
        }
      }
      return true;
    }

    if (!collect('ra', widget.raParams) || !collect('dec', widget.decParams)) {
      return;
    }

    setState(() {
      _applying = true;
      _errorText = null;
    });
    try {
      final writer = widget.onParamChanged;
      if (writer != null) {
        // Preserve edit order and backend ordering. Parallel writes can arrive
        // out of order on a remote host and leave PHD2 with an older value.
        for (final change in changes) {
          await writer(change.axis, change.name, change.value);
        }
      }
      await widget.onApply?.call();
      if (mounted) setState(() => _hasChanges = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorText = e is StateError ? e.message : e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _resetChanges() async {
    if (_isBusy) return;
    setState(() {
      _applying = true;
      _errorText = null;
    });
    try {
      await widget.onReset?.call();
      if (!mounted) return;
      _restoreControllers();
      setState(() => _hasChanges = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorText = e is StateError ? e.message : e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required SkotiqColors colors,
    VoidCallback? onPressed,
    bool isOutline = false,
    bool isPrimary = false,
  }) {
    final isDisabled = onPressed == null;
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    return Semantics(
      // A hand-rolled button: the InkWell carries the tap and nothing else, so
      // assistive tech was told a live control was an inert disabled panel.
      button: true,
      enabled: !isDisabled,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            // Ensure minimum 44px touch target height for accessibility
            constraints: const BoxConstraints(minHeight: 44),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isPrimary
                    ? (isDisabled ? colors.surfaceHover : color)
                    : (isOutline ? Colors.transparent : colors.surfaceHover),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isOutline
                      ? colors.border
                      : (isPrimary ? color : Colors.transparent),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 14,
                    color: isPrimary
                        ? (isDisabled ? colors.textMuted : onPrimary)
                        : (isDisabled ? colors.textMuted : color),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isPrimary
                          ? (isDisabled ? colors.textMuted : onPrimary)
                          : (isDisabled ? colors.textMuted : color),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatParamName(String name) {
    // Convert camelCase or PascalCase to readable format
    return name.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (match) => '${match.group(1)} ${match.group(2)}',
    );
  }
}
