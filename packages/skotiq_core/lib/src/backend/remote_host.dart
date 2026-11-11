import 'disconnected_backend.dart';
import 'ffi_backend.dart';
import 'network_backend.dart';
import 'network_backend/host_data/remote_host_calibration_library.dart';
import 'network_backend/host_data/remote_observation_log.dart';
import 'network_backend/host_data/host_poll.dart';
import 'network_backend/host_data/remote_host_runtime_mirror.dart';
import 'network_backend/host_data/remote_host_secondary_rig.dart';
import 'network_backend/host_data/remote_host_pointing.dart';
import 'network_backend/host_data/remote_host_rig_settings.dart';
import 'network_backend/host_data/remote_host_planning.dart';
import 'network_backend/host_data/remote_host_live_stack.dart';
import 'network_backend/host_data/remote_host_focus_data.dart';
import 'network_backend/host_data/remote_host_history.dart';
import 'network_backend/host_data/remote_host_notes.dart';
import 'network_backend/host_data/remote_host_run_state.dart';
import 'network_backend/host_data/remote_host_sequence_records.dart';
import 'network_backend/host_data/remote_host_target_records.dart';
import 'network_backend/host_data/remote_host_files.dart';
import 'network_backend/host_data/remote_host_calibration_frames.dart';
import 'network_backend/host_data/remote_host_image_records.dart';
import 'network_backend/host_data/remote_host_transients.dart';
import 'network_backend/host_data/remote_host_weather.dart';
import 'network_backend/host_data/remote_host_sky_atlas.dart';
import 'network_backend/host_data/remote_host_records.dart';
import 'network_backend/host_data/remote_observing_lists_store.dart';
import 'network_backend/host_data/remote_replay_debug_log.dart';
import 'network_backend/host_data/remote_science_products.dart';
import 'roles/host_data/calibration_library.dart';
import 'roles/host_data/host_runtime_mirror.dart';
import 'roles/host_data/host_secondary_rig.dart';
import 'roles/host_data/host_pointing.dart';
import 'roles/host_data/host_rig_settings.dart';
import 'roles/host_data/host_planning.dart';
import 'roles/host_data/host_live_stack.dart';
import 'roles/host_data/host_focus_data.dart';
import 'roles/host_data/host_history.dart';
import 'roles/host_data/host_notes.dart';
import 'roles/host_data/host_run_state.dart';
import 'roles/host_data/host_sequence_records.dart';
import 'roles/host_data/host_target_records.dart';
import 'roles/host_data/host_files.dart';
import 'roles/host_data/host_calibration_frames.dart';
import 'roles/host_data/host_image_records.dart';
import 'roles/host_data/host_transients.dart';
import 'roles/host_data/host_weather.dart';
import 'roles/host_data/host_sky_atlas.dart';
import 'roles/host_data/observation_log.dart';
import 'roles/host_data/observing_lists_store.dart';
import 'roles/host_data/replay_debug_log.dart';
import 'roles/host_data/science_products.dart';
import 'skotiq_backend.dart';

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

  /// Everything the host announces: device and run events and the
  /// notifications that its stored data changed.
  Stream<SkotiqEvent> get events => _backend.eventStream;

  /// The connection to the host: its name and whether it is answering.
  late final HostLink link = HostLink._(_backend);

  late final CalibrationLibrary calibrationLibrary =
      RemoteHostCalibrationLibrary(_backend);

  late final HostSkyAtlas skyAtlas = RemoteHostSkyAtlas(_backend);

  late final HostWeather weather = RemoteHostWeather(_backend);

  late final HostTransients transients = RemoteHostTransients(_backend);

  late final HostImageRecords imageRecords = RemoteHostImageRecords(_backend);

  /// The host's saved targets, sequences, sessions and runs.
  late final RemoteHostRecords records = RemoteHostRecords(_backend);

  late final HostCalibrationFrames calibrationFrames =
      RemoteHostCalibrationFrames(_backend);

  late final HostFiles files = RemoteHostFiles(_backend);

  late final HostTargetRecords targetRecords = RemoteHostTargetRecords(
    _backend,
  );

  late final HostSequenceRecords sequenceRecords = RemoteHostSequenceRecords(
    _backend,
  );

  late final HostRunState runState = RemoteHostRunState(_backend);

  late final HostNotes notes = RemoteHostNotes(_backend);

  late final HostHistory history = RemoteHostHistory(_backend);

  late final HostFocusData focusData = RemoteHostFocusData(_backend);

  late final HostLiveStack liveStack = RemoteHostLiveStack(_backend);

  late final HostPlanning planning = RemoteHostPlanning(_backend);

  late final HostRigSettings rigSettings = RemoteHostRigSettings(_backend);

  late final HostPointing pointing = RemoteHostPointing(_backend);

  late final HostSecondaryRig secondaryRig = RemoteHostSecondaryRig(_backend);

  late final HostRuntimeMirror runtimeMirror = RemoteHostRuntimeMirror(
    _backend,
  );

  late final ObservationLog observationLog = RemoteObservationLog(_backend);

  late final ObservingListsStore observingLists = RemoteObservingListsStore(
    _backend,
  );

  /// A new instance per call: the caller keeps it for as long as it wants
  /// that [pollInterval].
  ScienceProducts scienceProducts({
    Duration pollInterval = HostPoll.defaultInterval,
  }) => RemoteScienceProducts(_backend, pollInterval: pollInterval);

  late final ReplayDebugLog replayDebug = RemoteReplayDebugLog(_backend);

  late final SettingRows scienceSettingRows = RemoteScienceSettingRows(
    _backend,
  );
}

/// The connection between this client and the imaging host it is linked to.
final class HostLink {
  HostLink._(this._backend);

  final NetworkBackend _backend;

  /// The host's address as the user entered or discovered it.
  String get hostName => _backend.serverHost;

  BackendConnectionState get state => _backend.connectionState;

  Stream<BackendConnectionState> get states => _backend.connectionStateStream;

  /// True once the host refused this client's credentials. Nothing sent
  /// after that can succeed until the client is paired again.
  bool get credentialsRejected => _backend.isAuthTokenRejected;

  /// How long the host has left a heartbeat unanswered, or null when every
  /// heartbeat sent has been answered.
  Duration? get unansweredPingAge => _backend.unansweredPingAge;
}

extension HostDataDispatch on SkotiqBackend {
  /// True when this process is the imaging host: the devices, the capture
  /// files and the database are on this machine.
  bool get isImagingHost => this is FfiBackend;

  /// True when there is no imaging host: not this process, and none linked.
  bool get hasNoHost => this is DisconnectedBackend;

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
}
