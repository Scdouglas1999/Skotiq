// Deterministic tests for the effective, capability-resolved capture config
// (`FlatWizardService.resolveCaptureConfig`) and the bit-depth-aware ADU math.
//
// These pin the trust-hardening contract: the flat wizard targets the DETECTED
// camera range (8/10/12/14/16-bit or an explicit max-ADU), never a hardcoded
// 16-bit range; gain/offset are the profile/live values (null == camera
// default, not zero), clamped to the capability range and dropped when the
// camera cannot set them; binning honours the profile, the max-bin, and the
// asymmetric-bin capability; and a remote NetworkBackend is host-authoritative.

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _CapBackend extends Mock implements SkotiqBackend {}

class _RemoteCapBackend extends Mock implements NetworkBackend {}

CameraStatus _status({
  int maxAdu = 65535,
  int gain = 0,
  int offset = 0,
  int binX = 1,
  int binY = 1,
  bool canSetGain = true,
  bool canSetOffset = true,
}) => CameraStatus.fromJson({
  'connected': true,
  'gain': gain,
  'offset': offset,
  'binX': binX,
  'binY': binY,
  'maxAdu': maxAdu,
  'canSetGain': canSetGain,
  'canSetOffset': canSetOffset,
});

CameraCapabilities _caps({
  int bitDepth = 16,
  bool canSetGain = true,
  int? gainMin,
  int? gainMax,
  bool canSetOffset = true,
  int? offsetMin,
  int? offsetMax,
  bool canBin = true,
  int maxBinX = 1,
  int maxBinY = 1,
  bool canAsymmetricBin = false,
}) => CameraCapabilities.fromJson({
  'maxWidth': 1000,
  'maxHeight': 1000,
  'bitDepth': bitDepth,
  'canSetGain': canSetGain,
  'gainMin': gainMin,
  'gainMax': gainMax,
  'canSetOffset': canSetOffset,
  'offsetMin': offsetMin,
  'offsetMax': offsetMax,
  'canBin': canBin,
  'maxBinX': maxBinX,
  'maxBinY': maxBinY,
  'canAsymmetricBin': canAsymmetricBin,
});

