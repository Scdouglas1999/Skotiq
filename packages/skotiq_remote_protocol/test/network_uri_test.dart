import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('brackets a bare IPv6 host in the URI authority', () {
    final uri = buildSkotiqServerUri(
      scheme: 'https',
      host: 'fd7a:115c:a1e0::1',
      port: 8443,
      pathAndQuery: '/api/info',
    );

    expect(uri.toString(), 'https://[fd7a:115c:a1e0::1]:8443/api/info');
    expect(uri.host, 'fd7a:115c:a1e0::1');
  });

  test('does not double-bracket an already wrapped IPv6 host', () {
    final uri = buildSkotiqServerUri(
      scheme: 'http',
      host: '[2001:db8::5]',
      port: 8080,
      pathAndQuery: '/api/status',
    );

    expect(uri.toString(), 'http://[2001:db8::5]:8080/api/status');
  });

  test('preserves an inline endpoint query', () {
    final uri = buildSkotiqServerUri(
      scheme: 'http',
      host: 'rig.local',
      port: 8080,
      pathAndQuery: '/api/logs?limit=50&level=warning',
    );

    expect(uri.path, '/api/logs');
    expect(uri.queryParameters, {'limit': '50', 'level': 'warning'});
  });
}
