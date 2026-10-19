import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/session/last_frame_metrics_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_format.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_stats_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'session_test_support.dart';

CapturedImageData _current({required String path, required ImageStats stats}) =>
    CapturedImageData(
      width: 1,
      height: 1,
      displayData: Uint8List(4),
      histogram: List<int>.filled(256, 1),
      stats: stats,
      capturedAt: kNight.add(const Duration(minutes: 40)),
      settings:
          const ExposureSettings(exposureTime: 180, gain: 139, offset: 21),
      filePath: path,
    );

MetricVm _metric(NightLastFrameVm vm, String key) =>
    vm.metrics.firstWhere((m) => m.label.key == key);

/// Four Ha frames and one rejected, a dark that is not a light, and one
/// frame nothing graded.
Future<void> _seedNight(SessionHarness h) async {
  await h.addFrame(minutes: 0, hfr: 2.20, starCount: 1100, noise: 11.0);
  await h.addFrame(minutes: 10, hfr: 2.10, starCount: 1150, noise: 11.4);
  await h.addFrame(
    minutes: 20,
    hfr: 3.05,
    starCount: 412,
    noise: 14.0,
    accepted: false,
  );
  await h.addFrame(minutes: 25, frameType: 'dark');
  await h.addFrame(minutes: 30, hfr: 2.30, starCount: 1200, noise: 11.2);
  await h.addFrame(minutes: 40, path: '/data/m74/ungraded.fits');
}

