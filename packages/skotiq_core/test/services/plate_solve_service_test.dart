import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// These tests pin the unit contract for every local-fallback solve parser:
/// `PlateSolveResult.ra` is in DEGREES, matching the dominant FFI/network
/// host path (Rust `PlateSolveResult.ra` reads FITS `CRVAL1` verbatim — see
/// `native/.../bridge/src/api/plate_solve.rs`). The previous parsers divided
/// CRVAL1 by 15 and returned hours, a latent 15x inconsistency that fed the
/// wrong-unit RA into the centering pipeline (which assumes degrees).
void main() {
  late ProviderContainer container;
  late PlateSolveService service;

  setUp(() {
    container = ProviderContainer();
    service = container.read(plateSolveServiceProvider);
  });

  tearDown(() {
    container.dispose();
  });

  group('RA unit contract — all parsers return degrees', () {
    test('_parseWcsFile returns RA in degrees (CRVAL1 verbatim)', () async {
      // CRVAL1 = 187.7 deg (≈ 12.513h). If the parser still divided by 15 we
      // would see ~12.513 here instead of 187.7.
      const crval1Deg = 187.7;
      const crval2Deg = 12.39;
      final tmp = await Directory.systemTemp.createTemp('sk_wcs_test');
      addTearDown(() => tmp.delete(recursive: true));
      final wcs = File('${tmp.path}/frame.wcs');
      await wcs.writeAsString(
        'CRVAL1  =       $crval1Deg / RA of reference point\n'
        'CRVAL2  =        $crval2Deg / Dec of reference point\n'
        'CDELT1  =   -0.000416667 / deg/pixel\n'
        'CDELT2  =    0.000416667 / deg/pixel\n'
        'CROTA2  =           1.25 / rotation\n',
      );

      final result = await service.parseWcsFileForTest(wcs.path);

      expect(result.success, isTrue);
      expect(
        result.ra,
        closeTo(crval1Deg, 1e-9),
        reason: 'RA must be in degrees, not hours (187.7 not 12.513)',
      );
      expect(result.dec, closeTo(crval2Deg, 1e-9));
      // CDELT1 (deg/px) -> arcsec/px
      expect(result.pixelScale, closeTo(0.000416667 * 3600, 1e-6));
      expect(result.rotation, closeTo(1.25, 1e-9));
    });

    test('_parseAstrometryOutput returns RA in degrees', () {
      const raDeg = 187.7;
      const decDeg = 12.39;
      const output =
          'Field center: (RA,Dec) = ($raDeg, $decDeg) deg.\n'
          'RA,Dec = ($raDeg,$decDeg), pixel scale 1.23 arcsec/pix.\n';

      final result = service.parseAstrometryOutputForTest(output);

      expect(result.success, isTrue);
      expect(
        result.ra,
        closeTo(raDeg, 1e-9),
        reason: 'RA must be in degrees, not hours',
      );
      expect(result.dec, closeTo(decDeg, 1e-9));
    });
  });

  group('.wcs is a raw FITS header, not a text file', () {
    /// A real ASTAP `.wcs` is fixed-width 80-character cards packed end to end
    /// with **no line terminators at all**. Splitting it on newlines yields the
    /// whole header as one enormous "line", so only `SIMPLE` is ever inspected
    /// and `CRVAL1` is invisible: ASTAP solves, the parse reports the solution
    /// as missing, and the caller counts a successful solve as a failed one.
    /// `native/.../imaging/src/platesolve.rs` already carries this fix; this
    /// pins the Dart fallback to the same contract.
    String card(String content) => content.padRight(80).substring(0, 80);

    test('_parseWcsFile reads a terminator-free ASTAP header', () async {
      final tmp = await Directory.systemTemp.createTemp('sk_wcs_cards');
      addTearDown(() => tmp.delete(recursive: true));
      final wcs = File('${tmp.path}/frame.wcs');
      await wcs.writeAsString(
        <String>[
          card('SIMPLE  =                    T / FITS standard'),
          card('BITPIX  =                   16 /'),
          card('NAXIS   =                    2 /'),
          card('NAXIS1  =                 4144 /'),
          card('NAXIS2  =                 2822 /'),
          card('CRPIX1  =               2072.0 /'),
          card('CRPIX2  =               1411.0 /'),
          card('CRVAL1  =    187.7000000000000 / RA of reference pixel [deg]'),
          card('CRVAL2  =     12.3900000000000 / Dec of reference pixel [deg]'),
          card('CDELT1  =  -4.1666700000E-0004 / deg/pixel'),
          card('CDELT2  =   4.1666700000E-0004 / deg/pixel'),
          card('CROTA2  =      1.2500000000000 / rotation [deg]'),
          card('END'),
        ].join(),
      );

      final result = await service.parseWcsFileForTest(wcs.path);

      expect(
        result.success,
        isTrue,
        reason: 'ASTAP writes no newlines; the header must be card-split',
      );
      expect(result.ra, closeTo(187.7, 1e-9));
      expect(result.dec, closeTo(12.39, 1e-9));
      expect(result.pixelScale, closeTo(4.16667e-4 * 3600, 1e-6));
      expect(result.rotation, closeTo(1.25, 1e-9));
    });

    test('_parseWcsFile still reads a newline-delimited header', () async {
      final tmp = await Directory.systemTemp.createTemp('sk_wcs_lines');
      addTearDown(() => tmp.delete(recursive: true));
      final wcs = File('${tmp.path}/frame.wcs');
      await wcs.writeAsString(
        <String>[
          card('CRVAL1  =    187.7000000000000 / RA'),
          card('CRVAL2  =     12.3900000000000 / Dec'),
        ].join('\r\n'),
      );

      final result = await service.parseWcsFileForTest(wcs.path);

      expect(result.success, isTrue);
      expect(result.ra, closeTo(187.7, 1e-9));
      expect(result.dec, closeTo(12.39, 1e-9));
    });
  });

  group('parser failure paths fail closed (no silent success)', () {
    test('_parseWcsFile fails loud when CRVAL keywords are absent', () async {
      final tmp = await Directory.systemTemp.createTemp('sk_wcs_bad');
      addTearDown(() => tmp.delete(recursive: true));
      final wcs = File('${tmp.path}/frame.wcs');
      await wcs.writeAsString('COMMENT no coordinates here\n');

      final result = await service.parseWcsFileForTest(wcs.path);

      expect(result.success, isFalse);
      expect(result.ra, 0);
      expect(result.error, isNotNull);
    });

    test('_parseAstrometryOutput fails loud on unparseable output', () {
      final result = service.parseAstrometryOutputForTest(
        'no solution in this text',
      );

      expect(result.success, isFalse);
      expect(result.error, isNotNull);
    });
  });

  group('every result carries the full 25-field shape', () {
    /// The result contract: a failure is zeroed astrometry plus a reason, and
    /// a success from a local fallback parser leaves the CD matrix and SIP
    /// terms empty (only the native solver recovers those). No path may leave
    /// a field half-populated.
    void expectAstrometryUnset(PlateSolveResult result) {
      expect(result.cd11, 0);
      expect(result.cd12, 0);
      expect(result.cd21, 0);
      expect(result.cd22, 0);
      expect(result.fieldWidth, 0);
      expect(result.fieldHeight, 0);
      expect(result.solveTimeSecs, 0);
      expect(result.sipAOrder, 0);
      expect(result.sipBOrder, 0);
      expect(result.sipApOrder, 0);
      expect(result.sipBpOrder, 0);
      expect(result.sipACoeffs, isEmpty);
      expect(result.sipBCoeffs, isEmpty);
      expect(result.sipApCoeffs, isEmpty);
      expect(result.sipBpCoeffs, isEmpty);
    }

    test('a failure result is fully zeroed and names its reason', () async {
      final tmp = await Directory.systemTemp.createTemp('sk_wcs_shape');
      addTearDown(() => tmp.delete(recursive: true));
      final wcs = File('${tmp.path}/frame.wcs');
      await wcs.writeAsString('COMMENT nothing solvable here\n');

      final result = await service.parseWcsFileForTest(wcs.path);

      expect(result.success, isFalse);
      expect(result.error, isNotNull);
      expect(result.ra, 0);
      expect(result.dec, 0);
      expect(result.pixelScale, 0);
      expect(result.rotation, 0);
      expectAstrometryUnset(result);
    });

    test('a local-parser success carries position but no CD/SIP', () {
      final result = service.parseAstrometryOutputForTest(
        'RA,Dec = (187.7,12.39), pixel scale 1.23 arcsec/pix.\n',
      );

      expect(result.success, isTrue);
      expect(result.error, isNull);
      expect(result.ra, closeTo(187.7, 1e-9));
      expect(result.dec, closeTo(12.39, 1e-9));
      expectAstrometryUnset(result);
    });
  });
}
