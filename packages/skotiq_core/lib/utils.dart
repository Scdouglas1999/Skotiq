/// Small helpers of skotiq_core that depend on nothing else in the package.
///
/// Exports only files under `src/utils/`.
library;

export 'src/utils/device_id.dart' show isValidDeviceIdFormat;
// Single source of truth for device-identity logic: parsing, canonicalization,
// matching, and id-pattern friendly-name fallback.
export 'src/utils/device_id.dart'
    show
        DeviceId,
        DeviceDriverKind,
        canonicalGuiderId,
        isPhd2DeviceId,
        deviceIdsMatch,
        friendlyNameFromDeviceId,
        kBuiltinGuiderDisplayName,
        kBuiltinGuiderIdPrefix,
        builtinGuiderDeviceId,
        kSimulatorDeviceDisplayNames,
        kPhd2CanonicalId,
        kPhd2DisplayName;
export 'src/utils/coordinate_parser.dart';
export 'src/utils/resilient_poll_stream.dart';
export 'src/utils/poll_pace.dart';
export 'src/utils/dither_settle_presets.dart';
export 'src/utils/export_target.dart';
export 'src/utils/utc_timestamp.dart';
export 'src/utils/local_time_of_day.dart';
export 'src/utils/remote_path.dart';
export 'src/utils/aligned_ticker.dart';
export 'src/utils/skotiq_data_directory.dart';
export 'src/utils/legacy_install_migration.dart';
export 'src/utils/host_paths.dart' show hostPathContext;
