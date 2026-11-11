import 'network_backend.dart';
import 'network_backend/host_data/remote_host_calibration_library.dart';
import 'network_backend/host_data/remote_observation_log.dart';
import 'network_backend/host_data/remote_observing_lists_store.dart';
import 'disconnected_backend.dart';
import 'ffi_backend.dart';
import 'roles/host_data/calibration_library.dart';
import 'roles/host_data/host_calibration_tools.dart';
import 'roles/host_data/host_imaging_records.dart';
import 'roles/host_data/host_device_control.dart';
import 'roles/host_data/host_files.dart';
import 'roles/host_data/host_focus_models.dart';
import 'roles/host_data/host_profiles.dart';
import 'roles/host_data/host_link.dart';
import 'roles/host_data/host_live_stack.dart';
import 'roles/host_data/host_planning_data.dart';
import 'roles/host_data/host_post_session.dart';
import 'roles/host_data/host_sequence_library.dart';
import 'roles/host_data/observation_log.dart';
import 'roles/host_data/observing_lists_store.dart';
import 'skotiq_backend.dart';

export 'roles/host_data/host_calibration_tools.dart';
export 'roles/host_data/host_imaging_records.dart';
export 'roles/host_data/host_device_control.dart';
export 'roles/host_data/host_files.dart';
export 'roles/host_data/host_focus_models.dart';
export 'roles/host_data/host_profiles.dart';
export 'roles/host_data/host_link.dart';
export 'roles/host_data/host_live_stack.dart';
export 'roles/host_data/host_planning_data.dart';
export 'roles/host_data/host_post_session.dart';
export 'roles/host_data/host_sequence_library.dart';

/// The data roles of a backend whose imaging host is another machine.
///
/// Host-owned data (observing lists, the calibration library, sessions, ...)
/// lives in the host's database. A linked client reaches it over the host API;
/// the host itself reads its own database. Each such data set is a role
/// interface under `roles/host_data/` with one implementation per side, and
/// this class is where the remote side of every role hangs.
///
/// Callers do not test which backend they have. They ask
/// [HostDataDispatch.remoteHost] and fall back to the local implementation:
///
/// ```dart
/// final observingListsStoreProvider = Provider<ObservingListsStore>(
///   (ref) =>
///       ref.watch(backendProvider).remoteHost?.observingLists ??
///       ref.watch(observingListsDaoProvider),
/// );
/// ```
final class RemoteHost {
  RemoteHost._(this._backend);

  final NetworkBackend _backend;

  static final _hosts = Expando<RemoteHost>('RemoteHost');

  late final CalibrationLibrary calibrationLibrary =
      RemoteHostCalibrationLibrary(_backend);

  late final ObservationLog observationLog = RemoteObservationLog(_backend);

  late final ObservingListsStore observingLists = RemoteObservingListsStore(
    _backend,
  );

  // Roles below have no shared local interface yet: the feature's service or
  // screen holds the local half and asks for the host's half here. The host
  // client itself answers them until the shared route definitions land.

  /// The connection to the host: where it is and whether it answers.
  HostLink get link => _backend;

  HostCalibrationTools get calibrationTools => _backend;

  HostImagingRecords get imagingRecords => _backend;

  HostDeviceControl get devices => _backend;

  HostFiles get files => _backend;

  HostFocusModels get focusModels => _backend;

  HostProfiles get profiles => _backend;

  HostLiveStack get liveStack => _backend;

  HostPlanningData get planning => _backend;

  HostPostSession get postSession => _backend;

  HostSequenceLibrary get sequences => _backend;
}

extension HostDataDispatch on SkotiqBackend {
  /// The remote side of the host-data roles, or null when host data lives in
  /// this process's own database (a local backend, or no host at all).
  ///
  /// One [RemoteHost] per backend instance, so the roles it hands out are
  /// stable for as long as that backend is current and can be compared by
  /// identity.
  RemoteHost? get remoteHost {
    final self = this;
    if (self is! NetworkBackend) return null;
    return RemoteHost._hosts[self] ??= RemoteHost._(self);
  }

  /// True when this process has no imaging host at all: it was launched as a
  /// client and is not linked, or its link was given up. Every host call
  /// fails; screens show what to connect instead of loading.
  bool get hasNoHost => this is DisconnectedBackend;

  /// True when the rig is this machine: its devices, files and database are
  /// in this process, so paths are local paths and device work happens here.
  bool get runsRigHere =>
      this is! NetworkBackend && this is! DisconnectedBackend;

  /// True when the device drivers are loaded in this process, so device calls
  /// that have no backend method yet may go straight to the bridge.
  bool get ownsDeviceBridge => this is FfiBackend;
}
