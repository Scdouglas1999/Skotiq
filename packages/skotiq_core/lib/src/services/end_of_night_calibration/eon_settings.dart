import '../../database/daos/settings_dao.dart';

/// Where the mount goes before the calibration frames.
enum EonMountAction {
  /// Send the mount to its home position and stop tracking.
  home,

  /// Park the mount.
  park,

  /// Leave the mount where the night left it.
  leave;

  static EonMountAction parse(String? value) => switch (value) {
    'park' => EonMountAction.park,
    'leave' => EonMountAction.leave,
    _ => EonMountAction.home,
  };
}

/// What to do when the filter wheel has no dark slot.
enum EonNoDarkSlotPolicy {
  /// Ask the operator to cap the telescope and wait for them to confirm.
  askToCap,

  /// Take no darks or bias and say so in the report.
  skip;

  static EonNoDarkSlotPolicy parse(String? value) =>
      value == 'skip' ? EonNoDarkSlotPolicy.skip : EonNoDarkSlotPolicy.askToCap;

  String get wireValue => this == skip ? 'skip' : 'ask';
}

/// Operator settings for the end-of-night calibration step.
class EonSettings {
  const EonSettings({
    this.enabled = false,
    this.mountAction = EonMountAction.home,
    this.darkCount = 20,
    this.biasCount = 50,
    this.noDarkSlot = EonNoDarkSlotPolicy.askToCap,
    this.capWaitMinutes = 30,
    this.warmUp = true,
  });

  /// Run the step automatically when the night's imaging ends.
  final bool enabled;
  final EonMountAction mountAction;

  /// Darks per light configuration.
  final int darkCount;

  /// Bias frames per gain/offset/binning.
  final int biasCount;
  final EonNoDarkSlotPolicy noDarkSlot;

  /// How long to wait for the operator to confirm the telescope is capped.
  final int capWaitMinutes;

  /// Warm the camera up gradually once the frames are taken.
  final bool warmUp;

  static const keyPrefix = 'end_of_night_calibration';
  static const enabledKey = '$keyPrefix.enabled';
  static const mountKey = '$keyPrefix.mount';
  static const darkCountKey = '$keyPrefix.dark_count';
  static const biasCountKey = '$keyPrefix.bias_count';
  static const noDarkSlotKey = '$keyPrefix.no_dark_slot';
  static const capWaitKey = '$keyPrefix.cap_wait_minutes';
  static const warmUpKey = '$keyPrefix.warm_up';
  static const lastReportKey = '$keyPrefix.last_report';

  static const minCount = 2;
  static const maxCount = 200;

  static Future<EonSettings> load(SettingsDao dao) async {
    Future<String?> read(String key) => dao.getSetting(key);
    int count(String? raw, int fallback) =>
        (int.tryParse(raw ?? '') ?? fallback).clamp(minCount, maxCount);
    return EonSettings(
      enabled: await read(enabledKey) == 'true',
      mountAction: EonMountAction.parse(await read(mountKey)),
      darkCount: count(await read(darkCountKey), 20),
      biasCount: count(await read(biasCountKey), 50),
      noDarkSlot: EonNoDarkSlotPolicy.parse(await read(noDarkSlotKey)),
      capWaitMinutes: (int.tryParse(await read(capWaitKey) ?? '') ?? 30).clamp(
        1,
        240,
      ),
      warmUp: await read(warmUpKey) != 'false',
    );
  }

  Map<String, String> toStorage() => {
    enabledKey: '$enabled',
    mountKey: mountAction.name,
    darkCountKey: '$darkCount',
    biasCountKey: '$biasCount',
    noDarkSlotKey: noDarkSlot.wireValue,
    capWaitKey: '$capWaitMinutes',
    warmUpKey: '$warmUp',
  };

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'mountAction': mountAction.name,
    'darkCount': darkCount,
    'biasCount': biasCount,
    'noDarkSlot': noDarkSlot.wireValue,
    'capWaitMinutes': capWaitMinutes,
    'warmUp': warmUp,
  };

  EonSettings copyWith({
    bool? enabled,
    EonMountAction? mountAction,
    int? darkCount,
    int? biasCount,
    EonNoDarkSlotPolicy? noDarkSlot,
    int? capWaitMinutes,
    bool? warmUp,
  }) => EonSettings(
    enabled: enabled ?? this.enabled,
    mountAction: mountAction ?? this.mountAction,
    darkCount: (darkCount ?? this.darkCount).clamp(minCount, maxCount),
    biasCount: (biasCount ?? this.biasCount).clamp(minCount, maxCount),
    noDarkSlot: noDarkSlot ?? this.noDarkSlot,
    capWaitMinutes: (capWaitMinutes ?? this.capWaitMinutes).clamp(1, 240),
    warmUp: warmUp ?? this.warmUp,
  );
}
