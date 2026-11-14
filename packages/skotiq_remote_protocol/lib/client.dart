/// What only a client of an imaging host runs: finding hosts, probing them,
/// pairing with one and decoding its LAN alerts. Import `wire.dart` beside it
/// for the shared definitions.
library;

export 'src/discovery.dart';
export 'src/enhanced_discovery.dart';
export 'src/push/lan_push_broadcaster.dart'
    show LanPushDecodeFailure, LanPushDecodeResult, PushNotificationFrame;
export 'src/remote_pairing_client.dart';
export 'src/rig_discovery.dart';
export 'src/tailnet_detector.dart';
