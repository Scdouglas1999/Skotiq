// The consent dialog must name exactly what each allowed tier sends.
//
// The failure this pins is silent by construction: a tier whose disclosure is
// missing still runs, and the operator has agreed to something they were never
// told about. Skotiq is routinely installed on isolated observatory
// networks, where the names of the networks around the house leaving the
// machine is a bigger deal than the position that comes back.
//
// The body is built by a pure function so the copy can be asserted per tier
// without pumping a dialog for each combination.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/geolocation_consent.dart';

void main() {
  String body({
    bool wifi = true,
    bool ip = true,
    bool google = false,
  }) =>
      geolocationConsentBody(
        outcome: kGeolocationWritesSiteOutcome,
        includeWifiScan: wifi,
        includeIpFallback: ip,
        googleKeyPresent: google,
      );

  test('the device tier is always disclosed, and says nothing leaves', () {
    expect(
      body(wifi: false, ip: false),
      contains('This device’s own location service, if it has one. Nothing '
          'leaves the machine.'),
    );
  });

  test('the Wi-Fi tier names what is sent, to whom, and that it is not kept',
      () {
    expect(
      body(),
      contains(
        'The names and signal strengths of nearby Wi-Fi networks, sent to '
        'beaconDB (an open positioning service). This is the step that finds '
        'your yard rather than your town. The networks are used for this one '
        'request and never saved.',
      ),
    );
  });

  test('a Google key changes who the network list goes to, and says so', () {
    final text = body(google: true);
    expect(text, contains('sent to Google (your Geolocation API key)'));
    expect(
        text,
        contains('and to beaconDB (an open positioning service) if '
            'Google cannot place them'));
  });

  test('the IP tier names the hosts, the scheme, and how coarse it is', () {
    expect(
      body(),
      contains(
        'Your public IP address, sent to ipinfo.io over HTTPS (falling back '
        'to ipwho.is). That only locates your internet provider — city '
        'level, tens of kilometres.',
      ),
    );
  });

  test('a tier that will not run is not disclosed', () {
    expect(body(wifi: false), isNot(contains('Wi-Fi')));
    expect(body(wifi: false), contains('ipinfo.io'));
    expect(body(ip: false), isNot(contains('ipinfo.io')));
    expect(body(ip: false), contains('Wi-Fi'));
  });

  test('the outcome paragraph closes the dialog', () {
    expect(body(), endsWith(kGeolocationWritesSiteOutcome));
    expect(
      geolocationConsentBody(
        outcome: kGeolocationOffersEstimateOutcome,
        includeWifiScan: false,
        includeIpFallback: true,
      ),
      endsWith(kGeolocationOffersEstimateOutcome),
    );
  });

  group('remembered consent', () {
    test('a wider grant covers a narrower request', () {
      const granted = GeolocationConsent(wifiScan: true, ip: true);
      expect(granted.covers(wifiScan: false, ip: true), isTrue);
      expect(granted.covers(wifiScan: true, ip: true), isTrue);
    });

    test('an IP-only grant does not authorise a Wi-Fi scan', () {
      const granted = GeolocationConsent(wifiScan: false, ip: true);
      expect(granted.covers(wifiScan: true, ip: true), isFalse);
      expect(granted.covers(wifiScan: false, ip: true), isTrue);
    });
  });
}
