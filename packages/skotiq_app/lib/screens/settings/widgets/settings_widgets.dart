import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lucide_icons/lucide_icons.dart';

import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/user_facing_error.dart';
import '../../../widgets/help/field_help_copy.dart';
import '../../../widgets/help/field_help_label.dart';

part 'settings_widgets/settings_field_binding.dart';
part 'settings_widgets/settings_field_notice.dart';
part 'settings_widgets/settings_page_states.dart';
part 'settings_widgets/settings_section_and_row.dart';
part 'settings_widgets/settings_switch_and_dropdown.dart';
part 'settings_widgets/settings_text_and_number_inputs.dart';
part 'settings_widgets/settings_color_and_path_inputs.dart';
part 'settings_widgets/settings_link_and_info_rows.dart';
part 'settings_widgets/settings_compact_controls.dart';

/// Whether a [SettingRow] trailing control should use flexible width.
bool settingsTrailingIsNarrow(
  BuildContext context, {
  bool? isMobile,
  BoxConstraints? constraints,
  double fixedWidth = 260,
}) {
  if (isMobile ?? SettingsFormScope.isMobileOf(context)) return true;
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
  bool? isMobile,
  BoxConstraints? constraints,
}) {
  final narrow = settingsTrailingIsNarrow(
    context,
    isMobile: isMobile,
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
  bool? isMobile,
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
      isMobile: isMobile,
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
  bool? isMobile,
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
      isMobile: isMobile,
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
