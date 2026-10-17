/// Skotiq Core - backend interface barrel.
///
/// Re-exports the backend abstraction (the device/imaging backend interface and
/// its FFI / network / disconnected implementations) together with the wire
/// model types that the backend exchanges with the host. Prefer this import in
/// code that talks to a backend rather than to higher-level services.
library;

// Backend interface
export 'src/backend/skotiq_backend.dart';
export 'src/backend/ffi_backend.dart';
export 'src/backend/network_backend.dart';
export 'src/backend/disconnected_backend.dart';
export 'src/models/backend/fits_header.dart';
export 'src/models/backend/image_result.dart';
export 'src/models/backend/platform_capabilities.dart';
export 'src/models/backend/remote_api_compatibility.dart';
// Recovery Mode — Dart mirror of the Rust `RecoveryContext`,
// `RecoveryHistoryEntry`, `RecoveryCause`, and `RecoveryPhase` so the Run
// Dashboard recovery banner and post-session report render the same data
// the executor publishes.
export 'src/models/sequencer/recovery_status.dart';
