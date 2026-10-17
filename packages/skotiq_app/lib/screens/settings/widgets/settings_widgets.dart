// ignore_for_file: unused_element_parameter

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:lucide_icons/lucide_icons.dart';

import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/help/field_help_copy.dart';
import '../../../widgets/help/field_help_label.dart';

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
  bool isMobile = false,
  BoxConstraints? constraints,
  double fixedWidth = 260,
}) {
  if (isMobile || Responsive.isMobile(context)) return true;
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
  bool isMobile = false,
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

/// [SettingsTextInput] that shrinks on narrow setting rows / mobile viewports.
Widget settingsTrailingTextInput({
  required BuildContext context,
  required TextEditingController controller,
  String? authoritativeValue,
  Object? authorityKey,
  FutureOr<void> Function(String)? onChanged,
  String? hint,
  double designWidth = 260,
  bool isMobile = false,
  bool obscure = false,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final layout = settingsTrailingLayout(
        context,
        designWidth: designWidth,
        isMobile: isMobile,
        constraints: constraints,
      );
      return SettingsTextInput(
        controller: controller,
        authoritativeValue: authoritativeValue,
        authorityKey: authorityKey,
        hint: hint,
        width: layout.width,
        flexible: layout.flexible,
        obscure: obscure,
        isMobile: isMobile,
        onChanged: onChanged,
      );
    },
  );
}

/// [SettingsDropdown] that shrinks on narrow setting rows / mobile viewports.
Widget settingsTrailingDropdown({
  required BuildContext context,
  required String value,
  required List<String> items,
  required FutureOr<void> Function(String) onChanged,
  double designWidth = 200,
  bool isMobile = false,
  List<String>? itemLabels,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final layout = settingsTrailingLayout(
        context,
        designWidth: designWidth,
        isMobile: isMobile,
        constraints: constraints,
      );
      return SettingsDropdown(
        value: value,
        items: items,
        itemLabels: itemLabels,
        onChanged: onChanged,
        width: layout.width,
        flexible: layout.flexible,
        isMobile: isMobile,
      );
    },
  );
}

/// A full-page settings layout with title, description, and children.
