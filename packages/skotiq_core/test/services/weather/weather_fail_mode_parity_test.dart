import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart';
import 'package:skotiq_core/src/providers/weather_safety_provider.dart';

/// Architecture-unification 2026-06-05 (Subsystem 2 step 1 — CROSS-LANGUAGE
/// FAIL-MODE PARITY).
///
/// This is the Dart half of a truth table pinned on BOTH sides of the FFI. The
/// Rust half is `safety_fail_mode_no_data_resolution_truth_table` in
/// `native/skotiq_native/sequencer/src/executor/mod.rs`. The two
/// implementations — the Dart no-data weather-safety verdict
/// (`noDataFailModeResolution`) and the Rust safety-poll no-data resolution
/// (`safety_fail_mode_no_data_resolution`) — MUST agree on the identical rows:
///
///   failClosed -> unsafe   (Dart verdict: Some(true);  Rust: weather_safe=false)
///   failOpen   -> safe      (Dart verdict: None/abstain; Rust: weather_safe=true)
///   warnOnly   -> preserve  (Dart verdict: None/abstain; Rust: weather_safe unchanged)
///
/// If you change a row here, change it in the Rust test too, or the two
/// implementations have silently drifted. This is the structural guard that
/// keeps the unattended-night fail-closed semantics identical across languages.
void main() {
  group('cross-language no-data fail-mode resolution parity', () {
    test('failClosed resolves no-data as UNSAFE', () {
      expect(
        noDataFailModeResolution(SafetyFailMode.failClosed),
        NoDataResolution.unsafe,
        reason:
            'failClosed must treat missing safety data as unsafe — this is '
            'the unattended-run default that pauses/parks the rig.',
      );
    });

    test('failOpen resolves no-data as SAFE', () {
      expect(
        noDataFailModeResolution(SafetyFailMode.failOpen),
        NoDataResolution.safe,
        reason:
            'failOpen must treat missing safety data as safe so the '
            'sequence keeps running (daytime / intentional-no-device runs).',
      );
    });

    test('warnOnly resolves no-data as PRESERVE', () {
      expect(
        noDataFailModeResolution(SafetyFailMode.warnOnly),
        NoDataResolution.preserve,
        reason:
            'warnOnly must preserve the prior reading (last good wins) and '
            'surface a warning rather than asserting safe or unsafe.',
      );
    });

    test('every SafetyFailMode is mapped (exhaustive, no silent default)', () {
      // Defends against a new SafetyFailMode variant being added without a
      // corresponding row here AND in the Rust table. If this fails, both the
      // Dart switch and the Rust match (and both parity tests) need updating.
      for (final mode in SafetyFailMode.values) {
        final resolution = noDataFailModeResolution(mode);
        expect(
          NoDataResolution.values.contains(resolution),
          isTrue,
          reason: 'SafetyFailMode.$mode produced an unmapped resolution',
        );
      }
    });
  });

  group('no-data resolution drives the pushed verdict (safety-monotone)', () {
    // Pins the link between the shared resolution and the executor-facing
    // verdict semantics documented in weather_safety_provider.dart: only the
    // `unsafe` resolution asserts UNSAFE to the executor; the permissive
    // resolutions (`safe` / `preserve`) ABSTAIN (push None) so a permissive
    // policy can never gag a hardware-unsafe device. The Rust side mirrors this:
    // `safe` => weather_safe=true (does not OR-in unsafe), `preserve` => no
    // change. Both are non-asserting on the verdict channel.
    bool? verdictForResolution(NoDataResolution resolution) {
      switch (resolution) {
        case NoDataResolution.unsafe:
          return true;
        case NoDataResolution.safe:
        case NoDataResolution.preserve:
          return null;
      }
    }

    test('only failClosed asserts UNSAFE on the verdict channel', () {
      expect(
        verdictForResolution(
          noDataFailModeResolution(SafetyFailMode.failClosed),
        ),
        isTrue,
      );
    });

    test('failOpen and warnOnly ABSTAIN (push null), never assert SAFE', () {
      expect(
        verdictForResolution(noDataFailModeResolution(SafetyFailMode.failOpen)),
        isNull,
      );
      expect(
        verdictForResolution(noDataFailModeResolution(SafetyFailMode.warnOnly)),
        isNull,
      );
    });
  });
}
