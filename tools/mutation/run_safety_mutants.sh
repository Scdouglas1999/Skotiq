#!/usr/bin/env bash
# Scoped cargo-mutants runs over the safety-critical Rust logic.
#
# Usage: tools/mutation/run_safety_mutants.sh <target> [extra cargo-mutants args]
#   targets: recovery, slew, meridian, autofocus, grading, updater, all
#          tools/mutation/run_safety_mutants.sh file <output-name> <path-in-workspace>
#
# Each target mutates only the files (and, where noted, the functions) that
# decide whether the rig keeps exposing, parks, flips, or trusts a result, so a
# run finishes in tens of minutes instead of mutating the whole workspace.
#
# Environment:
#   MUTANTS_JOBS      parallel mutant builds (default 3; the dev machine is shared)
#   MUTANTS_OUT       output root (default ~/.cache/sk-reports/w27-mutation)
#   MUTANTS_TMP       scratch root for the workspace copies (default ~/.cache/sk-tmp/mutants)
#   MUTANTS_FAST=1    run only the sequencer's unit tests, and skip the
#                     wall-clock-heavy focuser backlash and meridian-flip tests on
#                     targets that do not mutate that code. Rerun the survivors
#                     without it (`--iterate`) before trusting a miss.
#
# Builds carry no debuginfo (linking dominates a mutant's build otherwise). The
# autofocus target builds at opt-level 1: its focuser backlash simulations are
# CPU-bound and take minutes per run in a plain debug build.
set -euo pipefail

target="${1:?usage: $0 <recovery|slew|meridian|autofocus|grading|updater|all> [cargo-mutants args]}"
shift || true

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workspace="$repo_root/native/skotiq_native"
out_root="${MUTANTS_OUT:-$HOME/.cache/sk-reports/w27-mutation}"
jobs="${MUTANTS_JOBS:-3}"

# cargo-mutants copies the workspace into TMPDIR and builds each copy in its own
# target dir; a shared CARGO_TARGET_DIR would make parallel mutants clobber
# each other.
unset CARGO_TARGET_DIR
# imaging/build.rs reads version.yaml three directories above its manifest,
# which for a copy at $TMPDIR/cargo-mutants-*/imaging is $TMPDIR/.. — so the
# copies live one level below a directory holding a copy of version.yaml.
mutants_tmp="${MUTANTS_TMP:-$HOME/.cache/sk-tmp/mutants}"
mkdir -p "$mutants_tmp/copies" "$out_root"
cp "$repo_root/version.yaml" "$mutants_tmp/version.yaml"
export TMPDIR="$mutants_tmp/copies"
export CARGO_PROFILE_DEV_DEBUG=0
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"

slow_test_skips=(-- -- --skip focuser_backlash --skip meridian_flip_executor::tests::a_failed_flip
  --skip meridian_flip_executor::tests::exhausted_flip --skip meridian_flip_executor::tests::retried_flip
  --skip meridian_flip_executor::tests::a_successful_flip_announces)
meridian_test_skips=(-- -- --skip meridian_flip_executor::tests::a_failed_flip
  --skip meridian_flip_executor::tests::exhausted_flip --skip meridian_flip_executor::tests::retried_flip
  --skip meridian_flip_executor::tests::a_successful_flip_announces)

run() {
  local name="$1"; shift
  local -a files=() test_args=() extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do files+=(--file "$1"); shift; done
  [[ $# -gt 0 ]] && shift
  while [[ $# -gt 0 && "$1" != "--" ]]; do extra+=("$1"); shift; done
  if [[ "${MUTANTS_FAST:-0}" == "1" && "$name" != "updater" ]]; then
    extra+=(-C --lib)
    case "$name" in
      autofocus) test_args=("${meridian_test_skips[@]}") ;;
      meridian) test_args=(-- -- --skip focuser_backlash) ;;
      *) test_args=("${slow_test_skips[@]}") ;;
    esac
  fi
  echo "== $name"
  (cd "$workspace" && if [[ "$name" == "autofocus" ]]; then export CARGO_PROFILE_DEV_OPT_LEVEL=1; fi
    cargo mutants --jobs "$jobs" --output "$out_root/$name" \
    "${files[@]}" "${extra[@]}" "${passthrough[@]}" "${test_args[@]}") || true
}

passthrough=("$@")
seq=sequencer/src

recovery() {
  run recovery \
    $seq/executor/monitoring.rs $seq/executor/recovery_ops.rs $seq/executor/recovery.rs \
    $seq/executor/start/recovery_driver.rs $seq/executor/start/trigger_monitor.rs \
    $seq/executor/trigger_context.rs $seq/recovery/mod.rs $seq/triggers/state.rs \
    $seq/instructions/expose.rs $seq/instructions/context.rs -- \
    --exclude-re 'next_grid_dither_offset|calculate_drift_pixels'
}

slew() {
  run slew $seq/instructions/slew.rs $seq/device_ops.rs -- \
    --re 'slew|of_date|j2000|precess|epoch|read_back|readback|arrival|coordinates|radec|ra_dec' --exclude-re NullDeviceOps
}

meridian() {
  run meridian $seq/meridian.rs $seq/meridian_flip_executor.rs $seq/meridian_events.rs \
    $seq/triggers/meridian_window.rs $seq/instructions/meridian_flip.rs
}

autofocus() {
  # The final approach (run-up side, landing, restoring guiding) and the
  # backlash measurement; config validation and HFR cropping are left out.
  run autofocus $seq/instructions/autofocus.rs $seq/focuser_calibration.rs \
    $seq/instructions/focuser_calibration.rs -- \
    --re 'execute_autofocus_once|execute_autofocus_attempts|resolve_run_up|final_run_up_position|restore_autofocus_origin|resume_guiding_after_autofocus|append_guiding_not_restored|derive_backlash_calibration|validate_scan|grade_confidence|resolution_limit_steps|DirectionalScan|worst_r_squared|scan_one_direction|plan_backlash_calibration|fit_one_direction|run_both_scans|scan_positions|settle_after_move'
}

grading() {
  run grading $seq/instructions/grading.rs $seq/quality/image_grading.rs
}

updater() {
  run updater updater/src/main.rs
}

# `file <name> <path>`: mutate one file on its own, with the fast-mode test
# selection of the target it belongs to, e.g. after adding tests for it.
file() {
  local name="$1" path="$2"
  passthrough=("${passthrough[@]:2}")
  run "$name" "$path"
}

case "$target" in
  recovery|slew|meridian|autofocus|grading|updater) "$target" ;;
  file) file "${passthrough[@]:0:2}" ;;
  all) recovery; slew; meridian; autofocus; grading; updater ;;
  *) echo "unknown target: $target" >&2; exit 2 ;;
esac
