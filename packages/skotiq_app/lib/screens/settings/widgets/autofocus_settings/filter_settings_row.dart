part of '../autofocus_settings.dart';

class _FilterSettingsRow extends StatefulWidget {
  final int position;
  final String filterName;
  final FilterAutofocusConfig config;
  final List<String> allFilterNames;
  final bool isLast;
  final Future<void> Function(
    FilterAutofocusConfig Function(FilterAutofocusConfig current) update,
  ) onConfigChanged;

  const _FilterSettingsRow({
    required this.position,
    required this.filterName,
    required this.config,
    required this.allFilterNames,
    required this.isLast,
    required this.onConfigChanged,
  });

  @override
  State<_FilterSettingsRow> createState() => _FilterSettingsRowState();
}

class _FilterSettingsRowState extends State<_FilterSettingsRow> {
  late TextEditingController _focusOffsetController;
  late TextEditingController _afExpTimeController;
  late TextEditingController _gainController;
  late TextEditingController _offsetController;

  @override
  void initState() {
    super.initState();
    _focusOffsetController = TextEditingController(
      text: widget.config.focusOffset.toString(),
    );
    _afExpTimeController = TextEditingController(
      text: widget.config.afExposureTime?.toString() ?? '',
    );
    _gainController = TextEditingController(
      text: widget.config.gain?.toString() ?? '',
    );
    _offsetController = TextEditingController(
      text: widget.config.offset?.toString() ?? '',
    );
  }

