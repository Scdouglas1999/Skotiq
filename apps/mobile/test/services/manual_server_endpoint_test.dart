import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/manual_server_endpoint.dart';

void main() {
  test('parses hostnames and custom ports', () {
    final endpoint = parseManualServerEndpoint('rig.example.ts.net:8123');

    expect(endpoint.host, 'rig.example.ts.net');
    expect(endpoint.port, 8123);
    expect(endpoint.scheme, 'http');
  });

  test('keeps an unbracketed IPv6 literal intact at the default port', () {
    final endpoint = parseManualServerEndpoint('fd7a:115c:a1e0::1');

    expect(endpoint.host, 'fd7a:115c:a1e0::1');
    expect(endpoint.port, 8080);
    expect(endpoint.authority, '[fd7a:115c:a1e0::1]:8080');
  });

  test('parses a bracketed IPv6 literal with a custom port', () {
    final endpoint = parseManualServerEndpoint('[2001:db8::5]:8443');

    expect(endpoint.host, '2001:db8::5');
    expect(endpoint.port, 8443);
  });

  test('accepts a pasted HTTPS server URL', () {
    final endpoint = parseManualServerEndpoint('https://rig.local:9443/');

    expect(endpoint.host, 'rig.local');
    expect(endpoint.port, 9443);
    expect(endpoint.scheme, 'https');
  });

  test('rejects malformed and out-of-range ports', () {
    expect(
      () => parseManualServerEndpoint('rig.local:not-a-port'),
      throwsFormatException,
    );
    expect(
      () => parseManualServerEndpoint('rig.local:70000'),
      throwsFormatException,
    );
  });
}
