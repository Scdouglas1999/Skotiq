/// Skotiq Bridge - Dart FFI bindings to Rust native code
library;

export 'src/frb_generated.dart';
export 'src/event.dart';
export 'src/event_display.dart';
export 'src/device.dart';
export 'src/state.dart';
export 'src/storage.dart';
export 'src/native_bridge.dart';
export 'src/api_barrel.dart';

// Export PHD2 utilities
export 'src/rolling_rms_calculator.dart';

// Export device capabilities
export 'src/device_capabilities/types.dart';

// Export the FRB-generated SkotiqError sealed class hierarchy so
// consumers don't have to reach into `src/error.dart` directly.
export 'src/error.dart';
