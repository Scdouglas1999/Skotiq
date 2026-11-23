// The appliance's static Avahi advert carries the TXT keys the in-process
// mDNS registration sends (HostAdvert.toTxt), so a phone browsing mDNS reads
// the host's fingerprint, name and mode before /api/info. The instance name
// and `name=Skotiq` stay as the appliance has always advertised them.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless/headless_discovery_bootstrap.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  HostAdvert advert({String hostName = 'skotiq-pi'}) => HostAdvert(
    hostName: hostName,
    hostMode: SkotiqHostMode.headless,
    version: '9.1.0',
    scheme: 'https',
    fingerprint: 'ab:cd:ef',
    authRequired: true,
  );

  test('the advert keeps its records and adds the host identity', () {
    final xml = renderAvahiServiceFile(port: 8443, advert: advert());
    expect(xml, contains('<port>8443</port>'));
    expect(xml, contains('<name replace-wildcards="yes">Skotiq on %h</name>'));
    final records = RegExp(
      '<txt-record>(.*)</txt-record>',
    ).allMatches(xml).map((m) => m.group(1)).toList();
    expect(records, [
      'version=9.1.0',
      'scheme=https',
      'pairingSupported=true',
      'name=Skotiq',
      'fingerprint=ab:cd:ef',
      'hostName=skotiq-pi',
      'hostMode=${SkotiqHostMode.headless.wire}',
    ]);
  });

  test('a host name is escaped for the XML', () {
    final xml = renderAvahiServiceFile(
      port: 8080,
      advert: advert(hostName: 'pi <lab> & co'),
    );
    expect(xml, contains('<txt-record>hostName=pi &lt;lab&gt; &amp; co'));
  });
}
