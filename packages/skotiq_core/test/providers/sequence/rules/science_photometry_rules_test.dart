// Science — SciencePhotometry validation + serialization tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/providers/sequence/rules/science_photometry_rules.dart';

Sequence _sequenceWith(SciencePhotometryNode node) {
  return Sequence.create(
    id: 'seq',
    name: 'test',
    nodes: {node.id: node},
    rootNodeId: node.id,
  );
}

SciencePhotometryNode _node({
  String target = 'V0376 Per',
  String filter = 'Clear',
  List<String> refs = const ['ref-1', 'ref-2', 'ref-3'],
  double cadence = 2.0,
  double exposure = 60.0,
  int count = 60,
  bool applyDifferential = true,
  BinningMode binning = BinningMode.one,
}) {
  return SciencePhotometryNode(
    id: 'photometry-1',
    name: 'Photometry',
    targetDesignation: target,
    referenceStars: refs,
    maxCadenceGapSecs: cadence,
    filter: filter,
    exposureSecs: exposure,
    count: count,
    applyDifferential: applyDifferential,
    binning: binning,
  );
}

void main() {
  group('SciencePhotometryNode model', () {
    test('isPhotometricFilter accepts standard bands', () {
      expect(isPhotometricFilterBand('V'), isTrue);
      expect(isPhotometricFilterBand('B'), isTrue);
      expect(isPhotometricFilterBand('g'), isTrue);
      expect(isPhotometricFilterBand('Clear'), isTrue);
      expect(isPhotometricFilterBand('CV'), isTrue);
      expect(isPhotometricFilterBand('Ha'), isFalse);
      expect(isPhotometricFilterBand('Lum'), isFalse);
      expect(isPhotometricFilterBand(''), isFalse);
    });

    test('hasImpossibleCadence flags only negative gaps', () {
      // max_cadence_gap_secs is the inter-frame *extra* settle time
      // (gap = next_start - prev_start - exposure). Any non-negative
      // value is structurally valid; a negative value is the only
      // impossible case.
      expect(_node(cadence: -1.0, exposure: 60.0).hasImpossibleCadence, isTrue);
      expect(_node(cadence: 2.0, exposure: 60.0).hasImpossibleCadence, isFalse);
      expect(_node(cadence: 0.0, exposure: 60.0).hasImpossibleCadence, isFalse);
    });

    test('toRustConfigJson round-trips through fromRustConfigJson', () {
      final original = _node(
        target: 'KIC-9832227',
        filter: 'V',
        refs: ['ref-a', 'ref-b'],
        cadence: 5.0,
        exposure: 120.0,
        count: 30,
      );
      final json = original.toRustConfigJson();
      // Wire shape sanity checks — must match the Rust deserializer.
      expect(json['target_designation'], 'KIC-9832227');
      expect(json['reference_stars'], ['ref-a', 'ref-b']);
      expect(json['max_cadence_gap_secs'], 5.0);
      expect(json['filter'], 'V');
      expect(json['exposure_secs'], 120.0);
      expect(json['count'], 30);
      expect(json['binning'], 'One');
      expect(json['quality'], isA<Map<String, dynamic>>());

      final restored = SciencePhotometryNode.fromRustConfigJson(json);
      expect(restored.targetDesignation, original.targetDesignation);
      expect(restored.referenceStars, original.referenceStars);
      expect(restored.maxCadenceGapSecs, original.maxCadenceGapSecs);
      expect(restored.filter, original.filter);
      expect(restored.exposureSecs, original.exposureSecs);
      expect(restored.count, original.count);
      expect(restored.applyDifferential, original.applyDifferential);
      expect(restored.quality.minSnr, original.quality.minSnr);
    });
  });

  group('SciencePhotometryFilterRule', () {
    final rule = SciencePhotometryFilterRule();

    test('photometric filter = clean', () {
      expect(rule.validate(_sequenceWith(_node(filter: 'V'))), isEmpty);
      expect(rule.validate(_sequenceWith(_node(filter: 'Clear'))), isEmpty);
    });

    test('non-photometric filter fires warning', () {
      final issues = rule.validate(_sequenceWith(_node(filter: 'Ha')));
      expect(issues, isNotEmpty);
      expect(issues.first.severity, ValidationSeverity.warning);
      expect(issues.first.title, contains('non-photometric'));
    });

    test('binning > 1 fires warning', () {
      final issues = rule.validate(
        _sequenceWith(_node(binning: BinningMode.two)),
      );
      expect(issues.where((i) => i.title.contains('binning')), hasLength(1));
    });
  });

  group('SciencePhotometryReferenceStarsEmptyRule', () {
    final rule = SciencePhotometryReferenceStarsEmptyRule();

    test('differential with refs = clean', () {
      expect(
        rule.validate(_sequenceWith(_node(applyDifferential: true))),
        isEmpty,
      );
    });

    test('differential without refs fires error', () {
      final node = _node(applyDifferential: true, refs: const []);
      final issues = rule.validate(_sequenceWith(node));
      expect(
        issues.where((i) => i.title.contains('reference stars')),
        hasLength(1),
      );
      expect(
        issues.firstWhere((i) => i.title.contains('reference stars')).severity,
        ValidationSeverity.error,
      );
    });

    test('apply_differential off with no refs = clean', () {
      final node = _node(applyDifferential: false, refs: const []);
      // The empty-target rule still fires if target is empty; here
      // target is set, so no issues.
      expect(rule.validate(_sequenceWith(node)), isEmpty);
    });

    test('empty target designation fires error', () {
      final node = _node(target: '');
      final issues = rule.validate(_sequenceWith(node));
      expect(
        issues.where((i) => i.title.contains('target designation')),
        hasLength(1),
      );
    });
  });

  group('SciencePhotometryCadenceRule', () {
    final rule = SciencePhotometryCadenceRule();

    test('typical cadence = clean', () {
      expect(
        rule.validate(_sequenceWith(_node(cadence: 2.0, exposure: 60.0))),
        isEmpty,
      );
    });

    test('negative cadence fires error', () {
      final issues = rule.validate(
        _sequenceWith(_node(cadence: -5.0, exposure: 60.0)),
      );
      expect(issues.where((i) => i.title.contains('cadence')), hasLength(1));
      expect(
        issues.firstWhere((i) => i.title.contains('cadence')).severity,
        ValidationSeverity.error,
      );
    });

    test('zero exposure fires error', () {
      final issues = rule.validate(_sequenceWith(_node(exposure: 0.0)));
      expect(
        issues.where((i) => i.title.contains('exposure duration')),
        hasLength(1),
      );
    });
  });

  group('TransparencyBackupPlan', () {
    test('isEmpty when both filter and target null', () {
      const empty = TransparencyBackupPlan();
      expect(empty.isEmpty, isTrue);
    });

    test('not empty when filter set', () {
      const plan = TransparencyBackupPlan(backupFilter: 'Lum');
      expect(plan.isEmpty, isFalse);
    });

    test('round-trips through JSON', () {
      const plan = TransparencyBackupPlan(
        backupFilter: 'Lum',
        backupTargetId: 'm42-bright-backup',
        description: 'Bright Moon Backup',
      );
      final json = plan.toJson();
      final restored = TransparencyBackupPlan.fromJson(json);
      expect(restored.backupFilter, plan.backupFilter);
      expect(restored.backupTargetId, plan.backupTargetId);
      expect(restored.description, plan.description);
    });
  });

  group('TriggerType.transparencyDropped', () {
    test('RecoveryNode emits TransparencyDropped tagged config', () {
      final node = RecoveryNode(
        id: 'rec-1',
        name: 'Recovery',
        triggerType: TriggerType.transparencyDropped,
        transparencyBelowThreshold: 0.65,
        transparencyDurationSecs: 90.0,
        recoveryAction: RecoveryActionType.switchTargetOrFilter,
      );
      final cfg = node.toRustTriggerConfig();
      expect(cfg, isA<Map<String, dynamic>>());
      final map = cfg as Map<String, dynamic>;
      expect(map.containsKey('TransparencyDropped'), isTrue);
      final inner = map['TransparencyDropped'] as Map<String, dynamic>;
      expect(inner['below_threshold'], 0.65);
      expect(inner['duration_secs'], 90.0);
    });
  });
}
