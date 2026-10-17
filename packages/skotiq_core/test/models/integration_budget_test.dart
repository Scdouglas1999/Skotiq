// Per-target integration budget model tests.
//
// Pins the JSON shape one-to-one to the Rust side (see
// `native/skotiq_native/sequencer/src/lib.rs::IntegrationBudget`).
// If the Rust enum/struct ever changes, these tests must fail loudly so
// the Dart mirror stays in lock-step.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';

void main() {
  group('FilterBudgetEntry', () {
    test('Absolute JSON shape matches the Rust serde tag/content shape', () {
      const entry = FilterBudgetEntry.absolute(3600.0);
      final json = entry.toJson();
      expect(json, equals({'kind': 'Absolute', 'value': 3600.0}));
    });

    test('Ratio JSON shape matches the Rust serde tag/content shape', () {
      const entry = FilterBudgetEntry.ratio(4.0);
      final json = entry.toJson();
      expect(json, equals({'kind': 'Ratio', 'value': 4.0}));
    });

    test('round-trips through JSON', () {
      const a = FilterBudgetEntry.absolute(7200.0);
      const r = FilterBudgetEntry.ratio(2.5);
      final aJson = jsonEncode(a.toJson());
      final rJson = jsonEncode(r.toJson());
      expect(
        FilterBudgetEntry.fromJson(jsonDecode(aJson) as Map<String, dynamic>),
        equals(a),
      );
      expect(
        FilterBudgetEntry.fromJson(jsonDecode(rJson) as Map<String, dynamic>),
        equals(r),
      );
    });

    test('unknown kind throws FormatException', () {
      expect(
        () => FilterBudgetEntry.fromJson({'kind': 'Other', 'value': 1.0}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('IntegrationBudget.resolvedFilterCap', () {
    test('Absolute entries return their own value', () {
      const budget = IntegrationBudget(
        perFilter: {'Ha': FilterBudgetEntry.absolute(21600.0)},
      );
      expect(budget.resolvedFilterCap('Ha'), equals(21600.0));
      expect(budget.resolvedFilterCap('OIII'), isNull);
    });

    test('Ratios normalise against total — 4:1:1:1 LRGB / 8h example', () {
      const budget = IntegrationBudget(
        totalSecs: 28800.0,
        perFilter: {
          'L': FilterBudgetEntry.ratio(4.0),
          'R': FilterBudgetEntry.ratio(1.0),
          'G': FilterBudgetEntry.ratio(1.0),
          'B': FilterBudgetEntry.ratio(1.0),
        },
      );
      expect(
        (budget.resolvedFilterCap('L')! - (4.0 / 7.0) * 28800.0).abs(),
        lessThan(1.0),
      );
      expect(
        (budget.resolvedFilterCap('R')! - (1.0 / 7.0) * 28800.0).abs(),
        lessThan(1.0),
      );
    });

    test('Ratios without total yield null', () {
      const budget = IntegrationBudget(
        perFilter: {
          'L': FilterBudgetEntry.ratio(4.0),
          'R': FilterBudgetEntry.ratio(1.0),
        },
      );
      expect(budget.resolvedFilterCap('L'), isNull);
      expect(budget.resolvedFilterCap('R'), isNull);
    });

    test('Zero-value entries yield null', () {
      const budget = IntegrationBudget(
        totalSecs: 10000.0,
        perFilter: {
          'L': FilterBudgetEntry.ratio(0.0),
          'R': FilterBudgetEntry.absolute(0.0),
        },
      );
      expect(budget.resolvedFilterCap('L'), isNull);
      expect(budget.resolvedFilterCap('R'), isNull);
    });
  });

  group('IntegrationBudget JSON round-trip', () {
    test('round-trips through JSON byte-for-byte', () {
      const budget = IntegrationBudget(
        totalSecs: 28800.0,
        perFilter: {
          'L': FilterBudgetEntry.ratio(4.0),
          'R': FilterBudgetEntry.ratio(1.0),
          'Ha': FilterBudgetEntry.absolute(7200.0),
        },
        stopOnBudgetMet: false,
      );
      final json = jsonEncode(budget.toJson());
      final back = IntegrationBudget.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      expect(back, equals(budget));
    });

    test('default deserialization (missing fields) honours defaults', () {
      final budget = IntegrationBudget.fromJson(<String, dynamic>{});
      expect(budget.totalSecs, equals(0.0));
      expect(budget.perFilter, isEmpty);
      expect(budget.stopOnBudgetMet, isTrue);
    });

    test('isActive false for all-zero budget', () {
      const budget = IntegrationBudget();
      expect(budget.isActive, isFalse);
    });

    test('isActive true for any non-zero cap', () {
      const t = IntegrationBudget(totalSecs: 60.0);
      const a = IntegrationBudget(
        perFilter: {'L': FilterBudgetEntry.absolute(60.0)},
      );
      const r = IntegrationBudget(
        perFilter: {'L': FilterBudgetEntry.ratio(1.0)},
      );
      expect(t.isActive, isTrue);
      expect(a.isActive, isTrue);
      expect(r.isActive, isTrue);
    });
  });

  group('TargetHeaderNode copyWith integrationBudget keep-or-replace', () {
    test('omitting integrationBudget preserves the existing value', () {
      const original = IntegrationBudget(totalSecs: 3600.0);
      final node = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.5,
        decDegrees: 41.0,
        integrationBudget: original,
      );
      final copy = node.copyWith(targetName: 'M33');
      expect(copy.integrationBudget, equals(original));
    });

    test(
      'explicit null now KEEPS the budget (plain `?? this.X` semantics)',
      () {
        // TargetHeaderNode.copyWith carries no sentinel: null and omitted
        // are indistinguishable. Clearing the budget is rebuild-explicit at
        // the editor — see sequence_node_complex_subclasses_test.dart::
        // nullable_fields_cleared_via_rebuild_explicit for the recipe.
        const original = IntegrationBudget(totalSecs: 3600.0);
        final node = TargetHeaderNode(
          targetName: 'M31',
          raHours: 0.5,
          decDegrees: 41.0,
          integrationBudget: original,
        );
        final copy = node.copyWith(integrationBudget: null);
        expect(copy.integrationBudget, equals(original));
      },
    );

    test('explicit value replaces the budget', () {
      const original = IntegrationBudget(totalSecs: 3600.0);
      const replacement = IntegrationBudget(totalSecs: 7200.0);
      final node = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.5,
        decDegrees: 41.0,
        integrationBudget: original,
      );
      final copy = node.copyWith(integrationBudget: replacement);
      expect(copy.integrationBudget, equals(replacement));
    });
  });
}
