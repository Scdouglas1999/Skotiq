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
import 'roles/host_data/host_backups.dart';
import 'roles/host_data/host_catalogs.dart';
import 'roles/host_data/host_cloud_sync.dart';
import 'roles/host_data/host_logs.dart';
import 'roles/host_data/host_notifications.dart';
import 'roles/host_data/host_jobs.dart';
import 'roles/host_data/host_updates.dart';
import 'roles/host_data/host_science.dart';
import 'roles/host_data/host_transients.dart';
import 'roles/host_data/host_sky_atlas.dart';
import 'roles/host_data/host_control_session.dart';
import 'roles/host_data/host_night_control.dart';
import 'roles/host_data/host_link.dart';
import 'roles/host_data/host_live_stack.dart';
import 'roles/host_data/host_planning_data.dart';
import 'roles/host_data/host_post_session.dart';
import 'roles/host_data/host_sequence_library.dart';
import 'roles/host_data/observation_log.dart';
import 'roles/host_data/observing_lists_store.dart';
import 'skotiq_backend.dart';
import 'roles/host_data/host_runtime_mirror.dart';
import 'roles/host_data/host_secondary_rig.dart';
import 'roles/host_data/host_pointing.dart';
import 'roles/host_data/host_rig_settings.dart';
import 'roles/host_data/host_history.dart';
import 'roles/host_data/host_notes.dart';
import 'roles/host_data/host_run_state.dart';
import 'roles/host_data/host_calibration_frames.dart';
import 'roles/host_data/host_replay_debug.dart';
import 'roles/host_data/host_weather.dart';
import 'network_backend/host_data/host_poll.dart';
import 'network_backend/host_data/remote_host_records.dart';
import 'network_backend/host_data/remote_science_products.dart';
import 'roles/host_data/science_products.dart';

export 'roles/host_data/host_calibration_tools.dart';
export 'roles/host_data/host_imaging_records.dart';
export 'roles/host_data/host_device_control.dart';
export 'roles/host_data/host_files.dart';
export 'roles/host_data/host_focus_models.dart';
export 'roles/host_data/host_profiles.dart';
export 'roles/host_data/host_backups.dart';
export 'roles/host_data/host_catalogs.dart';
export 'roles/host_data/host_cloud_sync.dart';
export 'roles/host_data/host_logs.dart';
export 'roles/host_data/host_notifications.dart';
export 'roles/host_data/host_jobs.dart';
export 'roles/host_data/host_updates.dart';
export 'roles/host_data/host_science.dart';
export 'roles/host_data/host_transients.dart';
export 'roles/host_data/host_sky_atlas.dart';
export 'roles/host_data/host_control_session.dart';
export 'roles/host_data/host_night_control.dart';
export 'roles/host_data/host_link.dart';
export 'roles/host_data/host_live_stack.dart';
export 'roles/host_data/host_planning_data.dart';
export 'roles/host_data/host_post_session.dart';
export 'roles/host_data/host_sequence_library.dart';
export 'roles/host_data/host_runtime_mirror.dart';
export 'roles/host_data/host_secondary_rig.dart';
export 'roles/host_data/host_pointing.dart';
export 'roles/host_data/host_rig_settings.dart';
export 'roles/host_data/host_history.dart';
export 'roles/host_data/host_notes.dart';
export 'roles/host_data/host_run_state.dart';
export 'roles/host_data/host_calibration_frames.dart';
export 'roles/host_data/host_replay_debug.dart';
export 'roles/host_data/host_weather.dart';

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

  HostBackups get backups => _backend;

  HostCatalogs get catalogs => _backend;

  HostCloudSync get cloudSync => _backend;

  HostLogs get logs => _backend;

  HostNotifications get notifications => _backend;

  HostJobs get jobs => _backend;

  HostUpdates get updates => _backend;

  HostScience get science => _backend;

  HostTransients get transients => _backend;

  HostSkyAtlas get skyAtlas => _backend;

  HostControlSession get control => _backend;

  HostNightControl get night => _backend;

  HostLiveStack get liveStack => _backend;

  HostPlanningData get planning => _backend;

  HostPostSession get postSession => _backend;

  HostSequenceLibrary get sequences => _backend;

  HostRuntimeMirror get runtimeMirror => _backend;

  HostSecondaryRig get secondaryRig => _backend;

  HostPointing get pointing => _backend;

  HostRigSettings get rigSettings => _backend;

  HostHistory get history => _backend;

  HostNotes get notes => _backend;

  HostRunState get runState => _backend;

  HostCalibrationFrames get calibrationFrames => _backend;

  HostReplayDebug get replayDebug => _backend;

  HostWeather get weather => _backend;

  /// Everything the host announces: device and run events and the
  /// notifications that its stored data changed.
  Stream<SkotiqEvent> get events => _backend.eventStream;

  /// The host's saved targets, sequences, sessions and runs, as the row types
  /// the local database yields (`TargetLibrary`, `SequenceLibrary`,
  /// `SessionHistory`, `RunHistory`).
  late final RemoteHostRecords records = RemoteHostRecords(_backend);

  /// A new instance per call: the caller keeps it for as long as it wants
  /// that [pollInterval].
  ScienceProducts scienceProducts({
    Duration pollInterval = HostPoll.defaultInterval,
  }) => RemoteScienceProducts(_backend, pollInterval: pollInterval);

  late final SettingRows scienceSettingRows = RemoteScienceSettingRows(
    _backend,
  );
}

extension HostDataDispatch on SkotiqBackend {
  /// The remote side of the host-data roles, or null when host data lives in
  /// this process's own database (a local backend, or no host at all).
  ///
  /// One [RemoteHost] per backend instance, so the roles it hands out are
  /// stable for as long as that backend is current and can be compared by
  /// identity.
  RemoteHost? get remoteHost => _remoteHostOf(this);

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

/// The same questions for a backend held as its sequencer role, which is how
/// the shell and the run screens receive it.
extension SequencerRoleHostDispatch on SequencerBackend {
  RemoteHost? get remoteHost => _remoteHostOf(this);

  bool get hasNoHost => this is DisconnectedBackend;
}

RemoteHost? _remoteHostOf(Object backend) {
  if (backend is! NetworkBackend) return null;
  return RemoteHost._hosts[backend] ??= RemoteHost._(backend);
}

/// The same questions for a backend held as its diagnostics role, which is
/// how the notification router and the host sync binding receive it.
extension DiagnosticsRoleHostDispatch on DiagnosticsBackend {
  RemoteHost? get remoteHost => _remoteHostOf(this);

  bool get hasNoHost => this is DisconnectedBackend;

  bool get ownsDeviceBridge => this is FfiBackend;
}

/// The same question for a backend held as its device role, which is how the
/// device state notifiers receive it.
extension DeviceRoleHostDispatch on DeviceBackend {
  RemoteHost? get remoteHost => _remoteHostOf(this);
}

extension HostLinkIdentity on HostLink {
  /// Names this host among the hosts this client has linked to: address,
  /// port, scheme and pinned certificate. Used to key per-host preferences.
  String get identity =>
      '${scheme.toLowerCase()}://'
      '${serverHost.trim().toLowerCase()}:$serverPort|'
      '${pinnedFingerprint?.trim().toLowerCase() ?? ''}';
}