  @override
  void didUpdateWidget(_FilterSettingsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) {
      _syncIfUnedited(
        _focusOffsetController,
        oldWidget.config.focusOffset.toString(),
        widget.config.focusOffset.toString(),
      );
      _syncIfUnedited(
        _afExpTimeController,
        oldWidget.config.afExposureTime?.toString() ?? '',
        widget.config.afExposureTime?.toString() ?? '',
      );
      _syncIfUnedited(
        _gainController,
        oldWidget.config.gain?.toString() ?? '',
        widget.config.gain?.toString() ?? '',
      );
      _syncIfUnedited(
        _offsetController,
        oldWidget.config.offset?.toString() ?? '',
        widget.config.offset?.toString() ?? '',
      );
    }
  }

  void _syncIfUnedited(
    TextEditingController controller,
    String oldText,
    String newText,
  ) {
    if (controller.text == oldText) controller.text = newText;
  }

  @override
  void dispose() {
    _focusOffsetController.dispose();
    _afExpTimeController.dispose();
    _gainController.dispose();
    _offsetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final afFilterName = widget.config.afFilterName ?? 'Default';
    final binningStr = '${widget.config.binning}x${widget.config.binning}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: widget.isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: SkotiqColors.of(context)
                      .border
                      .withValues(alpha: 0.5),
                ),
              ),
      ),
      child: Row(
        children: [
          // Position
          SizedBox(
            width: 40,
            child: Text(
              '${widget.position}',
              style: SkotiqTypography.readoutXs.copyWith(
                color: SkotiqColors.of(context).textSecondary,
              ),
            ),
          ),
          // Name
          Expanded(
            flex: 2,
            child: Text(
              widget.filterName,
              style: SkotiqTypography.labelSm
                  .copyWith(color: SkotiqColors.of(context).textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Focus offset
          Expanded(
            flex: 2,
            child: _buildCompactNumberInput(
              fieldKey: ValueKey('af-filter-${widget.filterName}-focus-offset'),
              controller: _focusOffsetController,
              allowNegative: true,
              onCommit: (value) {
                final parsed = int.tryParse(value);
                if (parsed == null) return Future<void>.value();
                return widget.onConfigChanged(
                  (current) => current.copyWith(focusOffset: parsed),
                );
              },
            ),
          ),
          // AF Exposure Time
          Expanded(
            flex: 2,
            child: _buildCompactNumberInput(
              fieldKey: ValueKey('af-filter-${widget.filterName}-exposure'),
              controller: _afExpTimeController,
              hint: 'default',
              allowDecimal: true,
              allowClear: true,
              min: 0.1,
              max: 300,
              onCommit: (value) {
                if (value.isEmpty) {
                  return widget.onConfigChanged(
                    (current) => current.copyWith(clearAfExposureTime: true),
                  );
                }
                final parsed = double.tryParse(value);
                if (parsed == null) return Future<void>.value();
                return widget.onConfigChanged(
                  (current) => current.copyWith(afExposureTime: parsed),
                );
              },
            ),
          ),
          // AF Filter
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SettingsDropdown(
                value: afFilterName,
                items: ['Default', ...widget.allFilterNames],
                onChanged: (value) {
                  if (value == 'Default') {
                    return widget.onConfigChanged(
                      (current) => current.copyWith(clearAfFilterName: true),
                    );
                  }
                  return widget.onConfigChanged(
                    (current) => current.copyWith(afFilterName: value),
                  );
                },
              ),
            ),
          ),
          // Binning
          SizedBox(
            width: 70,
            child: SettingsDropdown(
              value: binningStr,
              items: const ['1x1', '2x2', '3x3', '4x4'],
              onChanged: (value) {
                final binVal = int.tryParse(value.split('x').first) ?? 1;
                return widget.onConfigChanged(
                  (current) => current.copyWith(binning: binVal),
                );
              },
            ),
          ),
          // Gain
          Expanded(
            flex: 1,
            child: _buildCompactNumberInput(
              fieldKey: ValueKey('af-filter-${widget.filterName}-gain'),
              controller: _gainController,
              hint: 'def',
              allowClear: true,
              min: 0,
              onCommit: (value) {
                if (value.isEmpty) {
                  return widget.onConfigChanged(
                    (current) => current.copyWith(clearGain: true),
                  );
                }
                final parsed = int.tryParse(value);
                if (parsed == null) return Future<void>.value();
                return widget.onConfigChanged(
                  (current) => current.copyWith(gain: parsed),
                );
              },
            ),
          ),
          // Offset
          Expanded(
            flex: 1,
            child: _buildCompactNumberInput(
              fieldKey: ValueKey('af-filter-${widget.filterName}-offset'),
              controller: _offsetController,
              hint: 'def',
              allowClear: true,
              min: 0,
              onCommit: (value) {
                if (value.isEmpty) {
                  return widget.onConfigChanged(
                    (current) => current.copyWith(clearOffset: true),
                  );
                }
                final parsed = int.tryParse(value);
                if (parsed == null) return Future<void>.value();
                return widget.onConfigChanged(
                  (current) => current.copyWith(offset: parsed),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactNumberInput({
    required Key fieldKey,
    required TextEditingController controller,
    String? hint,
    bool allowDecimal = false,
    bool allowNegative = false,
    bool allowClear = false,
    num? min,
    num? max,
    required Future<void> Function(String) onCommit,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: _FilterSettingsNumberInput(
        fieldKey: fieldKey,
        controller: controller,
        hint: hint,
        allowDecimal: allowDecimal,
        allowNegative: allowNegative,
        allowClear: allowClear,
        min: min,
        max: max,
        height: 28,
        onCommit: onCommit,
      ),
    );
  }
}

class _FilterSettingsNumberInput extends StatefulWidget {
  final Key fieldKey;
  final TextEditingController controller;
  final String? hint;
  final bool allowDecimal;
  final bool allowNegative;
  final bool allowClear;
  final num? min;
  final num? max;
  final double height;
  final Future<void> Function(String) onCommit;

  const _FilterSettingsNumberInput({
    required this.fieldKey,
    required this.controller,
    required this.hint,
    required this.allowDecimal,
    required this.allowNegative,
    required this.allowClear,
    required this.min,
    required this.max,
    required this.height,
    required this.onCommit,
  });

  @override
  State<_FilterSettingsNumberInput> createState() =>
      _FilterSettingsNumberInputState();
}

class _FilterSettingsNumberInputState
    extends State<_FilterSettingsNumberInput> {
  final _focusNode = FocusNode();
  late String _committedText;
  bool _saving = false;
  bool _submittedSinceLastEdit = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _committedText = widget.controller.text;
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(_FilterSettingsNumberInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && !_saving) {
      _committedText = widget.controller.text;
    }
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) return;
    if (_submittedSinceLastEdit) {
      _submittedSinceLastEdit = false;
      return;
    }
    _commit();
  }

  void _setText(String text) {
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _commit() async {
    if (_saving) return;
    final raw = widget.controller.text.trim();
    late String canonical;
    if (raw.isEmpty) {
      if (!widget.allowClear) {
        _setText(_committedText);
        setState(() => _error = 'Required');
        return;
      }
      canonical = '';
    } else {
      final parsed =
          widget.allowDecimal ? double.tryParse(raw) : int.tryParse(raw);
      if (parsed == null || (parsed is double && !parsed.isFinite)) {
        _setText(_committedText);
        setState(() => _error = 'Invalid number');
        return;
      }
      var normalized = parsed;
      if (widget.min != null && normalized < widget.min!) {
        normalized = widget.min!;
      }
      if (widget.max != null && normalized > widget.max!) {
        normalized = widget.max!;
      }
      canonical = widget.allowDecimal
          ? normalized.toDouble().toString()
          : normalized.toInt().toString();
    }

    _setText(canonical);
    if (canonical == _committedText) {
      if (_error != null) setState(() => _error = null);
      return;
    }

    final previous = _committedText;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onCommit(canonical);
      if (!mounted) return;
      _committedText = canonical;
    } catch (_) {
      if (!mounted) return;
      _setText(previous);
      setState(() => _error = 'Save failed');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final input = Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
        border:
            Border.all(color: _error == null ? colors.border : colors.error),
      ),
      child: TextField(
        key: widget.fieldKey,
        controller: widget.controller,
        focusNode: _focusNode,
        enabled: !_saving,
        keyboardType: TextInputType.numberWithOptions(
          decimal: widget.allowDecimal,
          signed: widget.allowNegative,
        ),
        inputFormatters: [
          FilteringTextInputFormatter.allow(
            RegExp(
              widget.allowDecimal
                  ? (widget.allowNegative ? r'[0-9.\-]' : r'[0-9.]')
                  : (widget.allowNegative ? r'[0-9\-]' : r'[0-9]'),
            ),
          ),
        ],
        style: SkotiqTypography.captionSm.copyWith(
          color: colors.textPrimary,
        ),
        textAlign: TextAlign.right,
        decoration: InputDecoration(
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          isDense: true,
          hintText: widget.hint,
          hintStyle: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
        onChanged: (_) {
          _submittedSinceLastEdit = false;
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) {
          _submittedSinceLastEdit = true;
          _commit();
        },
      ),
    );
    final error = _error;
    return error == null ? input : Tooltip(message: error, child: input);
  }
}

/// Mobile card for per-filter AF settings (used instead of table on small screens).