void main() {
  const cam = 'native:asi:0';

  void stub(_CapBackend b, {CameraStatus? status, CameraCapabilities? caps}) {
    if (status != null) {
      when(() => b.getCameraStatus(cam)).thenAnswer((_) async => status);
    } else {
      when(() => b.getCameraStatus(cam)).thenThrow(StateError('no status'));
    }
    when(() => b.getCameraCapabilities(cam)).thenAnswer((_) async => caps);
  }

  group('effective max ADU (pixel container, not ADC range)', () {
    // The driver reports the PIXEL-CONTAINER ceiling. Bit depth describes ADC
    // precision and must never cap it: 12/14-bit astro CMOS drivers
    // left-justify their samples into the 16-bit pixel word, so a 12-bit
    // ASI1600MM genuinely produces values up to 65504 (measured live). Capping
    // by bit depth pinned its 50% target at 2048 ADU — below the camera's own
    // bias floor at the shortest possible exposure — so flats could never
    // converge.
    test(
      '12-bit left-justified sensor keeps the driver container scale',
      () async {
        final b = _CapBackend();
        stub(b, status: _status(maxAdu: 65520), caps: _caps(bitDepth: 12));
        final cfg = await FlatWizardService.resolveCaptureConfig(
          backend: b,
          deviceId: cam,
        );
        expect(
          cfg.maxAdu,
          65520,
          reason: '4095 << 4 — what the frames contain',
        );
        expect(cfg.bitDepth, 12, reason: 'ADC precision is still reported');
        expect(cfg.targetAduFor(50), closeTo(32760, 1));
      },
    );

    test('12-bit right-justified driver is believed at 4095', () async {
      final b = _CapBackend();
      // A driver that genuinely delivers 0..4095 samples reports so; the target
      // follows the driver, not an assumption about the container.
      stub(b, status: _status(maxAdu: 4095), caps: _caps(bitDepth: 12));
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
      );
      expect(cfg.maxAdu, 4095);
      expect(cfg.targetAduFor(50), closeTo(2047.5, 1));
    });

    test(
      '14-bit left-justified sensor keeps the driver container scale',
      () async {
        final b = _CapBackend();
        stub(b, status: _status(maxAdu: 65532), caps: _caps(bitDepth: 14));
        final cfg = await FlatWizardService.resolveCaptureConfig(
          backend: b,
          deviceId: cam,
        );
        expect(cfg.maxAdu, 65532, reason: '16383 << 2');
        expect(cfg.targetAduFor(50), closeTo(32766, 1));
      },
    );

    test('14-bit driver reporting its ADC range is believed', () async {
      final b = _CapBackend();
      stub(b, status: _status(maxAdu: 16383), caps: _caps(bitDepth: 14));
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
      );
      expect(cfg.maxAdu, 16383);
      expect(cfg.targetAduFor(50), closeTo(8191.5, 1));
    });

    test('16-bit camera keeps the 65535 full scale', () async {
      final b = _CapBackend();
      stub(b, status: _status(maxAdu: 65535), caps: _caps(bitDepth: 16));
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
      );
      expect(cfg.maxAdu, 65535);
      expect(cfg.targetAduFor(50), closeTo(32768, 1));
    });

    test('bit depth is a FALLBACK, never a cap on the driver value', () async {
      final b = _CapBackend();
      // No status (probe threw) but an 8-bit capability: the only information
      // available is the bit depth, so it is used.
      stub(b, status: null, caps: _caps(bitDepth: 8));
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
      );
      expect(cfg.maxAdu, 255);
      expect(cfg.rangeKnown, isTrue);
      expect(cfg.targetAduFor(50), closeTo(127.5, 1));
    });

    test('driver max-ADU without a capability struct is honoured', () async {
      final b = _CapBackend();
      // No caps at all, but the status reports a 14-bit-ish range.
      stub(b, status: _status(maxAdu: 16383), caps: null);
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
      );
      expect(cfg.maxAdu, 16383);
      expect(cfg.capabilitiesKnown, isFalse);
    });

    test('capability absent → safe 16-bit fallback', () async {
      final b = _CapBackend();
      // Status probe throws AND capabilities are null: fall back to 65535.
      stub(b, status: null, caps: null);
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
      );
      expect(cfg.maxAdu, FlatExposureCalculator.fallbackMaxAdu);
      expect(cfg.maxAdu, 65535);
      expect(cfg.capabilitiesKnown, isFalse);
      expect(
        cfg.gain,
        isNull,
        reason: 'no profile/live value → camera default',
      );
    });
  });

  group('ADU math is range-relative', () {
    test('histogramPercentToAdu scales with maxAdu', () {
      expect(FlatExposureCalculator.histogramPercentToAdu(50), 32768);
      expect(
        FlatExposureCalculator.histogramPercentToAdu(50, maxAdu: 4095),
        2048,
      );
      expect(
        FlatExposureCalculator.histogramPercentToAdu(75, maxAdu: 16383),
        12287,
      );
    });

    test('aduToHistogramPercent scales with maxAdu', () {
      expect(
        FlatExposureCalculator.aduToHistogramPercent(2048, maxAdu: 4095),
        closeTo(50, 0.05),
      );
    });

    // The percent<->ADU pair is the whole flat target, and the ADU it is
    // compared against (`FlatFrameCapture.adu` = `CapturedImageResult.stats.mean`)
    // is in PIXEL-CONTAINER units. This matrix pins the container scale for both
    // sensor conventions at every bit depth Skotiq supports, so a future
    // change cannot silently reintroduce an ADC-range divisor.
    test('percent<->ADU round-trips for shifted and unshifted sensors', () {
      // (bit depth, right-justified full scale, left-justified-into-16 full scale)
      const cases = <(int, int, int)>[
        (8, 255, 65280), // 255 << 8
        (10, 1023, 65472), // 1023 << 6
        (12, 4095, 65520), // 4095 << 4  — ASI1600MM class
        (14, 16383, 65532), // 16383 << 2 — ASI2600/6200 class
        (16, 65535, 65535), // no shift possible
      ];
      for (final (bitDepth, unshifted, shifted) in cases) {
        for (final scale in <int>[unshifted, shifted]) {
          for (final percent in <double>[1, 25, 50, 75, 99]) {
            final adu = FlatExposureCalculator.histogramPercentToAdu(
              percent,
              maxAdu: scale,
            );
            expect(
              adu,
              inInclusiveRange(0, scale),
              reason:
                  '$bitDepth-bit scale $scale: $percent% -> $adu must be reachable',
            );
            expect(
              FlatExposureCalculator.aduToHistogramPercent(adu, maxAdu: scale),
              closeTo(percent, 0.6),
              reason: '$bitDepth-bit scale $scale: $percent% must round-trip',
            );
          }
        }
      }
    });

    // The numbers measured on the rig: a live ASI1600MM at gain 0 / offset 0 /
    // 1 ms — the shortest exposure the driver accepts — already reads a mean of
    // ~4500 ADU. Targeting 50% of the ADC range (2048) is BELOW the camera's
    // floor, so the solver can only shorten the exposure, hits
    // `minExposureReached`, and the filter fails.
    test('ASI1600MM 50% target must exceed its shortest-exposure floor', () {
      const measuredFloorAduAtShortestExposure = 4500.8; // live, 2 ms, gain 0

      final adcRangeTarget = FlatExposureCalculator.histogramPercentToAdu(
        50,
        maxAdu: 4095, // what the old bit-depth cap produced
      );
      expect(adcRangeTarget, 2048);
      expect(
        adcRangeTarget,
        lessThan(measuredFloorAduAtShortestExposure),
        reason: 'documents the defect: the old target was unreachable',
      );

      final containerTarget = FlatExposureCalculator.histogramPercentToAdu(
        50,
        maxAdu: 65520, // 4095 << 4, what the driver now reports
      );
      expect(containerTarget, 32760);
      expect(
        containerTarget,
        greaterThan(measuredFloorAduAtShortestExposure),
        reason:
            'the corrected target sits above the bias floor, so it is '
            'reachable by lengthening the exposure',
      );
      // ...and still comfortably below the pipeline's saturation threshold.
      expect(containerTarget, lessThan(65024));
    });
  });

  group('gain / offset resolution', () {
    test('profile default wins over the live camera value', () async {
      final b = _CapBackend();
      stub(
        b,
        status: _status(gain: 50, offset: 5),
        caps: _caps(gainMin: 0, gainMax: 300, offsetMin: 0, offsetMax: 100),
      );
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
        profileDefaultGain: 120,
        profileDefaultOffset: 30,
        currentGain: 50,
        currentOffset: 5,
      );
      expect(cfg.gain, 120);
      expect(cfg.offset, 30);
    });

    test('falls back to the live connected value when no profile', () async {
      final b = _CapBackend();
      stub(b, status: _status(gain: 200, offset: 8), caps: _caps());
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
        currentGain: 77,
        currentOffset: 9,
      );
      expect(cfg.gain, 77);
      expect(cfg.offset, 9);
    });

    test(
      'unsupported gain/offset are NOT sent (null = camera default)',
      () async {
        final b = _CapBackend();
        stub(
          b,
          status: _status(canSetGain: false, canSetOffset: false),
          caps: _caps(canSetGain: false, canSetOffset: false),
        );
        final cfg = await FlatWizardService.resolveCaptureConfig(
          backend: b,
          deviceId: cam,
          profileDefaultGain: 100, // present, but camera can't set gain
          profileDefaultOffset: 20,
        );
        expect(cfg.gain, isNull);
        expect(cfg.offset, isNull);
        expect(cfg.canSetGain, isFalse);
        expect(cfg.canSetOffset, isFalse);
      },
    );

    test(
      'out-of-range gain/offset are clamped to the capability range',
      () async {
        final b = _CapBackend();
        stub(
          b,
          status: _status(),
          caps: _caps(gainMin: 0, gainMax: 100, offsetMin: 10, offsetMax: 50),
        );
        final high = await FlatWizardService.resolveCaptureConfig(
          backend: b,
          deviceId: cam,
          profileDefaultGain: 500,
          profileDefaultOffset: 999,
        );
        expect(high.gain, 100);
        expect(high.offset, 50);

        final low = await FlatWizardService.resolveCaptureConfig(
          backend: b,
          deviceId: cam,
          profileDefaultGain: -5,
          profileDefaultOffset: 0,
        );
        expect(low.gain, 0);
        expect(low.offset, 10);
      },
    );
  });

  group('binning resolution', () {
    test('honours profile binX/binY within the max-bin', () async {
      final b = _CapBackend();
      stub(
        b,
        status: _status(),
        caps: _caps(maxBinX: 4, maxBinY: 4, canAsymmetricBin: true),
      );
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
        profileBinX: 2,
        profileBinY: 3,
      );
      expect(cfg.binX, 2);
      expect(cfg.binY, 3);
    });

    test('clamps binning above the camera max-bin', () async {
      final b = _CapBackend();
      stub(
        b,
        status: _status(),
        caps: _caps(maxBinX: 2, maxBinY: 2, canAsymmetricBin: true),
      );
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
        profileBinX: 8,
        profileBinY: 8,
      );
      expect(cfg.binX, 2);
      expect(cfg.binY, 2);
    });

    test('forces symmetric binning when asymmetric is unsupported', () async {
      final b = _CapBackend();
      stub(
        b,
        status: _status(),
        caps: _caps(maxBinX: 4, maxBinY: 4, canAsymmetricBin: false),
      );
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
        profileBinX: 2,
        profileBinY: 1,
      );
      expect(cfg.binX, 2);
      expect(cfg.binY, 2, reason: 'binY coerced to binX for symmetric-only');
    });

    test('forces 1x1 when the camera cannot bin at all', () async {
      final b = _CapBackend();
      stub(b, status: _status(), caps: _caps(canBin: false, maxBinX: 4));
      final cfg = await FlatWizardService.resolveCaptureConfig(
        backend: b,
        deviceId: cam,
        profileBinX: 4,
        profileBinY: 4,
      );
      expect(cfg.binX, 1);
      expect(cfg.binY, 1);
    });
  });

  group('remote host authority', () {
    test(
      'capabilities come from the host and are marked authoritative',
      () async {
        final b = _RemoteCapBackend();
        when(
          () => b.getCameraStatus(cam),
        ).thenAnswer((_) async => _status(maxAdu: 16383, gain: 90));
        when(
          () => b.getCameraCapabilities(cam),
        ).thenAnswer((_) async => _caps(bitDepth: 14, gainMax: 200));
        final cfg = await FlatWizardService.resolveCaptureConfig(
          backend: b,
          deviceId: cam,
          currentGain: 90,
        );
        // Range + gain came from the host, not from any phone-side inference.
        expect(cfg.maxAdu, 16383);
        expect(cfg.gain, 90);
        expect(cfg.hostAuthoritative, isTrue);
        expect(cfg.capabilitiesKnown, isTrue);
      },
    );
  });
}
