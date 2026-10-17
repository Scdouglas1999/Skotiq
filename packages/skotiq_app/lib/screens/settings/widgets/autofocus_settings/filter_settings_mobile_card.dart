part of '../autofocus_settings.dart';

class _FilterSettingsMobileCard extends StatefulWidget {
  final int position;
  final String filterName;
  final FilterAutofocusConfig config;
  final List<String> allFilterNames;
  final bool isLast;
  final Future<void> Function(
    FilterAutofocusConfig Function(FilterAutofocusConfig current) update,
  ) onConfigChanged;

  const _FilterSettingsMobileCard({
    required this.position,
    required this.filterName,
    required this.config,
    required this.allFilterNames,
    required this.isLast,
    required this.onConfigChanged,
  });

  @override
  State<_FilterSettingsMobileCard> createState() =>
      _FilterSettingsMobileCardState();
}

class _FilterSettingsMobileCardState extends State<_FilterSettingsMobileCard> {
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
  void didUpdateWidget(_FilterSettingsMobileCard oldWidget) {
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: position + name
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: SkotiqDecorations.chip(
                    SkotiqColors.of(context),
                    tone: SkotiqColors.of(context).primary),
                child: Center(
                  child: Text(
                    '${widget.position}',
                    style: SkotiqTypography.caption
                        .copyWith(fontWeight: FontWeight.w600)
                        .copyWith(color: SkotiqColors.of(context).primary),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                widget.filterName,
                style: SkotiqTypography.bodyStrong
                    .copyWith(color: SkotiqColors.of(context).textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Settings grid (2 columns)
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _buildMobileField(
                'Focus Offset',
                _buildCompactNumberInput(
                  fieldKey:
                      ValueKey('af-filter-${widget.filterName}-focus-offset'),
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
              _buildMobileField(
                'AF Exp Time',
                _buildCompactNumberInput(
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
                        (current) =>
                            current.copyWith(clearAfExposureTime: true),
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
              _buildMobileField(
                'AF Filter',
                SettingsDropdown(
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
                  isMobile: true,
                  flexible: true,
                ),
              ),
              _buildMobileField(
                'Binning',
                SettingsDropdown(
                  value: binningStr,
                  items: const ['1x1', '2x2', '3x3', '4x4'],
                  onChanged: (value) {
                    final binVal = int.tryParse(value.split('x').first) ?? 1;
                    return widget.onConfigChanged(
                      (current) => current.copyWith(binning: binVal),
                    );
                  },
                  isMobile: true,
                  flexible: true,
                ),
              ),
              _buildMobileField(
                'Gain',
                _buildCompactNumberInput(
                  fieldKey: ValueKey('af-filter-${widget.filterName}-gain'),
                  controller: _gainController,
                  hint: 'default',
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
              _buildMobileField(
                'Offset',
                _buildCompactNumberInput(
                  fieldKey: ValueKey('af-filter-${widget.filterName}-offset'),
                  controller: _offsetController,
                  hint: 'default',
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
        ],
      ),
    );
  }

  Widget _buildMobileField(String label, Widget input) {
    return SizedBox(
      width: 140,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: SkotiqTypography.eyebrow.copyWith(
              color: SkotiqColors.of(context).textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          input,
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
    return _FilterSettingsNumberInput(
      fieldKey: fieldKey,
      controller: controller,
      hint: hint,
      allowDecimal: allowDecimal,
      allowNegative: allowNegative,
      allowClear: allowClear,
      min: min,
      max: max,
      height: 32,
      onCommit: onCommit,
    );
  }
}
