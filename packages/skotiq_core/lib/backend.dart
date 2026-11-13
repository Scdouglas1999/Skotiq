/// The backend layer of skotiq_core: the role interfaces a host implements and the
/// local, linked and disconnected hosts.
///
/// Exports only files under `src/backend/`.
library;

export 'src/backend/skotiq_backend.dart';
export 'src/backend/ffi_backend.dart';
export 'src/backend/network_backend.dart';
export 'src/backend/disconnected_backend.dart';
export 'src/backend/remote_host.dart';
export 'src/backend/roles/host_data/calibration_library.dart';
export 'src/backend/roles/host_data/notes_journal.dart';
export 'src/backend/roles/host_data/observation_log.dart';
export 'src/backend/roles/host_data/observing_lists_store.dart';
export 'src/backend/roles/host_data/polar_alignment_log.dart';
export 'src/backend/roles/host_data/science_products.dart';
export 'src/backend/roles/host_data/host_records.dart';
// Typed bridge events. `SkotiqEvent`, `EventCategory` and `EventSeverity` share
// their names with the wire event model in models.dart and are imported
// from `package:skotiq_core/bridge_events.dart`.
export 'src/backend/bridge_events.dart';
export 'src/backend/sequencer_error_kind.dart';

// Per-frame capture truth carried on FrameAccepted/FrameRejected. Exported so
// the surfaces that persist or assert on a sequenced frame read the event's
// key names from one place rather than re-spelling them.
export 'src/backend/frame_capture_metadata.dart';
// Authored sentence inside a typed bridge error, for UI packages that render a
// caught error as copy without importing package:skotiq_bridge.
export 'src/backend/bridge_error_message.dart';
export 'src/backend/device_connect_exception.dart';
export 'src/backend/network_backend/host_data/remote_imaging_records.dart';
export 'src/backend/roles/host_data/imaging_records.dart';
export 'src/backend/bridge_event_codec.dart';
