import 'dart:io';

import 'package:skotiq_core/skotiq_core.dart';

const _headlessLogSource = 'HeadlessMain';


/// Directory avahi-daemon watches for static service files on the appliance.
const _avahiServicesDir = '/etc/avahi/services';
const _avahiServiceFileName = 'skotiq.service';

/// (Re)write `/etc/avahi/services/skotiq.service` so its `<port>` matches
/// the live bound port and its `scheme=` TXT record matches the active scheme
/// (https when TLS is on, else http).
///
/// WHY: the appliance ships a STATIC Avahi service file (installed by
/// packaging/appliance/systemd/install.sh) with a hardcoded `<port>8080</port>`
/// and `scheme=http`. If the operator changes `SKOTIQ_PORT` or enables
/// `--tls`, that file no longer reflects reality and the mobile client's
/// `_skotiq._tcp` discovery connects to the wrong port/scheme. Rewriting it
/// at boot from the live values keeps mDNS discovery correct.
///
/// The services dir only exists (and is only writable) when running as the
/// packaged appliance. Anywhere else — dev desktop, CI, a host without Avahi,
/// or a read-only `/etc` — we log-and-continue. This must NEVER crash the
/// daemon: every failure mode is caught and downgraded to a log line.
void refreshAvahiServiceFile({
  required LoggingService logger,
  required int port,
  required String scheme,
  required String version,
}) {
  try {
    final dir = Directory(_avahiServicesDir);
    if (!dir.existsSync()) {
      // Not the appliance (or Avahi not installed). Nothing to refresh.
      logger.info(
        'Avahi services dir $_avahiServicesDir absent; skipping static mDNS '
        'service-file refresh (not running as the appliance).',
        source: _headlessLogSource,
      );
      return;
    }
    final contents = _renderAvahiServiceFile(
      port: port,
      scheme: scheme,
      version: version,
    );
    final file = File('$_avahiServicesDir/$_avahiServiceFileName');
    file.writeAsStringSync(contents, flush: true);
    logger.info(
      'Refreshed Avahi service file ${file.path}: port=$port scheme=$scheme. '
      'avahi-daemon picks up the change automatically.',
      source: _headlessLogSource,
    );
  } catch (e, st) {
    // Read-only /etc, permission denied, races with the installer, etc. The
    // UDP broadcast beacon and any in-process mDNS remain; discovery is
    // degraded but the daemon keeps running.
    logger.warning(
      'Could not refresh Avahi service file (best-effort): $e\n$st',
      source: _headlessLogSource,
    );
  }
}

/// Render the `_skotiq._tcp` Avahi service-group XML with the live [port],
/// [scheme] and [version]. Mirrors packaging/appliance/avahi/skotiq.service
/// (same service type + name/version/scheme/pairingSupported/name TXT records)
/// but with the runtime values substituted.
String _renderAvahiServiceFile({
  required int port,
  required String scheme,
  required String version,
}) {
  return '''
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<!--
  GENERATED AT BOOT by the Skotiq headless daemon (main_headless.dart,
  _refreshAvahiServiceFile). Do not edit by hand — it is overwritten on every
  start so the advertised <port> and scheme= TXT track the live bound port and
  TLS state. The static template lives at
  packaging/appliance/avahi/skotiq.service.
-->
<service-group>
  <name replace-wildcards="yes">Skotiq on %h</name>
  <service>
    <type>_skotiq._tcp</type>
    <port>$port</port>
    <txt-record>version=$version</txt-record>
    <txt-record>scheme=$scheme</txt-record>
    <txt-record>pairingSupported=true</txt-record>
    <txt-record>name=Skotiq</txt-record>
  </service>
</service-group>
''';
}
