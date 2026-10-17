/// Equipment state providers barrel.
///
/// Each device type owns its own file under `equipment/`. This shell re-exports
/// them so existing consumers (`import 'src/providers/equipment_provider.dart'`)
/// keep working without churn.
///
library;

export 'equipment/camera_state_provider.dart';
export 'equipment/cover_calibrator_state_provider.dart';
export 'equipment/dome_state_provider.dart';
export 'equipment/filter_wheel_state_provider.dart';
export 'equipment/focuser_state_provider.dart';
export 'equipment/focuser_temp_compensation_provider.dart';
export 'equipment/guider_state_provider.dart';
export 'equipment/mount_state_provider.dart';
export 'equipment/profile_connection_status_provider.dart';
export 'equipment/rotator_state_provider.dart';
export 'equipment/safety_monitor_state_provider.dart';
export 'equipment/switch_state_provider.dart';
export 'equipment/weather_state_provider.dart';
export 'equipment/equipment_state_reset.dart';
