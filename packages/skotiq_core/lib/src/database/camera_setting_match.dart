import 'package:drift/drift.dart';

/// Matching a calibration library column against a frame's gain or offset.
extension CameraSettingMatch on Expression<int> {
  /// The column holds [value], or is empty when [value] is null: a camera
  /// without gain or offset control (FLI, Atik CCDs) records neither, and two
  /// of its frames agree on that.
  Expression<bool> isSetting(int? value) =>
      value == null ? this.isNull() : this.equals(value);
}
