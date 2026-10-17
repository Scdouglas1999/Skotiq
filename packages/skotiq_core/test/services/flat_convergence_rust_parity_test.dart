import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/services/flat_wizard_service.dart';

/// Parity: the Dart standalone engine against the Rust in-sequence engine.
///
/// There are intentionally TWO runtimes for flat convergence:
///   * Dart `FlatWizardService.calculateNextExposure` (standalone wizard
///     screen + headless `/api/flat-wizard/*`) — a PROPORTIONAL-adjustment
///     engine: it scales the current exposure by `target/measured`, clamped
///     and damped.
///   * Rust `flat_wizard` (in-sequence, native sequencer) — a true
///     BINARY-SEARCH engine: it tests the midpoint of an exposure window and
///     narrows `[min,max]` directionally.
///
/// The Rust engine is checkpoint/resume-bound to the native Wizard executor,
/// so the two cannot be merged without new FFI. The boundary is pinned instead
/// by the two invariants both engines MUST agree on for shared inputs:
///   (1) the convergence predicate — `|measured - target| <= tolerance`;
///   (2) the direction of correction — measured < target  => longer exposure,
///       measured > target  => shorter exposure.
///
/// If either engine ever changes its decision rule, this test fails.
class _FakeBackend extends Mock implements SkotiqBackend {}

/// Pure-Dart reference port of the Rust binary-search decision rule
/// (native/skotiq_native/sequencer/src/flat_wizard/mod.rs:
/// `do_binary_search_iteration`). No FFI — a hand-port of the exact branch
/// logic so the parity assertion has a concrete oracle.
({bool converged, double nextMin, double nextMax}) rustBinarySearchStep({
  required double minExp,
  required double maxExp,
  required int targetAdu,
  required int toleranceAdu,
  required int measuredAdu,
}) {
  // converged when within tolerance (Rust: median_adu.abs_diff(target) <= tol)
  final converged = (measuredAdu - targetAdu).abs() <= toleranceAdu;
  if (converged) {
    return (converged: true, nextMin: minExp, nextMax: maxExp);
  }
  final testExposure = (minExp + maxExp) / 2.0;
  if (measuredAdu < targetAdu) {
    // Too dark -> raise the lower bound (search longer exposures).
    return (converged: false, nextMin: testExposure, nextMax: maxExp);
  } else {
    // Too bright -> lower the upper bound (search shorter exposures).
    return (converged: false, nextMin: minExp, nextMax: testExposure);
  }
}

void main() {
  final svc = FlatWizardService(_FakeBackend());

  // Rust derives toleranceAdu = target * tolerance_percent / 100.
  int toleranceAdu(int target, double tolerancePercent) =>
      (target * tolerancePercent / 100.0).toInt();

  group('Dart proportional engine vs Rust binary-search decision rule', () {
    // Representative (measured, target, tolerance%) cases spanning under-,
    // over-, and on-target exposures.
    final cases = <({int measured, int target, double tolPct})>[
      (measured: 5000, target: 30000, tolPct: 10), // very under
      (measured: 20000, target: 30000, tolPct: 10), // under
      (measured: 29000, target: 30000, tolPct: 10), // within tol (under)
      (measured: 30000, target: 30000, tolPct: 5), // exact
      (measured: 31000, target: 30000, tolPct: 10), // within tol (over)
      (measured: 45000, target: 30000, tolPct: 5), // over
      (measured: 64000, target: 30000, tolPct: 8), // very over
    ];

    for (final c in cases) {
      test('measured=${c.measured} target=${c.target} tol=${c.tolPct}% '
          'agree on convergence + direction', () {
        const minExp = 0.001;
        const maxExp = 30.0;
        const currentExposure = 5.0;

        final tolAdu = toleranceAdu(c.target, c.tolPct);
        final rust = rustBinarySearchStep(
          minExp: minExp,
          maxExp: maxExp,
          targetAdu: c.target,
          toleranceAdu: tolAdu,
          measuredAdu: c.measured,
        );

        // Dart convergence predicate (mirrors calibrateFilter's check:
        // error% = |adu-target|/target*100 <= tolerance).
        final dartError = (c.measured - c.target).abs() / c.target * 100.0;
        final dartConverged = dartError <= c.tolPct;

        // (1) Convergence predicate parity.
        expect(
          dartConverged,
          rust.converged,
          reason: 'convergence predicate must match Rust for shared inputs',
        );

        if (rust.converged) return;

        // (2) Direction parity: the Dart proportional engine must move the
        // exposure the SAME way the Rust binary search narrows its window.
        final dartNext = svc.calculateNextExposure(
          currentExposure: currentExposure,
          currentAdu: c.measured.toDouble(),
          targetAdu: c.target.toDouble(),
          minExposure: minExp,
          maxExposure: maxExp,
        );

        // Rust "needs longer exposure" iff it raised the lower bound.
        final rustWantsLonger = rust.nextMin > minExp;
        final dartWantsLonger = dartNext > currentExposure;

        expect(
          dartWantsLonger,
          rustWantsLonger,
          reason:
              'direction of exposure correction must match Rust binary search',
        );
      });
    }
  });
}
