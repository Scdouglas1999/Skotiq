import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import 'backend_provider.dart';

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

/// Declares the store of one kind of host-owned data: [here] where the
/// imaging host is this process, [linked] on a client of another machine.
///
/// Readers watch the provider and call the role; they never ask which side
/// they got. The side is chosen again only when the backend is replaced.
///
/// ```dart
/// final observingListsStoreProvider = hostRoleProvider<ObservingListsStore>(
///   here: (ref) => ref.watch(observingListsDaoProvider),
///   linked: (ref, host) => host.observingLists,
/// );
/// ```
Provider<Role> hostRoleProvider<Role>({
  required Role Function(Ref ref) here,
  required Role Function(Ref ref, RemoteHost host) linked,
  String? name,
}) => Provider<Role>((ref) {
  final host = ref.watch(remoteHostProvider);
  return host == null ? here(ref) : linked(ref, host);
}, name: name);
