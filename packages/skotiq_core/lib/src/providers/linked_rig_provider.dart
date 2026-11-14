import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/linked_rig/linked_rig_store.dart';
import '../services/linked_rig/rig_link_service.dart';

/// Where this desktop remembers the imaging computer it links to.
final linkedRigStoreProvider = Provider<LinkedRigStore>(
  (_) => LinkedRigStore(),
);

final rigLinkServiceProvider = Provider<RigLinkService>(
  (ref) => RigLinkService(store: ref.watch(linkedRigStoreProvider)),
);

/// The remembered rig this launch is linked to, or null.
///
/// Set by the desktop entry point when the role came from the remembered rig
/// (no `--remote-host` flag or `SKOTIQ_REMOTE_*` variable). A launch driven by
/// flags or variables leaves it null: those runs did not pair through the app
/// and the app has nothing to say about their token's scope.
final launchLinkedRigProvider = Provider<LinkedRig?>((_) => null);

/// The remembered rig as the store holds it now, including one kept inactive
/// after "Use this computer instead". Invalidate after changing the store.
final rememberedRigProvider = FutureProvider<LinkedRig?>(
  (ref) => ref.watch(linkedRigStoreProvider).load(),
);

/// Restarts the app so it comes back in the role the store now records.
///
/// The role (this computer's own host, or a linked client) is fixed for the
/// life of the process: plugins, background services, the embedded server and
/// shutdown safing are all chosen in `main`. Changing it therefore means a
/// clean restart, never a swap inside a running process.
abstract class AppRelauncher {
  /// Close this window the normal way (the shell's quit confirmation still
  /// applies) and start the app again. Returns false when the operator
  /// cancelled the quit, in which case nothing changed.
  Future<bool> relaunch({required String reason});
}

/// Null where the app cannot restart itself (mobile, tests). The desktop entry
/// point overrides it.
final appRelauncherProvider = Provider<AppRelauncher?>((_) => null);
