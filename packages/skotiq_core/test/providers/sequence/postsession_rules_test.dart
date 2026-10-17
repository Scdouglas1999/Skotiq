import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/preflight_providers.dart';
import 'package:skotiq_core/src/providers/sequence/rules/postsession_rules.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';
import 'package:skotiq_core/src/services/optical_train_diagnostics_service.dart';

OpticalTrainBaseline _baseline(double tilt, double coll) {
  return OpticalTrainBaseline(
    tiltScore: tilt,
    collimationScore: coll,
    capturedAt: DateTime(2026, 1, 1),
  );
}

OpticalTrainDiagnostics _diag(double tilt, double coll) {
  return OpticalTrainDiagnostics(
    tiltScore: tilt,
    collimationScore: coll,
    dominantTiltDirection: 'unknown',
    issues: const [],
  );
}

void main() {
  group('postSessionOpticalTrainDrift', () {
    test('reports drift when above threshold', () {
      final issues = postSessionOpticalTrainDrift(
        preSession: _baseline(5.0, 5.0),
        postSession: _diag(25.0, 5.0),
        threshold: 5.0,
      );
      expect(issues, hasLength(1));
      expect(issues.first.title, 'Optical Train Drifted During Session');
      expect(issues.first.severity, ValidationSeverity.info);
    });

    test('reports steady-state when below threshold', () {
      final issues = postSessionOpticalTrainDrift(
        preSession: _baseline(5.0, 5.0),
        postSession: _diag(6.0, 6.0),
        threshold: 50.0,
      );
      expect(issues.first.title, 'Optical Train Held Steady');
      expect(issues.first.severity, ValidationSeverity.info);
    });

    test('empty when either snapshot is missing', () {
      expect(
        postSessionOpticalTrainDrift(
          preSession: null,
          postSession: _diag(5, 5),
          threshold: 5,
        ),
        isEmpty,
      );
      expect(
        postSessionOpticalTrainDrift(
          preSession: _baseline(5, 5),
          postSession: null,
          threshold: 5,
        ),
        isEmpty,
      );
    });
  });

  group('postSessionEquipmentHealthSummary', () {
    test('renders disconnect/cooler/focuser/sky-brightness lines', () {
      final issues = postSessionEquipmentHealthSummary(
        const PostSessionHealthSummary(
          disconnectsDuringSession: 47,
          coolerOutOfBandSamples: 4,
          focuserMoves: 12,
          skyBrightnessMin: 19.0,
          skyBrightnessMax: 21.4,
          skyBrightnessMedian: 20.4,
          noticedConcerns: ['HFR trending up slowly'],
        ),
      );
      expect(issues, hasLength(5));
      expect(
        issues.any((i) => i.title == 'USB Disconnects During Session'),
        isTrue,
      );
      expect(
        issues.any((i) => i.title == 'Cooler Out of Setpoint Band'),
        isTrue,
      );
      expect(issues.any((i) => i.title == 'Focuser Activity'), isTrue);
      expect(issues.any((i) => i.title == 'Sky Brightness Range'), isTrue);
      expect(issues.any((i) => i.title == 'Noticed but Did Not Fire'), isTrue);
    });

    test('omits sections that are zero / empty', () {
      final issues = postSessionEquipmentHealthSummary(
        const PostSessionHealthSummary(),
      );
      expect(issues, isEmpty);
    });
  });

  group('PostSessionDiagnostics.build', () {
    test('combines optical-train and equipment-health entries', () {
      final diag = PostSessionDiagnostics.build(
        preSession: _baseline(5, 5),
        postSession: _diag(25, 5),
        healthSummary: const PostSessionHealthSummary(
          disconnectsDuringSession: 3,
        ),
        opticalTrainDriftThreshold: 5,
      );
      expect(diag.opticalTrain, hasLength(1));
      expect(diag.equipmentHealth, hasLength(1));
      expect(diag.isNotEmpty, isTrue);
      expect(diag.all, hasLength(2));
    });

    test('reports empty when nothing is interesting', () {
      final diag = PostSessionDiagnostics.build(
        preSession: null,
        postSession: null,
        healthSummary: const PostSessionHealthSummary(),
        opticalTrainDriftThreshold: 5,
      );
      expect(diag.isEmpty, isTrue);
    });
  });
}
