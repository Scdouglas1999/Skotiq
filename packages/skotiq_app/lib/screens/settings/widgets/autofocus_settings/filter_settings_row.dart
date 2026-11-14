part of '../autofocus_settings.dart';

typedef _FilterConfigUpdate = Future<void> Function(
  FilterAutofocusConfig Function(FilterAutofocusConfig current) update,
);

/// The six per-filter autofocus controls, shared by the desktop table row and
/// the phone card so their bounds and write rules exist once.
class _FilterAfFields {
  const _FilterAfFields({
    required this.filterName,
    required this.config,
    required this.allFilterNames,
    required this.onConfigChanged,
    required this.height,
    required this.defaultHint,
    required this.flexibleDropdowns,
  });

  final String filterName;
  final FilterAutofocusConfig config;
  final List<String> allFilterNames;
  final _FilterConfigUpdate onConfigChanged;
  final double height;

  /// Placeholder for a value left to the camera default.
  final String defaultHint;

  final bool flexibleDropdowns;

  static const _defaultFilter = 'Default';
  static const _binnings = [1, 2, 3, 4];

  Widget _cell<T>({
    required String id,
    required SettingCodec<T> codec,
    required T value,
    required FutureOr<void> Function(T value) onChanged,
    String? hint,
  }) {
    return SettingsValueField<T>(
      codec: codec,
      value: value,
      onChanged: onChanged,
      hint: hint,
      inputKey: ValueKey('af-filter-$filterName-$id'),
      builder: (context, parts) => _FilterCellBox(parts: parts, height: height),
    );
  }

  Widget get focusOffset => _cell<int>(
        id: 'focus-offset',
        codec: const IntCodec(min: -1000000, max: 1000000),
        value: config.focusOffset,
        onChanged: (value) =>
            onConfigChanged((current) => current.copyWith(focusOffset: value)),
      );

  Widget get exposure => _cell<double?>(
        id: 'exposure',
        codec: const OptionalCodec(
          NumberCodec(min: 0.1, max: 300, decimals: 3, unit: 's'),
        ),
        value: config.afExposureTime,
        hint: 'default',
        onChanged: (value) => onConfigChanged(
          (current) => value == null
              ? current.copyWith(clearAfExposureTime: true)
              : current.copyWith(afExposureTime: value),
        ),
      );

  Widget get gain => _cell<int?>(
        id: 'gain',
        codec: const OptionalCodec(IntCodec(min: 0, max: 1000000)),
        value: config.gain,
        hint: defaultHint,
        onChanged: (value) => onConfigChanged(
          (current) => value == null
              ? current.copyWith(clearGain: true)
              : current.copyWith(gain: value),
        ),
      );

  Widget get offset => _cell<int?>(
        id: 'offset',
        codec: const OptionalCodec(IntCodec(min: 0, max: 1000000)),
        value: config.offset,
        hint: defaultHint,
        onChanged: (value) => onConfigChanged(
          (current) => value == null
              ? current.copyWith(clearOffset: true)
              : current.copyWith(offset: value),
        ),
      );

  Widget get afFilter => SettingsDropdown(
        value: config.afFilterName ?? _defaultFilter,
        items: [_defaultFilter, ...allFilterNames],
        flexible: flexibleDropdowns,
        onChanged: (value) => onConfigChanged(
          (current) => value == _defaultFilter
              ? current.copyWith(clearAfFilterName: true)
              : current.copyWith(afFilterName: value),
        ),
      );

  Widget get binning => SettingsChoice<int>(
        value: config.binning,
        values: _binnings,
        labelOf: (bin) => '${bin}x$bin',
        flexible: flexibleDropdowns,
        onChanged: (bin) =>
            onConfigChanged((current) => current.copyWith(binning: bin)),
      );
}

/// The compact well-style text box of the per-filter table.
class _FilterCellBox extends StatelessWidget {
  const _FilterCellBox({required this.parts, required this.height});

  final SettingsFieldParts parts;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
        border: Border.all(
          color: parts.hasProblem ? colors.error : colors.border,
        ),
      ),
      child: TextField(
        key: parts.inputKey,
        controller: parts.controller,
        focusNode: parts.focusNode,
        enabled: parts.enabled,
        keyboardType: parts.keyboardType,
        inputFormatters: parts.inputFormatters,
        style: SkotiqTypography.captionSm.copyWith(color: colors.textPrimary),
        textAlign: TextAlign.right,
        decoration: InputDecoration(
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          isDense: true,
          hintText: parts.hint,
          hintStyle:
              SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
        ),
        onChanged: parts.onChanged,
        onSubmitted: parts.onSubmitted,
      ),
    );
  }
}

class _FilterSettingsRow extends StatelessWidget {
  final int position;
  final String filterName;
  final FilterAutofocusConfig config;
  final List<String> allFilterNames;
  final bool isLast;
  final _FilterConfigUpdate onConfigChanged;

  const _FilterSettingsRow({
    required this.position,
    required this.filterName,
    required this.config,
    required this.allFilterNames,
    required this.isLast,
    required this.onConfigChanged,
  });

  @override
  Widget build(BuildContext context) {
    final fields = _FilterAfFields(
      filterName: filterName,
      config: config,
      allFilterNames: allFilterNames,
      onConfigChanged: onConfigChanged,
      height: 28,
      defaultHint: 'def',
      flexibleDropdowns: false,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: SkotiqColors.of(context).border.withValues(alpha: 0.5),
                ),
              ),
      ),
      child: Row(
        children: [
          // Position
          SizedBox(
            width: 40,
            child: Text(
              '${position}',
              style: SkotiqTypography.readoutXs.copyWith(
                color: SkotiqColors.of(context).textSecondary,
              ),
            ),
          ),
          // Name
          Expanded(
            flex: 2,
            child: Text(
              filterName,
              style: SkotiqTypography.labelSm
                  .copyWith(color: SkotiqColors.of(context).textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(flex: 2, child: _padded(fields.focusOffset)),
          Expanded(flex: 2, child: _padded(fields.exposure)),
          Expanded(flex: 2, child: _padded(fields.afFilter)),
          SizedBox(width: 70, child: fields.binning),
          Expanded(flex: 1, child: _padded(fields.gain)),
          Expanded(flex: 1, child: _padded(fields.offset)),
        ],
      ),
    );
  }

  static Widget _padded(Widget child) =>
      Padding(padding: const EdgeInsets.only(right: 8), child: child);
}
