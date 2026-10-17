// The scanner parsers decide where the observatory thinks it is.
//
// A BSSID that is dropped, or a signal strength that is off by 30 dB, does not
// fail loudly: the positioning service answers anyway, with a worse position,
// and the app presents it with the same confidence as a good one. So the
// fixtures here are verbatim output from the real tools — including the two
// traps that cost real accuracy:
//
//   * `nmcli -t` escapes the colons INSIDE a BSSID as `\:` while still using a
//     bare colon as the field separator, so the obvious `split(':')` shreds
//     every row and the scan silently returns nothing.
//   * `nmcli`'s SIGNAL is NetworkManager's 0-100 quality, not dBm. The
//     expectations below are calibrated against `iw dev wlan0 scan dump` taken
//     on the same 12-network scan on this machine.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/services/positioning/wifi_positioning.dart';
import 'package:skotiq_planetarium/src/services/positioning/wifi_scan.dart';

/// Verbatim `nmcli -t -f BSSID,SIGNAL,CHAN,SSID dev wifi list --rescan yes`,
/// including the hidden-SSID rows (empty last field) and a `_nomap` opt-out.
const String _nmcliFixture =
    r'AA\:DA\:C4\:1E\:F5\:8A:100:2:'
    '\n'
    r'98\:DA\:C4\:1E\:F5\:89:100:40:TP-Link_F58A_5G'
    '\n'
    r'9C\:C9\:EB\:28\:D2\:F8:85:6:Fios-Guest'
    '\n'
    r'3C\:84\:6A\:78\:73\:CA:59:11:NETGEAR57'
    '\n'
    r'F8\:E4\:FB\:85\:22\:2E:44:1:linksys_nomap'
    '\n'
    r'28\:EE\:52\:A7\:4E\:FA:64:149:MyAltNet\:5G'
    '\n'
    '\n';

/// Verbatim `netsh wlan show networks mode=bssid` on Windows 11.
const String _netshFixture = '''
Interface name : Wi-Fi
There are 3 networks currently visible.

SSID 1 : TP-Link_F58A
    Network type            : Infrastructure
    Authentication          : WPA2-Personal
    Encryption              : CCMP
    BSSID 1                 : aa:da:c4:1e:f5:8a
         Signal             : 96%
         Radio type         : 802.11ax
         Band               : 2.4 GHz
         Channel            : 2
    BSSID 2                 : 98:da:c4:1e:f5:89
         Signal             : 90%
         Radio type         : 802.11ax
         Band               : 5 GHz
         Channel            : 40

SSID 2 : NETGEAR57
    Network type            : Infrastructure
    Authentication          : WPA2-Personal
    Encryption              : CCMP
    BSSID 1                 : 3c:84:6a:78:73:ca
         Signal             : 50%
         Radio type         : 802.11n
         Band               : 2.4 GHz
         Channel            : 11

SSID 3 : linksys_nomap
    Network type            : Infrastructure
    Authentication          : Open
    Encryption              : None
    BSSID 1                 : f8:e4:fb:85:22:2e
         Signal             : 38%
         Radio type         : 802.11n
         Band               : 2.4 GHz
         Channel            : 1
''';

/// Verbatim `iw dev wlan0 scan dump`, trimmed to the fields that matter.
const String _iwFixture = '''
BSS 3c:84:6a:78:73:ca(on wlan0)
	TSF: 1234567890 usec
	freq: 2462
	signal: -65.00 dBm
	SSID: NETGEAR57
	DS Parameter set: channel 11
BSS f8:e4:fb:85:22:2e(on wlan0)
	freq: 2412
	signal: -75.00 dBm
	SSID: linksys_nomap
	DS Parameter set: channel 1
BSS 9c:c9:eb:28:d2:f8(on wlan0)
	freq: 2437
	signal: -48.00 dBm
	SSID: Fios-Guest
	DS Parameter set: channel 6
BSS 11:22:33:44:55:66(on wlan0)
	freq: 2417
	signal: -94.00 dBm
	SSID: FarAway
	DS Parameter set: channel 2
''';

