import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fakes.dart';

// Contract tests for the remote live-stacking client
// (`_NetworkBackendStackingOperations`). This is a protocol-authority
// boundary: a 200 response with missing/malformed fields is a protocol
// failure, NOT a legitimate idle/empty-stack signal. These tests pin that the
// client decodes complete, well-typed responses and rejects everything else
// with a `FormatException`, rather than manufacturing plausible zero/idle
// state that would show a truncated buffer or a dead host as healthy.

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

/// A complete, well-typed stats object (all six fields, correct numeric types).
Map<String, Object?> _stats({
  Object stackedFrameCount = 3,
  Object totalFramesAttempted = 5,
  Object rejectedAlignmentFailures = 1,
  Object avgMatchedPairs = 12.5,
  Object avgAlignmentResidual = 0.42,
  Object totalSigmaRejectedPixels = 128,
}) => {
  'stackedFrameCount': stackedFrameCount,
  'totalFramesAttempted': totalFramesAttempted,
  'rejectedAlignmentFailures': rejectedAlignmentFailures,
  'avgMatchedPairs': avgMatchedPairs,
  'avgAlignmentResidual': avgAlignmentResidual,
  'totalSigmaRejectedPixels': totalSigmaRejectedPixels,
};

/// The armed-before-first-frame stats the host returns: a *complete*
/// zero-valued object (never an omission).
Map<String, Object?> _zeroStats() => _stats(
  stackedFrameCount: 0,
  totalFramesAttempted: 0,
  rejectedAlignmentFailures: 0,
  avgMatchedPairs: 0.0,
  avgAlignmentResidual: 0.0,
  totalSigmaRejectedPixels: 0,
);

/// A complete `/api/stacking/result` JSON header.
Map<String, Object?> _meta({
  Object width = 2,
  Object height = 2,
  Object channels = 1,
  Map<String, Object?>? stats,
}) => {
  'active': true,
  'width': width,
  'height': height,
  'channels': channels,
  'stats': stats ?? _stats(),
};

/// Encode [samples] as a little-endian u16 byte buffer (low byte first).
List<int> _le16(List<int> samples) {
  final out = <int>[];
  for (final s in samples) {
    out.add(s & 0xFF);
    out.add((s >> 8) & 0xFF);
  }
  return out;
}