void main() {
  test('the strip lists the session lights oldest first', () async {
    final h = await sessionHarness();
    await _seedNight(h);
    final frames = await h.settle(nightSessionFramesProvider);

    expect(frames.map((f) => f.frameNumber), <int>[1, 2, 3, 4, 5]);
    expect(frames.where((f) => f.isNewest).single.frameNumber, 5);
    expect(frames.map((f) => f.hfr), <double?>[2.20, 2.10, 3.05, 2.30, null]);
    expect(frames.first.filePath, '/data/m74/frame_0.fits');
  });

  test('a rejected frame is flagged and an ungraded one has no verdict',
      () async {
    final h = await sessionHarness();
    await _seedNight(h);
    final frames = await h.settle(nightSessionFramesProvider);

    expect(
        frames.map((f) => f.accepted), <bool?>[true, true, false, true, null]);

    final series = await h.settle(nightFrameSeriesProvider);
    final hfr = series.lines.firstWhere((l) => l.id == NightSeriesId.hfr);
    expect(hfr.points[2].accepted, isFalse);
    expect(hfr.points[2].y, 3.05);
    expect(
      series.markers.where((m) => m.kind == SeriesMarkerKind.reject).single.t,
      kNight.add(const Duration(minutes: 20)),
    );
    expect(series.sampleCount, 5);
    // The rejected frame's 3.05 is not the night's best.
    final min =
        series.legend.firstWhere((m) => m.label.key == 'nightSessionHfrMin');
    expect(min.value, '2.10');
  });

  test('last frame deltas are taken against the night medians', () async {
    final h = await sessionHarness(
      overrides: <Override>[
        currentImageProvider.overrideWith(
          (ref) => _current(
            path: '/data/m74/frame_30.fits',
            stats: const ImageStats(
              hfr: 2.30,
              starCount: 1200,
              noise: 11.2,
              fwhm: 3.4,
              snr: 38.6,
            ),
          ),
        ),
      ],
    );
    await _seedNight(h);
    final vm = (await h.settle(nightLastFrameProvider))!;

    expect(vm.frameNumber, 4);
    expect(vm.histogram, hasLength(256));
    // Accepted HFRs 2.20, 2.10, 2.30: median 2.20. The rejected 3.05 and the
    // ungraded frame stay out of it.
    final hfr = _metric(vm, 'nightSessionMetricHfr');
    expect(hfr.value, '2.30');
    expect(hfr.delta, '+0.10');
    final stars = _metric(vm, 'nightSessionMetricStars');
    expect(stars.value, '1200');
    expect(stars.delta, '+50');
    expect(stars.deltaTone, MetricTone.good);
    final noise = _metric(vm, 'nightSessionMetricBgSigma');
    expect(noise.delta, '0.0');
  });

  test('a metric the night never measured has no delta', () async {
    final h = await sessionHarness(
      overrides: <Override>[
        currentImageProvider.overrideWith(
          (ref) => _current(
            path: '/data/m74/frame_30.fits',
            stats: const ImageStats(hfr: 2.30, fwhm: 3.4, snr: 38.6),
          ),
        ),
      ],
    );
    await _seedNight(h);
    final vm = (await h.settle(nightLastFrameProvider))!;

    // The rows carry no FWHM and the in-memory list is empty.
    final fwhm = _metric(vm, 'nightSessionMetricFwhm');
    expect(fwhm.value, '3.40');
    expect(fwhm.delta, isNull);
    expect(_metric(vm, 'nightSessionMetricSnr').delta, isNull);
    // No eccentricity on the frame at all: a dash, not 0.
    final ecc = _metric(vm, 'nightSessionMetricEcc');
    expect(ecc.value, isNull);
    expect(ecc.delta, isNull);
  });

  test('two frames are too few for a median', () async {
    final h = await sessionHarness(
      overrides: <Override>[
        currentImageProvider.overrideWith(
          (ref) => _current(
            path: '/data/m74/frame_10.fits',
            stats: const ImageStats(hfr: 2.10),
          ),
        ),
      ],
    );
    await h.addFrame(minutes: 0, hfr: 2.20);
    await h.addFrame(minutes: 10, hfr: 2.10);
    final vm = (await h.settle(nightLastFrameProvider))!;
    expect(_metric(vm, 'nightSessionMetricHfr').delta, isNull);
  });

  test('the solve offset is measured against the active target', () async {
    final target = TargetHeaderNode(
      id: 't1',
      targetName: 'M74',
      raHours: 1.6117,
      decDegrees: 15.7836,
    );
    final h = await sessionHarness(
      overrides: <Override>[
        runDashboardActiveTargetProvider.overrideWithValue(target),
      ],
    );
    // 0.8″ north of the target.
    await h.addFrame(
      minutes: 0,
      hfr: 2.2,
      solvedRa: 1.6117,
      solvedDec: 15.7836 + 0.8 / 3600,
    );
    final vm = (await h.settle(nightLastFrameProvider))!;
    expect(_metric(vm, 'nightSessionMetricOffTarget').value, '0.8″');
    // No frame on screen: the newest row stands in, with what it stores.
    expect(_metric(vm, 'nightSessionMetricFwhm').value, isNull);
  });

  test('no frames and no image: no last-frame block', () async {
    final h = await sessionHarness();
    expect(await h.settle(nightLastFrameProvider), isNull);
  });

  test('session stats fall back to the rows without a live run', () async {
    final h = await sessionHarness(
      overrides: <Override>[
        nightCaptureFreeBytesProvider.overrideWithValue(639 * (1 << 30)),
        nightSessionNowProvider.overrideWithValue(kNight),
      ],
    );
    await _seedNight(h);
    final vm = await h.settle(nightSessionStatsProvider);
    String? value(String key) =>
        vm.metrics.firstWhere((m) => m.label.key == key).value;

    expect(vm.frameCount, 5);
    expect(value('nightSessionStatAccepted'), '4');
    expect(value('nightSessionStatRejected'), '1');
    expect(
      vm.metrics
          .firstWhere((m) => m.label.key == 'nightSessionStatRejected')
          .valueTone,
      MetricTone.bad,
    );
    expect(value('nightSessionStatIntegration'), '12m');
    expect(value('nightSessionStatDisk'), '639 GB');
    // The run's own counters are the only source for these.
    expect(
      vm.metrics.map((m) => m.label.key),
      isNot(contains('nightSessionStatAutofocus')),
    );
  });

  test('session stats read the live run counters', () async {
    final live = SequenceRunStats()
      ..framesCaptured = 87
      ..framesRejected = 3
      ..integrationSecs = 4 * 3600 + 12 * 60
      ..autofocusRuns = 3
      ..ditherCount = 28;
    final h = await sessionHarness(
      overrides: <Override>[
        liveSequenceStatsProvider.overrideWith((ref) => live),
        nightCaptureFreeBytesProvider.overrideWithValue(null),
      ],
    );
    final vm = await h.settle(nightSessionStatsProvider);
    String? value(String key) =>
        vm.metrics.firstWhere((m) => m.label.key == key).value;

    expect(vm.frameCount, 87);
    expect(value('nightSessionStatAccepted'), '84');
    expect(value('nightSessionStatIntegration'), '4h 12m');
    expect(value('nightSessionStatAutofocus'), '3');
    expect(value('nightSessionStatDithers'), '28');
    // No disk sample yet: the row is left out, not shown as 0.
    expect(
      vm.metrics.map((m) => m.label.key),
      isNot(contains('nightSessionStatDisk')),
    );
  });

  test('format helpers', () {
    expect(nightSignedDelta(-0.04, 2), '−0.04');
    expect(nightSignedDelta(0.001, 2), '0.00');
    expect(nightGrouped(45484), '45 484');
    expect(nightMedian(<double?>[1, null, 3]), isNull);
    expect(nightMedian(<double?>[1, 2, 3, 10]), 2.5);
  });
}
