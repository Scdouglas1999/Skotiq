import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('display endpoint retains destination while stripping secrets', () {
    expect(
      sanitizeEndpointForDisplay(
        'https://user:password@example.com:8443/releases/skotiq'
        '?token=secret#private',
      ),
      'https://example.com:8443/releases/skotiq',
    );
  });

  test('display endpoint rejects malformed and non-network values', () {
    expect(sanitizeEndpointForDisplay('not a URL'), isEmpty);
    expect(sanitizeEndpointForDisplay('file:///tmp/secret'), isEmpty);
  });

  test('remote version decoder also sanitizes older server responses', () {
    final version = RemoteVersionInfo.fromJson({
      'currentVersion': '6.0.0',
      'buildNumber': 60,
      'channel': 'stable',
      'platform': 'linux',
      'updateServerUrl':
          'https://user:password@updates.example.com/feed?token=secret',
    });

    expect(version.updateServerUrl, 'https://updates.example.com/feed');
  });
}
