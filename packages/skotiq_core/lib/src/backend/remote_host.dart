import 'network_backend.dart';
import 'network_backend/host_data/remote_host_calibration_library.dart';
import 'network_backend/host_data/remote_notes_journal.dart';
import 'network_backend/host_data/remote_observation_log.dart';
import 'network_backend/host_data/remote_observing_lists_store.dart';
import 'network_backend/host_data/remote_polar_alignment_log.dart';
import 'disconnected_backend.dart';
import 'ffi_backend.dart';
import 'roles/host_data/calibration_library.dart';
import 'roles/host_data/host_link.dart';
import 'roles/host_data/notes_journal.dart';
import '../database/stores/observation_log.dart';
import '../database/stores/observing_lists_store.dart';
import '../database/stores/polar_alignment_log.dart';
import 'skotiq_backend.dart';
import 'network_backend/host_data/host_poll.dart';
import 'network_backend/host_data/remote_host_records.dart';
import 'network_backend/host_data/remote_science_products.dart';
import '../database/stores/science_products.dart';
import 'roles/host_data/photometric_transforms.dart';
import 'network_backend/host_data/remote_photometric_transforms.dart';
import '../models/backend/backend_types.dart';

export 'roles/host_data/host_link.dart';
// The host-only roles a RemoteHost hands out.
export 'network_backend.dart'
    show
        HostBackups,
        HostCalibrationFrames,
        HostCalibrationTools,
        HostCatalogs,
        HostCloudSync,
        HostControlSession,
        HostDeviceControl,
        HostFiles,
        HostFocusModels,
        HostHistory,
        HostImagingRecords,
        HostLiveStack,
        HostLogs,
        HostNightControl,
        HostNotes,
        HostNotifications,
        HostPlanningData,
        HostPointing,
        HostPostSession,
        HostProfiles,
        HostReplayDebug,
        HostRigSettings,
        HostRunState,
        HostRuntimeMirror,
        HostScience,
        HostSecondaryRig,
        HostSequenceLibrary,
        HostSettingsRows,
        HostSkyAtlas,
        HostTransients,
        HostUpdates,
        HostWeather,
        RemoteScienceBundle;

/// The host's side of everything a linked client reaches over the link.
///
/// Data both sides keep (observing lists, the calibration library, sessions,
/// ...) is one role interface with a local implementation, a DAO or service in
/// this process, and a remote one built here. Its provider is a
/// `hostRoleProvider` (`providers/host_role.dart`), which picks the side:
///
/// ```dart
/// final observingListsStoreProvider = hostRoleProvider<ObservingListsStore>(
///   here: (ref) => ref.watch(observingListsDaoProvider),
///   linked: (ref, host) => host.observingLists,
/// );
/// ```
///
/// What only a linked host has (its backups, logs, updates, weather verdict,
/// ...) is a class over the link (`network_backend/host_*.dart`), read through
/// a `linkedOnlyProvider` half (`providers/linked_host.dart`).
final class RemoteHost {
  RemoteHost._(this._backend);

  final NetworkBackend _backend;

  static final _hosts = Expando<RemoteHost>('RemoteHost');

  late final CalibrationLibrary calibrationLibrary =
      RemoteHostCalibrationLibrary(_backend);

  late final ObservationLog observationLog = RemoteObservationLog(_backend);

  late final NotesJournal notesJournal = RemoteNotesJournal(notes);

  late final PolarAlignmentLog polarAlignmentLog = RemotePolarAlignmentLog(
    history,
  );

  late final ObservingListsStore observingLists = RemoteObservingListsStore(
    _backend,
  );

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

  late final PhotometricTransforms photometricTransforms =
      RemotePhotometricTransforms(science);
}

extension HostDataDispatch on SkotiqBackend {
  /// The remote side of the host-data roles, or null when host data lives in
  /// this process's own database (a local backend, or no host at all).
  ///
  /// One [RemoteHost] per backend instance, so the roles it hands out are
  /// stable for as long as that backend is current and can be compared by
  /// identity.
  RemoteHost? get remoteHost => _remoteHostOf(this);

  /// True when this process is a client of an imaging host on another
  /// machine, reached over the link. The question `isRemoteModeProvider`
  /// answers, for code that holds the backend itself: a backend listener's
  /// new value, or the backend an operation began on.
  bool get linksToHost => this is NetworkBackend;

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