void main() {
  group('NetworkBackend stacking — valid decode', () {
    test(
      'valid mono result decodes dimensions, channels, stats, pixels',
      () async {
        final samples = [10, 20, 300, 65535]; // 2x2 mono
        final fake = FakeNetworkClient()
          ..setResponse('/api/stacking/result', body: jsonEncode(_meta()))
          ..setBinaryResponse(
            '/api/stacking/preview',
            bodyBytes: _le16(samples),
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        final result = await backend.stackingGetResult();
        expect(result.width, 2);
        expect(result.height, 2);
        expect(result.channels, 1);
        expect(result.data, samples);
        expect(result.stats.stackedFrameCount, 3);
        expect(result.stats.totalFramesAttempted, 5);
        expect(result.stats.rejectedAlignmentFailures, 1);
        expect(result.stats.avgMatchedPairs, 12.5);
        expect(result.stats.avgAlignmentResidual, 0.42);
        expect(result.stats.totalSigmaRejectedPixels, 128);
      },
    );

    test(
      'valid RGB result decodes 3 channels and interleaved samples',
      () async {
        final samples = [1, 2, 3, 4, 5, 6]; // 2x1 RGB = 6 samples
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/stacking/result',
            body: jsonEncode(_meta(width: 2, height: 1, channels: 3)),
          )
          ..setBinaryResponse(
            '/api/stacking/preview',
            bodyBytes: _le16(samples),
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        final result = await backend.stackingGetResult();
        expect(result.width, 2);
        expect(result.height, 1);
        expect(result.channels, 3);
        expect(result.data, samples);
      },
    );

    test('little-endian byte order is decoded correctly', () async {
      // Raw bytes chosen so a big-endian misread would produce different
      // values: [0x02,0x01] LE = 0x0102 = 258 (BE would be 0x0201 = 513);
      // [0xFF,0x00] LE = 0x00FF = 255 (BE would be 0xFF00 = 65280).
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/result',
          body: jsonEncode(_meta(width: 2, height: 1, channels: 1)),
        )
        ..setBinaryResponse(
          '/api/stacking/preview',
          bodyBytes: const [0x02, 0x01, 0xFF, 0x00],
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final result = await backend.stackingGetResult();
      expect(result.data, [258, 255]);
    });
  });

  group('NetworkBackend stacking — start/stats accept complete objects', () {
    test(
      'start accepts a complete zero-valued stats object (armed host)',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/stacking/start',
            method: 'POST',
            body: jsonEncode({'status': 'armed', 'stats': _zeroStats()}),
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);

        final stats = await backend.stackingStart();
        expect(stats.stackedFrameCount, 0);
        expect(stats.totalFramesAttempted, 0);
        expect(stats.avgMatchedPairs, 0.0);
        expect(stats.avgAlignmentResidual, 0.0);
        expect(stats.totalSigmaRejectedPixels, 0);
      },
    );

    test('start accepts a complete populated stats object', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/start',
          method: 'POST',
          body: jsonEncode({'status': 'started', 'stats': _stats()}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final stats = await backend.stackingStart(
        referencePath: '/host/ref.fits',
      );
      expect(stats.stackedFrameCount, 3);
      expect(stats.avgMatchedPairs, 12.5);
    });

    test('stats endpoint accepts a complete zero object', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/stats',
          body: jsonEncode({'stats': _zeroStats()}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final stats = await backend.stackingGetStats();
      expect(stats.stackedFrameCount, 0);
      expect(stats.totalFramesAttempted, 0);
    });
  });

  group('NetworkBackend stacking — malformed stats fail loudly', () {
    test('start with no stats field throws (not a silent zero)', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/start',
          method: 'POST',
          body: jsonEncode({'status': 'started'}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingStart(), throwsFormatException);
    });

    test('stats with no stats field throws', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/stacking/stats', body: '{}');
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingGetStats(), throwsFormatException);
    });

    test('stats missing a single field throws', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/stats',
          body: jsonEncode({..._statsBody()}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingGetStats(), throwsFormatException);
    });

    test('stats with a wrong-typed count throws', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/stats',
          body: jsonEncode({
            'stats': {..._stats(), 'stackedFrameCount': 'three'},
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingGetStats(), throwsFormatException);
    });

    test('stats with a negative count throws', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/stats',
          body: jsonEncode({
            'stats': {..._stats(), 'rejectedAlignmentFailures': -1},
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingGetStats(), throwsFormatException);
    });

    test('stats with a non-integral count throws', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/stats',
          body: jsonEncode({
            'stats': {..._stats(), 'stackedFrameCount': 1.5},
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingGetStats(), throwsFormatException);
    });

    test('stats with a negative average throws', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/stats',
          body: jsonEncode({
            'stats': {..._stats(), 'avgAlignmentResidual': -0.1},
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingGetStats(), throwsFormatException);
    });

    test('stats given as a non-object throws', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/stacking/stats', body: jsonEncode({'stats': 7}));
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingGetStats(), throwsFormatException);
    });
  });

  group('NetworkBackend stacking — status requires real fields', () {
    test(
      'complete status decodes (including a legitimate idle host)',
      () async {
        final running = FakeNetworkClient()
          ..setResponse(
            '/api/stacking/status',
            body: jsonEncode({
              'active': true,
              'frameCount': 7,
              'armed': true,
              'started': true,
            }),
          );
        final runningBackend = _backend(running);
        addTearDown(runningBackend.dispose);
        final live = await runningBackend.stackingStatus();
        expect(live.active, isTrue);
        expect(live.frameCount, 7);

        // A host that is genuinely idle reports a COMPLETE {active:false,
        // frameCount:0}; that is accepted (the fields are present and valid) —
        // only *missing* fields are rejected.
        final idle = FakeNetworkClient()
          ..setResponse(
            '/api/stacking/status',
            body: jsonEncode({'active': false, 'frameCount': 0}),
          );
        final idleBackend = _backend(idle);
        addTearDown(idleBackend.dispose);
        final rest = await idleBackend.stackingStatus();
        expect(rest.active, isFalse);
        expect(rest.frameCount, 0);
      },
    );

    test('status missing active throws (not a fake idle host)', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/status',
          body: jsonEncode({'frameCount': 0}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingStatus(), throwsFormatException);
    });

    test('status missing frameCount throws', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/status',
          body: jsonEncode({'active': false}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingStatus(), throwsFormatException);
    });

    test('status with a wrong-typed active throws', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/status',
          body: jsonEncode({'active': 'yes', 'frameCount': 0}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingStatus(), throwsFormatException);
    });

    test('status with a negative frameCount throws', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/status',
          body: jsonEncode({'active': true, 'frameCount': -1}),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.stackingStatus(), throwsFormatException);
    });
  });

  group('NetworkBackend stacking — result meta is validated', () {
    test('non-positive width throws', () async {
      final backend = _resultBackend(
        meta: _meta(width: 0),
        preview: _le16([1, 2, 3, 4]),
      );
      await expectLater(backend.stackingGetResult(), throwsFormatException);
    });

    test('negative height throws', () async {
      final backend = _resultBackend(
        meta: _meta(height: -3),
        preview: _le16([1, 2, 3, 4]),
      );
      await expectLater(backend.stackingGetResult(), throwsFormatException);
    });

    test('missing channels throws (no absent->mono fallback)', () async {
      final backend = _resultBackend(
        meta: {..._meta()}..remove('channels'),
        preview: _le16([1, 2, 3, 4]),
      );
      await expectLater(backend.stackingGetResult(), throwsFormatException);
    });

    test('unsupported channel count throws', () async {
      final backend = _resultBackend(
        meta: _meta(channels: 2),
        preview: _le16([1, 2, 3, 4]),
      );
      await expectLater(backend.stackingGetResult(), throwsFormatException);
    });

    test('missing stats on result throws', () async {
      final backend = _resultBackend(
        meta: {..._meta()}..remove('stats'),
        preview: _le16([1, 2, 3, 4]),
      );
      await expectLater(backend.stackingGetResult(), throwsFormatException);
    });
  });

  group('NetworkBackend stacking — preview body is size-checked', () {
    test('truncated preview throws', () async {
      // 2x2 mono needs 4 samples (8 bytes); supply only 2 samples.
      final backend = _resultBackend(meta: _meta(), preview: _le16([1, 2]));
      await expectLater(backend.stackingGetResult(), throwsFormatException);
    });

    test('odd-length preview throws', () async {
      final backend = _resultBackend(
        meta: _meta(),
        preview: const [1, 2, 3], // 3 bytes: cannot form whole u16 samples
      );
      await expectLater(backend.stackingGetResult(), throwsFormatException);
    });

    test('oversized preview throws', () async {
      // 2x2 mono needs 4 samples; supply 6.
      final backend = _resultBackend(
        meta: _meta(),
        preview: _le16([1, 2, 3, 4, 5, 6]),
      );
      await expectLater(backend.stackingGetResult(), throwsFormatException);
    });

    test('dimension-mismatched preview throws', () async {
      // Declared 2x3 mono = 6 samples; supply a 2x2-sized 4-sample buffer.
      final backend = _resultBackend(
        meta: _meta(width: 2, height: 3, channels: 1),
        preview: _le16([1, 2, 3, 4]),
      );
      await expectLater(backend.stackingGetResult(), throwsFormatException);
    });

    test('channel-mismatched preview throws', () async {
      // Declared 2x2 RGB = 12 samples; supply a mono-sized 4-sample buffer.
      final backend = _resultBackend(
        meta: _meta(width: 2, height: 2, channels: 3),
        preview: _le16([1, 2, 3, 4]),
      );
      await expectLater(backend.stackingGetResult(), throwsFormatException);
    });
  });
}

/// A stats body deliberately missing one required field (`totalFramesAttempted`).
Map<String, Object?> _statsBody() {
  final stats = {..._stats()}..remove('totalFramesAttempted');
  return {'stats': stats};
}

/// Register a `/result` + `/preview` pair and return a backend under test.
NetworkBackend _resultBackend({
  required Map<String, Object?> meta,
  required List<int> preview,
}) {
  final fake = FakeNetworkClient()
    ..setResponse('/api/stacking/result', body: jsonEncode(meta))
    ..setBinaryResponse('/api/stacking/preview', bodyBytes: preview);
  final backend = _backend(fake);
  addTearDown(backend.dispose);
  return backend;
}
