import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// The rig this phone is linked to, as the connect flow reports it: set when
/// a connect succeeds, cleared when the session ends. Null while not linked.
final connectedRigProvider = StateProvider<DiscoveredServer?>((ref) => null);

/// Links this phone to [server]: the compatibility check, pairing when the
/// rig asks for it, the backend connect, the start-up and saved-server
/// records, the connection monitor and push registration. Answers whether the
/// phone is now linked to it. [savedServerId] names the Saved Servers row the
/// operator picked, which keeps its own name and address.
typedef RigConnect =
    Future<bool> Function(DiscoveredServer server, {String? savedServerId});

/// The one connect flow, registered by the app shell, which owns the
/// connection screen it reports on. Null until the shell has started.
final rigConnectProvider = StateProvider<RigConnect?>((ref) => null);
