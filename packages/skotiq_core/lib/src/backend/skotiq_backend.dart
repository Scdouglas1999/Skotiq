import 'roles/depthlock_backend.dart';
import 'roles/device_backend.dart';
import 'roles/diagnostics_backend.dart';
import 'roles/guiding_backend.dart';
import 'roles/imaging_backend.dart';
import 'roles/profile_settings_backend.dart';
import 'roles/sequencer_backend.dart';

// Re-export backend types for backward compatibility
export '../models/backend/backend_types.dart';
// Re-export the FRB-canonical PlateSolveResult so callers can keep importing
// just `skotiq_backend.dart` after the model-layer copy was deleted.
// Also re-export CameraRecommendedSettings so device service / UI code can
// stay on the skotiq_backend import path.
export 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        PlateSolveResult,
        CameraRecommendedSettings,
        FitsReadResult,
        MountSite,
        MountSiteCapabilities,
        MountTimeInfo;

// Re-export the role interfaces so consumers that want a single import
// path can write `import '.../skotiq_backend.dart';` and still get
// the role types.
export 'roles/roles.dart';

/// Marker interface composing every role-specific backend interface.
///
/// Concrete backends (`FfiBackend`, `NetworkBackend`, `DisconnectedBackend`)
/// implement [SkotiqBackend], which unconditionally drags in every
/// role. Existing call sites that take a `SkotiqBackend` and use any
/// subset of methods continue to work unchanged.
///
/// **For new code**: prefer depending on the narrowest role you need
/// ([DeviceBackend], [GuidingBackend], [ImagingBackend], [SequencerBackend],
/// [ProfileSettingsBackend], [DiagnosticsBackend]) rather than the full
/// [SkotiqBackend]. Riverpod role-specific providers
/// (`deviceBackendProvider`, `imagingBackendProvider`, etc.) read through
/// the same underlying `backendProvider` state, so swapping backends
/// remains a single state mutation.
///
/// **Why a marker and not a fat interface body**: the contract lives in the
/// role files, so each consumer's intent is visible at its import list and a
/// backend can implement only the roles it can legitimately answer. The marker
/// keeps working the call sites that take one backend object.
///
/// **DO NOT add new methods to this class**. New methods belong in the
/// role interface for their concern. If no existing role fits, add a new
/// role file under `backend/roles/` and have [SkotiqBackend]
/// `implements` it.
abstract class SkotiqBackend
    implements
        DeviceBackend,
        GuidingBackend,
        ImagingBackend,
        SequencerBackend,
        ProfileSettingsBackend,
        DiagnosticsBackend,
        DepthLockBackend {
  // Intentionally empty. See class doc.
}
