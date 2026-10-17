import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// The remote First Light feed reconstructs `TransientDetectionRow`s from the
/// appliance's `/api/firstlight/candidates` wire JSON. This pins that the
/// reconstruction is a faithful round-trip of the shape
/// `FirstLightHandlers._rowToWireJson` emits, so the remote discovery surface
/// renders identically to the local DB-watched one.
void main() {
  group('transientDetectionFromWireJson', () {
    Map<String, dynamic> wire({
      double? deltaMag,
      String? catalogMatch,
      int? sessionId,
      bool reviewed = false,
      bool dismissed = false,
    }) => {
      'id': 12,
      'sessionId': sessionId,
      'capturedImageId': 34,
      'tileId': 42,
      'detectedAt': DateTime.utc(2026, 6, 19, 22, 30).millisecondsSinceEpoch,
      'raDeg': 120.5,
      'decDeg': -25.25,
      'residualFlux': 1500.0,
      'deltaMag': deltaMag,
      'snr': 18.3,
      'fwhm': 2.1,
      'eccentricity': 0.12,
      'positionAngleDeg': 63.5,
      'kind': 'newSource',
      'catalogMatch': catalogMatch,
      'confidence': 0.81,
      'reviewed': reviewed,
      'dismissed': dismissed,
    };

    test('reconstructs every column of an unnamed new-source detection', () {
      final row = transientDetectionFromWireJson(wire());

      expect(row.id, 12);
      expect(row.sessionId, isNull);
      expect(row.capturedImageId, 34);
      expect(row.tileId, 42);
      expect(row.detectedAt.toUtc(), DateTime.utc(2026, 6, 19, 22, 30));
      expect(row.raDeg, 120.5);
      expect(row.decDeg, -25.25);
      expect(row.residualFlux, 1500.0);
      expect(row.deltaMag, isNull);
      expect(row.snr, 18.3);
      expect(row.fwhm, 2.1);
      expect(row.eccentricity, 0.12);
      expect(row.positionAngleDeg, 63.5);
      expect(row.kind, 'newSource');
      expect(row.catalogMatch, isNull);
      expect(row.confidence, 0.81);
      expect(row.reviewed, isFalse);
      expect(row.dismissed, isFalse);
    });

    test('carries deltaMag, catalog name, session, and triage flags', () {
      final row = transientDetectionFromWireJson(
        wire(
          deltaMag: -0.42,
          catalogMatch: 'Star V=12.3',
          sessionId: 7,
          reviewed: true,
          dismissed: true,
        ),
      );

      expect(row.deltaMag, -0.42);
      expect(row.catalogMatch, 'Star V=12.3');
      expect(row.sessionId, 7);
      expect(row.reviewed, isTrue);
      expect(row.dismissed, isTrue);
    });

    test('integer JSON numbers decode to double fields', () {
      final json = wire()
        ..['raDeg'] = 120
        ..['snr'] = 18
        ..['confidence'] = 1;
      final row = transientDetectionFromWireJson(json);

      expect(row.raDeg, 120.0);
      expect(row.snr, 18.0);
      expect(row.confidence, 1.0);
    });

    test('absent positionAngleDeg defaults to 0 (pre-fit rows)', () {
      final json = wire()..remove('positionAngleDeg');
      expect(transientDetectionFromWireJson(json).positionAngleDeg, 0.0);
    });
  });
}
