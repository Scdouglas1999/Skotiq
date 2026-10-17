import 'package:skotiq_core/skotiq_core.dart';

/// One naming for [SafetyFailMode] shared by every settings page that shows it.
///
/// The mode is stored once but is now surfaced on two pages (Sequencer >
/// Safety, Weather Safety). Keeping the strings here is what stops the two
/// from describing the same stored value differently.
extension SafetyFailModeLabels on SafetyFailMode {
  String get label => switch (this) {
        SafetyFailMode.failClosed => 'Fail Closed (Park)',
        SafetyFailMode.failOpen => 'Fail Open (Continue)',
        SafetyFailMode.warnOnly => 'Warn Only',
      };

  String get description => switch (this) {
        SafetyFailMode.failClosed =>
          'Treat unavailable safety data as unsafe and park/pause equipment',
        SafetyFailMode.failOpen =>
          'Treat unavailable safety data as safe and continue operations',
        SafetyFailMode.warnOnly =>
          'Continue operations and show a warning when safety data is '
              'unavailable',
      };

  /// What this mode means for a rig that has no weather source at all — the
  /// case the Weather Safety page must state, because the master switch there
  /// is what arms it.
  String get noSourceConsequence => switch (this) {
        SafetyFailMode.failClosed =>
          'With $label, missing data counts as unsafe: a run will refuse to '
              'start and the rig is parked.',
        SafetyFailMode.failOpen =>
          'With $label, missing data counts as safe and runs continue '
              'unchecked.',
        SafetyFailMode.warnOnly =>
          'With $label, missing data counts as safe and only a warning is '
              'shown.',
      };

  static SafetyFailMode fromLabel(String value) => switch (value) {
        'Fail Open (Continue)' => SafetyFailMode.failOpen,
        'Warn Only' => SafetyFailMode.warnOnly,
        _ => SafetyFailMode.failClosed,
      };

  /// Dropdown options, in the order both pages present them.
  static const List<String> labels = [
    'Fail Closed (Park)',
    'Fail Open (Continue)',
    'Warn Only',
  ];
}
