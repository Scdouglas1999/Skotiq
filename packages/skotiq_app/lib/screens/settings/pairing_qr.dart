import 'package:skotiq_core/providers.dart' show WebServerState;
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show EnhancedSkotiqDiscovery;

/// The QR a phone scans to pair with this computer's Remote access server at
/// [host] (its LAN or tailnet address), carrying [pairingCode]. Null until
/// the server has started and said what it advertises.
String? pairingQrData(
  WebServerState webState, {
  required String host,
  required String? pairingCode,
}) {
  final advert = webState.advert;
  if (advert == null) return null;
  return EnhancedSkotiqDiscovery.generateQrData(
    advert,
    host: host,
    webPort: webState.actualPort,
    pairingCode: pairingCode,
  );
}
