import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/help/field_help_copy.dart';
import '../../../widgets/help/field_help_label.dart';
import '../../settings/widgets/settings_widgets.dart';

typedef _Field<T> = SettingField<AppSettingsState, T>;

AppSettingsNotifier _settings(WidgetRef ref) =>
    ref.read(appSettingsProvider.notifier);

const _ditherScales = ['Small', 'Medium', 'Large'];

final _ditherSize = _Field<String>(
  label: 'Dither size',
  read: (s) =>
      _ditherScales.contains(s.ditherScale) ? s.ditherScale : 'Medium',
  write: (ref, v) => _settings(ref).setDitherScale(v),
  choices: _ditherScales,
  choiceLabel: (v) => '$v · ${ditherScalePixels(v).toStringAsFixed(0)} px',
);

final _ditherRaOnly = _Field<bool>(
  label: 'Dither in RA only',
  read: (s) => s.ditherRaOnly,
  write: (ref, v) => _settings(ref).setDitherRaOnly(v),
);

final _settleThreshold = _Field<double>(
  label: 'Settle threshold',
  read: (s) => s.settleThreshold,
  write: (ref, v) => _settings(ref).setSettleThreshold(v),
  codec: NumberCodec.of(
    AppSettingDefs.settleThreshold,
    decimals: 1,
    unit: 'px',
  ),
);

final _settleTime = _Field<int>(
  label: 'Settle time',
  read: (s) => s.settleTime,
  write: (ref, v) => _settings(ref).setSettleTime(v),
  codec: IntCodec.of(AppSettingDefs.settleTime, unit: 's'),
);

final _settleTimeout = _Field<int>(
  label: 'Settle timeout',
  read: (s) => s.settleTimeout,
  write: (ref, v) => _settings(ref).setSettleTimeout(v),
  codec: IntCodec.of(AppSettingDefs.settleTimeout, unit: 's'),
);

/// The guiding settings every dither and start of guiding uses: how far a
/// dither moves the star, and when guiding counts as settled. The one editor
/// of them, on the Guiding screen and in Imaging's guiding panel; the bounds
/// are the settings table's.
class GuideSettleSettings extends ConsumerWidget {
  const GuideSettleSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    if (settings == null) return const SizedBox.shrink();
    Widget row<T>(String key, SettingField<AppSettingsState, T> field,
        {FieldHelpId? helpId, double width = 104}) {
      final help = helpId == null ? null : helpFor(helpId);
      return _SettleRow(
        key: ValueKey('guide-settle-$key'),
        label: field.label,
        help: help,
        child: SettingsField<AppSettingsState, T>(
          field: field,
          state: settings,
          width: width,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row('dither-size', _ditherSize,
            helpId: FieldHelpId.ditherAmount, width: 136),
        row('dither-ra-only', _ditherRaOnly),
        row('threshold', _settleThreshold,
            helpId: FieldHelpId.settleThreshold),
        row('time', _settleTime, helpId: FieldHelpId.settleTime),
        row('timeout', _settleTimeout),
      ],
    );
  }
}

class _SettleRow extends StatelessWidget {
  const _SettleRow({
    super.key,
    required this.label,
    this.help,
    required this.child,
  });

  final String label;
  final FieldHelpCopy? help;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final style = SkotiqTypography.bodySm.copyWith(color: colors.textSecondary);
    final help = this.help;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
      child: Row(
        children: [
          Expanded(
            child: help == null
                ? Text(label, style: style)
                : FieldHelpLabel(
                    label: label,
                    helpTitle: help.title,
                    helpBody: help.body,
                  ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          child,
        ],
      ),
    );
  }
}
