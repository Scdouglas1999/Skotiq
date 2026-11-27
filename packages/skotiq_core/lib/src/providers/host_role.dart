import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../backend/skotiq_backend.dart';
import '../backend/host_place.dart';
import 'backend_provider.dart';
import 'launch_role.dart';

/// The linked host's side of every host-data role, or null when the imaging
/// host is this process and host data is in its own database.
///
/// This is the one place that turns the current backend into "which store
/// serves host data". A data set's provider is declared with
/// [hostRoleProvider]; code that is not about data (what to run on this
/// machine, what a control should say) reads [isRemoteModeProvider].
final remoteHostProvider = Provider<RemoteHost?>(
  (ref) => ref.watch(backendProvider).remoteHost,
);

/// The stand-in host of a client that is not linked: a phone, or a
/// `--remote-host` desktop, resting on no backend. Null where host data is
/// this process's own: a host launch, a linked client, the demo rig.
final unlinkedHostProvider = Provider<RemoteHost?>((ref) {
  if (ref.watch(launchRoleProvider).ownsRig) return null;
  final place = ref.watch(backendProvider.select((b) => b.hostPlace));
  if (place != HostPlace.none) return null;
  final host = RemoteHost.unlinked();
  ref.onDispose(host.dispose);
  return host;
});

/// Declares the store of one kind of host-owned data: [here] where the
/// imaging host is this process, [linked] on a client of another machine.
///
/// A client that is not linked reads the [linked] side of a host that
/// refuses every call ([unlinkedHostProvider]): its own database holds no
/// rig's data. [phoneKeeps] marks data the phone app keeps for browsing
/// without a rig (targets, lists, plans, notes); an unlinked phone reads its
/// own copy, and a `--remote-host` desktop still refuses.
///
/// Readers watch the provider and call the role; they never ask which side
/// they got. The side is chosen again only when the backend is replaced.
///
/// ```dart
/// final observingListsStoreProvider = hostRoleProvider<ObservingListsStore>(
///   here: (ref) => ref.watch(observingListsDaoProvider),
///   linked: (ref, host) => host.observingLists,
///   phoneKeeps: true,
/// );
/// ```
Provider<Role> hostRoleProvider<Role>({
  required Role Function(Ref ref) here,
  required Role Function(Ref ref, RemoteHost host) linked,
  bool phoneKeeps = false,
  String? name,
}) => Provider<Role>((ref) {
  final host = ref.watch(remoteHostProvider);
  if (host != null) return linked(ref, host);
  final unlinked = ref.watch(unlinkedHostProvider);
  if (unlinked == null) return here(ref);
  if (phoneKeeps && ref.watch(launchRoleProvider) == LaunchRole.mobile) {
    return here(ref);
  }
  return linked(ref, unlinked);
}, name: name);

/// Following the linked host across a change of host.
extension HostChangeListen on Ref {
  /// Calls [listener] the moment the backend is replaced, with what [select]
  /// makes of the new host (null where the imaging host is this process),
  /// when that differs from what it made of the old one.
  ///
  /// A provider derived from the backend hears of the change only when
  /// Riverpod re-evaluates it, after work started for the old host may
  /// already have resumed and been taken as the new host's.
  void listenAcrossHosts<T>(
    T Function(RemoteHost? host) select,
    void Function(T next) listener,
  ) {
    var current = select(read(backendProvider).remoteHost);
    listen<SkotiqBackend>(backendProvider, (_, next) {
      final value = select(next.remoteHost);
      if (value == current) return;
      current = value;
      listener(value);
    });
  }
}

/// Declares something only a linked client has, such as the link itself, the
/// host's log or its update: the host's [half], or null where the imaging
/// host is this process and the card, banner or action does not exist.
///
/// Every such half is declared in `linked_host.dart`. Data that both sides
/// keep is a [hostRoleProvider], not a null test on one of these.
Provider<Half?> linkedOnlyProvider<Half>(
  Half Function(RemoteHost host) half, {
  String? name,
}) => Provider<Half?>((ref) {
  final host = ref.watch(remoteHostProvider);
  return host == null ? null : half(host);
}, name: name);
