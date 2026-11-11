import 'network_backend.dart';
import 'network_backend/host_data/remote_host_calibration_library.dart';
import 'network_backend/host_data/remote_observation_log.dart';
import 'network_backend/host_data/remote_observing_lists_store.dart';
import 'roles/host_data/calibration_library.dart';
import 'roles/host_data/observation_log.dart';
import 'roles/host_data/observing_lists_store.dart';
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

  late final CalibrationLibrary calibrationLibrary =
      RemoteHostCalibrationLibrary(_backend);

  late final ObservationLog observationLog = RemoteObservationLog(_backend);

  late final ObservingListsStore observingLists = RemoteObservingListsStore(
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
  RemoteHost? get remoteHost {
    final self = this;
    if (self is! NetworkBackend) return null;
    return RemoteHost._hosts[self] ??= RemoteHost._(self);
  }
}
