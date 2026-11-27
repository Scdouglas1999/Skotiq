// Sky-brightness adaptive exposure validation tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/models/sequence/validation/rules/adaptive_exposure_rules.dart';

Sequence _sequenceWith(ExposureNode node) {
  // Minimal sequence shell wrapping one exposure node. The validators
  // we test here only read the nodes map, not the relationships, so the
  // shell can be empty otherwise.
  return Sequence.create(
    id: 'seq',
    name: 'test',
    nodes: {node.id: node},
    rootNodeId: node.id,
  );
}

ExposureNode _exp({
  String filter = 'L',
  double duration = 60.0,
  AdaptiveExposureConfig? adaptive,
}) {
  return ExposureNode(
    id: 'e1',
    name: 'Exposure',
    durationSecs: duration,
    count: 5,
    filter: filter,
    adaptiveExposure: adaptive,
  );
}

void main() {
  group('AdaptiveExposureBoundsRule', () {
    final rule = AdaptiveExposureBoundsRule();

    test('no override = clean', () {
      final issues = rule.validate(_sequenceWith(_exp()));
      expect(issues, isEmpty);
    });

    test('min > max fires error', () {
      const cfg = AdaptiveExposureConfig(
        minExposureSecs: 300,
        maxExposureSecs: 60,
      );
      final issues = rule.validate(_sequenceWith(_exp(adaptive: cfg)));
      expect(issues.length, 1);
      expect(issues.first.severity, ValidationSeverity.error);
      expect(issues.first.title, contains('inverted'));
    });

    test('min <= 0 fires error', () {
      const cfg = AdaptiveExposureConfig(minExposureSecs: 0);
      final issues = rule.validate(_sequenceWith(_exp(adaptive: cfg)));
      expect(
        issues.where((i) => i.title.contains('min must be > 0')),
        hasLength(1),
      );
    });

    test('max <= 0 fires error', () {
      const cfg = AdaptiveExposureConfig(maxExposureSecs: 0);
      final issues = rule.validate(_sequenceWith(_exp(adaptive: cfg)));
      expect(
        issues.where((i) => i.title.contains('max must be > 0')),
        hasLength(1),
      );
    });

    test('per-filter min > effective max fires error', () {
      const cfg = AdaptiveExposureConfig(
        minExposureSecs: 5,
        maxExposureSecs: 600,
        perFilterMinSecs: {'L': 700},
      );
      final issues = rule.validate(_sequenceWith(_exp(adaptive: cfg)));
      expect(
        issues.where((i) => i.title.contains('per-filter bounds inverted')),
        hasLength(1),
      );
    });
  });

  group('exposure values in the messages', () {
    test('sub-second bounds read as the exposure fields show them', () {
      const cfg = AdaptiveExposureConfig(
        minExposureSecs: 0.01,
        maxExposureSecs: 0.04,
        perFilterMinSecs: {'L': 0.06},
      );
      final issues = AdaptiveExposureBoundsRule().validate(
        _sequenceWith(_exp(adaptive: cfg)),
      );
      final inverted = issues.singleWhere(
        (i) => i.title.contains('per-filter bounds inverted'),
      );
      expect(inverted.description, contains('min 60 ms > effective max 40 ms'));
    });

    test('a nominal below the minimum names both values', () {
      const cfg = AdaptiveExposureConfig(
        minExposureSecs: 0.08,
        maxExposureSecs: 600,
      );
      final issues = AdaptiveExposureNominalOutOfBoundsRule().validate(
        _sequenceWith(_exp(adaptive: cfg, duration: 0.02)),
      );
      expect(issues.single.description, contains('duration 20 ms'));
      expect(issues.single.description, contains('is 80 ms.'));
    });
  });

  group('AdaptiveExposureNoFilterEnabledRule', () {
    final rule = AdaptiveExposureNoFilterEnabledRule();

    test('empty per-filter map = clean (implicit-global)', () {
      const cfg = AdaptiveExposureConfig();
      final issues = rule.validate(_sequenceWith(_exp(adaptive: cfg)));
      expect(issues, isEmpty);
    });

    test('disabled override = clean', () {
      const cfg = AdaptiveExposureConfig(
        enabled: false,
        perFilterEnabled: {'L': false, 'R': false},
      );
      final issues = rule.validate(_sequenceWith(_exp(adaptive: cfg)));
      expect(issues, isEmpty);
    });

    test('all-disabled per-filter map fires warning', () {
      const cfg = AdaptiveExposureConfig(
        enabled: true,
        perFilterEnabled: {'L': false, 'R': false, 'B': false},
      );
      final issues = rule.validate(_sequenceWith(_exp(adaptive: cfg)));
      expect(issues, hasLength(1));
      expect(issues.first.severity, ValidationSeverity.warning);
    });

    test('one filter enabled = clean', () {
      const cfg = AdaptiveExposureConfig(
        enabled: true,
        perFilterEnabled: {'L': true, 'R': false},
      );
      final issues = rule.validate(_sequenceWith(_exp(adaptive: cfg)));
      expect(issues, isEmpty);
    });
  });

  group('AdaptiveExposureNominalOutOfBoundsRule', () {
    final rule = AdaptiveExposureNominalOutOfBoundsRule();

    test('nominal inside bounds = clean', () {
      const cfg = AdaptiveExposureConfig(
        minExposureSecs: 10,
        maxExposureSecs: 600,
      );
      final issues = rule.validate(
        _sequenceWith(_exp(adaptive: cfg, duration: 60)),
      );
      expect(issues, isEmpty);
    });

    test('nominal below min fires warning', () {
      const cfg = AdaptiveExposureConfig(
        minExposureSecs: 100,
        maxExposureSecs: 600,
      );
      final issues = rule.validate(
        _sequenceWith(_exp(adaptive: cfg, duration: 60)),
      );
      expect(issues, hasLength(1));
      expect(issues.first.severity, ValidationSeverity.warning);
      expect(issues.first.title, contains('below'));
    });

    test('nominal above max fires warning', () {
      const cfg = AdaptiveExposureConfig(
        minExposureSecs: 5,
        maxExposureSecs: 60,
      );
      final issues = rule.validate(
        _sequenceWith(_exp(adaptive: cfg, duration: 600)),
      );
      expect(issues, hasLength(1));
      expect(issues.first.severity, ValidationSeverity.warning);
      expect(issues.first.title, contains('above'));
    });

    test('disabled config = clean', () {
      const cfg = AdaptiveExposureConfig(
        enabled: false,
        minExposureSecs: 100,
        maxExposureSecs: 600,
      );
      final issues = rule.validate(
        _sequenceWith(_exp(adaptive: cfg, duration: 60)),
      );
      expect(issues, isEmpty);
    });
  });
}
