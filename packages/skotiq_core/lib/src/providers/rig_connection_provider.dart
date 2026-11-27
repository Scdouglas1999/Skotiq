import 'dart:async';

import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../backend/remote_host.dart';
import '../backend/skotiq_backend.dart';
import '../services/linked_rig/rig_connection_service.dart';
import 'backend_provider.dart';
import 'linked_host.dart';
import 'profiles_provider.dart';
import 'settings_provider.dart';

/// What the device running the connect flow provides. The phone overrides it;
/// nothing else runs the flow.
final rigConnectionDeviceProvider = Provider<RigConnectionDevice>(
  (_) => throw UnimplementedError(
    'rigConnectionDeviceProvider is set by the app that connects to rigs.',
  ),
);

/// The phone's connect flow and what its connection screen shows.
final rigConnectionProvider = ChangeNotifierProvider<RigConnectionService>((
  ref,
) {
  final service = RigConnectionService(
    device: ref.watch(rigConnectionDeviceProvider),
    session: _BackendSession(ref),
  );
  ref.listen(backendProvider, (_, next) {
    service.backendChanged(offersLink: next.hostPlace.offersLink);
  });
  // The watch follows the link, whoever made it. A backend listener would
  // run before the link is rebuilt.
  ref.listen<HostLink?>(linkedHostLinkProvider, (previous, next) {
    if (next != null && !identical(previous, next)) service.startLinkWatch();
  });
  // The phone's shell reads this as it starts, and the search begins then:
  // the connection screen's first frame already shows it.
  unawaited(service.autoConnect());
  return service;
});

/// The rig this phone is linked to, as the connect flow reports it: set when
/// a connect succeeds, cleared when the session ends. Null while not linked.
final connectedRigProvider = Provider<DiscoveredServer?>(
  (ref) => ref.watch(rigConnectionProvider.select((c) => c.state.connected)),
);

class _BackendSession implements RigConnectionSession {
  _BackendSession(this._ref);

  final Ref _ref;

  BackendNotifier get _backend => _ref.read(backendProvider.notifier);

  @override
  Future<Object?> open(
    DiscoveredServer server,
    RigCollaborationIdentity identity,
  ) async {
    final backend = _backend;
    try {
      await backend.connect(
        server.host,
        server.webPort,
        authToken: server.authToken,
        // A TLS-fronted tailnet host is dialled over wss.
        scheme: server.scheme,
        // The handshake verifies the host identity /api/info advertised
        // before the socket opens.
        pinnedFingerprint: server.fingerprint,
        collaborationViewerId: identity.viewerId,
        collaborationDeviceName: identity.deviceName,
        collaborationDisplayName: identity.displayName,
      );
    } on BackendTransitionSupersededException {
      return null;
    }
    return backend.currentBackend;
  }

  @override
  bool isCurrent(Object handle) =>
      handle is SkotiqBackend && _backend.isCurrentBackend(handle);

  @override
  bool get isLinked => _ref.read(isRemoteModeProvider);

  @override
  HostLink? get link => _ref.read(linkedHostLinkProvider);

  @override
  Future<void> disconnect() => _backend.disconnect();

  @override
  void afterLinked(bool Function() stillCurrent) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!stillCurrent()) return;
      _ref.invalidate(appSettingsProvider);
      _ref.invalidate(equipmentProfilesProvider);
    });
  }
}
