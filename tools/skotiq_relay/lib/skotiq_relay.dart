/// Skotiq relay: zero-config remote access beyond the LAN.
///
/// Three pieces share this package so the wire protocol can never drift:
///   * [RelayServer]       (`server.dart`): the self-hostable relay (see bin/relay.dart)
///   * [RelayUplink]       (`uplink.dart`): appliance side, outbound WS + local proxying
///   * [RelayTunnelClient] (`client.dart`): phone side, relay tunnel as a loopback port
///
/// Pure Dart (dart:io only + `crypto`); no Flutter. The apps import
/// `uplink.dart` or `client.dart`, so the server does not ship in them. This
/// library exports everything for the relay binary and the tests.
library;

export 'src/mux/frame.dart';
export 'src/mux/mux_session.dart';
export 'src/relay_credentials.dart';
export 'src/relay_server.dart';
export 'src/relay_tunnel_client.dart';
export 'src/relay_uplink.dart';
export 'src/relay_url.dart';
export 'src/socket_bridge.dart';
