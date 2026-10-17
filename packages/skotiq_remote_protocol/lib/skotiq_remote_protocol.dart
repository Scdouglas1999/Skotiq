/// Skotiq remote-control protocol — LAN discovery, pairing, and token
/// management used by the headless API server and the mobile companion.
library;

// The package holds discovery, auth, crypto and pairing primitives. Live
// remote control runs over REST + WebSocket from
// apps/desktop/lib/headless_api_server.dart, which both GUI and headless modes
// share; there is no peer-connection or signalling layer here.
export 'src/discovery.dart';
export 'src/enhanced_discovery.dart';
export 'src/tailnet_detector.dart';
export 'src/server_compatibility.dart';
export 'src/server_identity.dart';
export 'src/network_uri.dart';
export 'src/remote_pairing_client.dart';
export 'src/collaboration/live_collaboration_session.dart';

// Secure authentication
export 'src/auth/token_manager.dart';

// Server-side mDNS / Bonjour / DNS-SD advertisement.
export 'src/discovery/mdns_registration.dart';

// Database
export 'src/database/device_push_tables.dart';
export 'src/database/paired_devices_table.dart';
export 'src/database/pairing_database.dart';

// LAN UDP push fan-out + FCM/APNs scaffolding. The broadcaster
// runs on the desktop next to the WebSocket fan-out so paired phones
// receive critical alerts even when their WS has dropped. See header
// of lan_push_broadcaster.dart for the wire format + threat model.
export 'src/push/lan_push_broadcaster.dart';
export 'src/push/push_config.dart';
export 'src/push/push_delivery_targets.dart';
export 'src/push/push_jwt.dart';
export 'src/push/push_token_store.dart';
export 'src/push/remote_push_delivery.dart';

// v4 couch-grade remote — self-hostable relay tunnel (tools/skotiq_relay).
// Re-exported so the desktop headless bootstrap (RelayUplink) and the mobile
// transport (RelayTunnelClient) consume the relay client classes through this
// package, keeping the wire protocol in one place. The RelayServer itself is
// only used by the standalone CLI/Docker image and is intentionally NOT
// re-surfaced here.
export 'package:skotiq_relay/skotiq_relay.dart'
    show
        RelayUplink,
        RelayUplinkState,
        RelayUplinkStatus,
        RelayTunnelClient,
        RelayTunnelException,
        RelayCredentials,
        RelayCredentialsStore,
        FileRelayCredentialsStore,
        MemoryRelayCredentialsStore,
        isValidApplianceId;
