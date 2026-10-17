// `constellationHubKey` replaced three byte-identical private copies —
// `ConstellationService._hubKey`, `CoImagingSessionService._hubKey`, and
// `SharedCalibrationLibrary.hubKey` — each of which carried a comment asking
// the reader to keep it in sync with the other two.
//
// The value is a join key across three tables written by those three services,
// so a drift in any one of them orphans rows in the other two. This pins the
// merged function against a verbatim copy of the body it replaced.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/constellation/constellation_hub_key.dart';

/// The body all three services carried, kept here so the merge is checkable
/// rather than asserted.
String _legacyHubKey(Uri hubBaseUrl) {
  final port = hubBaseUrl.hasPort ? ':${hubBaseUrl.port}' : '';
  return '${hubBaseUrl.scheme}://${hubBaseUrl.host}$port';
}

void main() {
  const urls = [
    'https://hub.example.org',
    'https://hub.example.org/',
    'https://hub.example.org/skotiq/',
    'https://hub.example.org:8443',
    'https://hub.example.org:443',
    'http://192.168.1.20:8088',
    'http://192.168.1.20:8088/v1/targets?order=9',
    'https://operator:secret@hub.example.org',
    'http://[2001:db8::1]:8088',
  ];

  test('the merged key matches the three bodies it replaced', () {
    for (final url in urls) {
      final uri = Uri.parse(url);
      expect(constellationHubKey(uri), _legacyHubKey(uri), reason: url);
    }
  });

  test('one hub yields one key however its URL was written', () {
    final keys = {
      for (final url in [
        'https://hub.example.org',
        'https://hub.example.org/',
        'https://hub.example.org/skotiq/',
        'https://operator:secret@hub.example.org',
      ])
        constellationHubKey(Uri.parse(url)),
    };
    expect(keys, {
      'https://hub.example.org',
    }, reason: 'a path prefix or a rotated token must not orphan prior rows');
  });

  test('scheme and explicit port stay part of the identity', () {
    expect(
      constellationHubKey(Uri.parse('http://hub.example.org')),
      isNot(constellationHubKey(Uri.parse('https://hub.example.org'))),
    );
    expect(
      constellationHubKey(Uri.parse('https://hub.example.org:8443')),
      'https://hub.example.org:8443',
    );
  });
}
