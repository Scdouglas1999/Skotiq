import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lucide_icons/lucide_icons.dart';

import 'package:skotiq_core/errors.dart' show userFacingError;
import 'package:skotiq_core/providers.dart'
    show appSettingsWriteFailureProvider;
import 'package:skotiq_core/settings.dart' show DoubleSetting, IntSetting;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/help/field_help_copy.dart';
import '../../../widgets/help/field_help_label.dart';
import '../../../utils/snackbar_helper.dart';

part 'settings_widgets/settings_field_binding.dart';
part 'settings_widgets/settings_field_notice.dart';
part 'settings_widgets/settings_page_states.dart';
part 'settings_widgets/settings_section_and_row.dart';
part 'settings_widgets/settings_switch_and_dropdown.dart';
part 'settings_widgets/settings_text_and_number_inputs.dart';
part 'settings_widgets/settings_color_and_path_inputs.dart';
part 'settings_widgets/settings_link_and_info_rows.dart';
part 'settings_widgets/settings_compact_controls.dart';

/// A fixed-width slot for a control that is not one of the settings inputs:
/// [width] in the split view, [narrowWidth] in the narrow layout.
class SettingsControlBox extends StatelessWidget {
  const SettingsControlBox({
    super.key,
    required this.width,
    required this.narrowWidth,
    this.height,
    required this.child,
  });

  final double width;
  final double narrowWidth;
  final double? height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: SettingsFormScope.narrowOf(context) ? narrowWidth : width,
      height: height,
      child: child,
    );
  }
}

/// The size of a labelled action button on a settings page: medium, or small
/// in the narrow layout.
ButtonSize settingsActionButtonSize(BuildContext context) =>
    SettingsFormScope.narrowOf(context) ? ButtonSize.small : ButtonSize.medium;

/// Vertical space between hand-laid blocks on a settings page, a step tighter
/// in the narrow layout.
class SettingsGap extends StatelessWidget {
  /// 20, or 16 narrow.
  const SettingsGap({super.key})
      : _wide = 20,
        _narrow = 16;

  /// 32, or 24 narrow.
  const SettingsGap.large({super.key})
      : _wide = 32,
        _narrow = 24;

  final double _wide;
  final double _narrow;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: SettingsFormScope.narrowOf(context) ? _narrow : _wide,
    );
  }
}

/// Whether a [SettingRow] trailing control should use flexible width.
bool settingsTrailingIsNarrow(
  BuildContext context, {
  BoxConstraints? constraints,
  double fixedWidth = 260,
}) {
  if (SettingsFormScope.narrowOf(context)) return true;
  if (Responsive.isMobile(context)) return true;
  if (constraints != null &&
      constraints.hasBoundedWidth &&
      constraints.maxWidth < fixedWidth + 48) {
    return true;
  }
  return false;
}

/// Layout parameters for trailing settings inputs on [SettingRow].
({bool flexible, double? width}) settingsTrailingLayout(
  BuildContext context, {
  double designWidth = 260,
  BoxConstraints? constraints,
}) {
  final narrow = settingsTrailingIsNarrow(
    context,
    constraints: constraints,
    fixedWidth: designWidth,
  );
  return (flexible: narrow, width: narrow ? null : designWidth);
}

/// Sizes a trailing settings control: [designWidth] where the row has room,
/// the row's own width on a phone or a narrow pane.
class SettingsTrailing extends StatelessWidget {
  const SettingsTrailing({
    super.key,
    this.designWidth = 260,
    required this.builder,
  });

  final double designWidth;

  /// Builds the control for the resolved [width] (null when [flexible]).
  final Widget Function(BuildContext context, double? width, bool flexible)
      builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = settingsTrailingLayout(
          context,
          designWidth: designWidth,
          constraints: constraints,
        );
        return builder(context, layout.width, layout.flexible);
      },
    );
  }
}

/// [SettingsTextInput] that shrinks on narrow setting rows / mobile viewports.
Widget settingsTrailingTextInput({
  required BuildContext context,
  TextEditingController? controller,
  String? authoritativeValue,
  Object? authorityKey,
  FutureOr<void> Function(String)? onChanged,
  String? Function(String text)? validate,
  String? hint,
  double designWidth = 260,
  bool obscure = false,
}) {
  return SettingsTrailing(
    designWidth: designWidth,
    builder: (context, width, flexible) => SettingsTextInput(
      controller: controller,
      authoritativeValue: authoritativeValue,
      authorityKey: authorityKey,
      hint: hint,
      width: width,
      flexible: flexible,
      obscure: obscure,
      onChanged: onChanged,
      validate: validate,
    ),
  );
}

/// [SettingsDropdown] that shrinks on narrow setting rows / mobile viewports.
Widget settingsTrailingDropdown({
  required BuildContext context,
  required String value,
  required List<String> items,
  required FutureOr<void> Function(String) onChanged,
  double designWidth = 200,
  List<String>? itemLabels,
}) {
  return SettingsTrailing(
    designWidth: designWidth,
    builder: (context, width, flexible) => SettingsDropdown(
      value: value,
      items: items,
      itemLabels: itemLabels,
      onChanged: onChanged,
      width: width,
      flexible: flexible,
    ),
  );
}

/// A typed [SettingsChoice] that shrinks on narrow setting rows.
Widget settingsTrailingChoice<T>({
  required T value,
  required List<T> values,
  required String Function(T value) labelOf,
  required FutureOr<void> Function(T value) onChanged,
  double designWidth = 200,
}) {
  return SettingsTrailing(
    designWidth: designWidth,
    builder: (context, width, flexible) => SettingsChoice<T>(
      value: value,
      values: values,
      labelOf: labelOf,
      onChanged: onChanged,
      width: width,
      flexible: flexible,
    ),
  );
}
