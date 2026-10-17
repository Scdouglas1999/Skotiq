// Dart-side parity tests for the variable catalog. The Rust
// catalog at `expressions/catalog.rs::variable_catalog` is the canonical
// source of truth; this test verifies that:
//
//   1. Every entry has a unique name.
//   2. Each entry's `placeholder` getter renders the correct `${...}` form.
//   3. `previewInterpolation` substitutes catalog examples without
//      throwing or returning the empty string for unknown variables.
//   4. Format specs (zero-pad, `.Nf`) apply to numeric examples.
//
// The Rust-Dart drift test (the catalog JSON dump compared against this
// list) lives in the Rust integration tests and is verified by CI.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('interpolationCatalog', () {
    test('variable names are unique', () {
      final names = interpolationCatalog.map((v) => v.name).toList();
      final unique = names.toSet();
      expect(
        unique.length,
        names.length,
        reason: 'duplicate variable names in catalog',
      );
    });

    test('placeholder is \${name}', () {
      for (final entry in interpolationCatalog) {
        expect(entry.placeholder, '\${${entry.name}}');
      }
    });

    test('every group has at least one entry', () {
      final groups = interpolationCatalog.map((v) => v.group).toSet();
      for (final g in InterpolationVariableGroup.values) {
        expect(
          groups,
          contains(g),
          reason: 'group ${g.name} has no catalog entries',
        );
      }
    });
  });

  group('previewInterpolation', () {
    test('substitutes a single variable with its example', () {
      final result = previewInterpolation(r'Target ${target.name}');
      expect(result, 'Target M42');
    });

    test('substitutes multiple variables', () {
      final result = previewInterpolation(
        r'${target.name} on ${filter} (frame ${frame})',
      );
      expect(result, 'M42 on Ha (frame 8)');
    });

    test('applies integer zero-pad spec to numeric example', () {
      // frame example is "8" → zero-pad to width 4 → "0008".
      final result = previewInterpolation(r'sub_${frame:04}.fits');
      expect(result, 'sub_0008.fits');
    });

    test('applies fixed-point spec to float example', () {
      // target.alt example is "42.7" → `.1f` keeps one decimal.
      final result = previewInterpolation(r'alt ${target.alt:.1f}');
      expect(result, 'alt 42.7');
    });

    test('renders save-path template with hierarchical directories', () {
      final result = previewInterpolation(
        r'${session.date}/${target.name}/${filter}/sub_${frame:04}.fits',
      );
      expect(result, '2026-01-15/M42/Ha/sub_0008.fits');
    });

    test('renders notification template', () {
      // exposure.total example is "30" → :.1f → "30.0".
      final result = previewInterpolation(
        r'${target.name} done. ${frame} frames at ${exposure.duration}s = ${exposure.total:.1f}m total.',
      );
      expect(result, 'M42 done. 8 frames at 180s = 30.0m total.');
    });

    test('marks unknown variables with `?` suffix', () {
      final result = previewInterpolation(r'${target.naem}');
      expect(result, '\${target.naem?}');
    });

    test(r'preserves literal $${...} via doubled dollar escape', () {
      final result = previewInterpolation(r'price $${100}');
      expect(result, r'price ${100}');
    });

    test('passes through plain text unchanged', () {
      const original = 'plain literal — no placeholders here';
      expect(previewInterpolation(original), original);
    });
  });
}
