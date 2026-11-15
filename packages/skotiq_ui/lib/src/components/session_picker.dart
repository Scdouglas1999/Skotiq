import 'package:flutter/material.dart';
import 'package:skotiq_astro/format.dart';

import 'form_row.dart';
import 'skotiq_dropdown.dart';

/// One choice in a [SessionPicker].
@immutable
class SessionPickerEntry<T> {
  const SessionPickerEntry({
    required this.value,
    required this.name,
    this.start,
    this.count,
  });

  /// What [SessionPicker.onChanged] reports when this entry is chosen.
  final T value;

  /// The session's name, or what the entry stands for ("Quick captures").
  final String name;

  /// When the session started. Shown in local time; null for an entry that is
  /// not one session.
  final DateTime? start;

  /// A count with its noun, "120 exposures". Null when it does not apply.
  final String? count;

  /// The muted facts after the name: date, then count.
  String? get detail {
    final parts = <String>[
      if (start != null) ClockFormat.monthDayYearHm(start!.toLocal()),
      ?count,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// The one way to choose a session: a labelled field whose value reads
/// "name · date · count", and whose open list shows the name with the date and
/// count right-aligned beside it.
///
/// Every screen that analyzes one night (Analytics > Session, Science,
/// Diagnostics) picks it with this, so a session reads the same wherever it is
/// chosen.
class SessionPicker<T> extends StatelessWidget {
  const SessionPicker({
    super.key,
    required this.entries,
    required this.value,
    required this.onChanged,
    this.label = 'Session',
    this.hint = 'Choose a session',
    this.labelWidth = FormRow.defaultLabelWidth,
  });

  /// The choices, in display order (newest first, by convention).
  final List<SessionPickerEntry<T>> entries;

  /// The chosen entry's value, or null for none (shows [hint]).
  final T? value;

  /// Null disables the picker.
  final ValueChanged<T>? onChanged;

  /// The form label to the left of the field.
  final String label;

  final String hint;

  final double labelWidth;

  /// The widest the field grows: enough for a name, a date and a count on one
  /// line, and no wider, so it does not stretch across a wide page.
  static const double maxFieldWidth = 480;

  @override
  Widget build(BuildContext context) {
    final index = entries.indexWhere((e) => e.value == value);
    return FormRow(
      label: label,
      labelWidth: labelWidth,
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxFieldWidth),
          child: SkotiqDropdown(
            value: index < 0 ? null : '$index',
            hint: hint,
            items: <String>[for (var i = 0; i < entries.length; i++) '$i'],
            itemLabels: <String>[for (final e in entries) e.name],
            itemDetails: <String?>[for (final e in entries) e.detail],
            onChanged: onChanged == null
                ? null
                : (chosen) {
                    if (chosen == null) return;
                    onChanged!(entries[int.parse(chosen)].value);
                  },
          ),
        ),
      ),
    );
  }
}