void main() {
  group('nmcli', () {
    final points = WifiScanner.parseNmcliList(_nmcliFixture);

    test('the escaped BSSID colons are not mistaken for field separators', () {
      expect(points.map((p) => p.macAddress), [
        'aa:da:c4:1e:f5:8a',
        '98:da:c4:1e:f5:89',
        '9c:c9:eb:28:d2:f8',
        '3c:84:6a:78:73:ca',
        '28:ee:52:a7:4e:fa',
      ]);
    });

    test('quality is converted to the dBm the driver actually reported', () {
      // Calibrated against `iw scan dump` on the same live scan: 59 -> -65,
      // 85 -> -49, 64 -> -61. NetworkManager clamps at -40, so 100 is -40.
      expect(points[0].signalStrengthDbm, -40);
      expect(points[2].signalStrengthDbm, -49);
      expect(points[3].signalStrengthDbm, -65);
      expect(points[4].signalStrengthDbm, -62);
    });

    test('channels ride along, including a 5 GHz one', () {
      expect(points.map((p) => p.channel), [2, 40, 6, 11, 149]);
    });

    test('a _nomap network is never put on the wire', () {
      expect(
        points.map((p) => p.macAddress),
        isNot(contains('f8:e4:fb:85:22:2e')),
      );
    });

    test('an SSID containing an escaped colon does not eat its own row', () {
      expect(points.last.macAddress, '28:ee:52:a7:4e:fa');
      expect(points.last.channel, 149);
    });

    test('a hidden SSID is still a usable landmark', () {
      expect(points.first.macAddress, 'aa:da:c4:1e:f5:8a');
    });

    test('empty output parses to nothing rather than throwing', () {
      expect(WifiScanner.parseNmcliList(''), isEmpty);
      expect(WifiScanner.parseNmcliList('\n\n'), isEmpty);
    });
  });

  group('netsh', () {
    final points = WifiScanner.parseNetshNetworks(_netshFixture);

    test('every BSSID under every SSID is collected', () {
      expect(points.map((p) => p.macAddress), [
        'aa:da:c4:1e:f5:8a',
        '98:da:c4:1e:f5:89',
        '3c:84:6a:78:73:ca',
      ]);
    });

    test('the signal percentage becomes dBm', () {
      // Microsoft documents the quality scale as linear over -100..-50 dBm.
      expect(points[0].signalStrengthDbm, -52);
      expect(points[1].signalStrengthDbm, -55);
      expect(points[2].signalStrengthDbm, -75);
    });

    test('channels are read from the per-BSSID block, not the SSID block', () {
      expect(points.map((p) => p.channel), [2, 40, 11]);
    });

    test('a _nomap network is never put on the wire', () {
      expect(
        points.map((p) => p.macAddress),
        isNot(contains('f8:e4:fb:85:22:2e')),
      );
    });

    test('the "Interface name : Wi-Fi" header is not read as a BSSID', () {
      expect(points, hasLength(3));
    });
  });

  group('iw scan dump', () {
    final points = WifiScanner.parseIwScanDump(_iwFixture);

    test('the header BSSID and its indented signal pair up', () {
      expect(points.map((p) => p.macAddress), [
        '3c:84:6a:78:73:ca',
        '9c:c9:eb:28:d2:f8',
      ]);
      expect(points.map((p) => p.signalStrengthDbm), [-65, -48]);
      expect(points.map((p) => p.channel), [11, 6]);
    });

    test('a beacon from three streets over is left out', () {
      // -94 dBm is below the useful floor: the service weights by distance and
      // a radio that faint drags the estimate towards somewhere else.
      expect(
        points.map((p) => p.macAddress),
        isNot(contains('11:22:33:44:55:66')),
      );
    });

    test('the interface name comes out of `iw dev`', () {
      const listing = '''
phy#0
	Interface wlan0
		ifindex 3
		type managed
''';
      expect(WifiScanner.parseIwInterfaceName(listing), 'wlan0');
      expect(WifiScanner.parseIwInterfaceName('phy#0\n'), isNull);
    });
  });

  group('what goes on the wire', () {
    test('at most twenty access points, strongest first', () {
      final many = [
        for (var i = 0; i < 30; i++)
          WifiAccessPoint(
            macAddress: 'aa:bb:cc:dd:ee:${i.toRadixString(16).padLeft(2, '0')}',
            signalStrengthDbm: -30 - i,
          ),
      ];

      final sent = WifiPositioningProvider.strongest(many);

      expect(sent, hasLength(20));
      expect(sent.first.signalStrengthDbm, -30);
      expect(sent.last.signalStrengthDbm, -49);
    });
  });
}
