/// The digits the sequencer prints for a number of seconds: `300` not `300.0`,
/// `1.5` not `1.50`.
///
/// One function, in a library with no dependencies at all, because the same
/// exposure length is printed in four places on the same screen — the
/// `Filter / exp` cell of a ledger row, the chip on a folded run, the rollup
/// summary under a collapsed container, and the fold model's own chip text —
/// and a run whose chip said `1.5 s` next to a cell saying `2s` would be
/// reporting two different exposures. The fold model
/// (`sequence_fold_model.dart`) is deliberately Flutter-free, so the shared
/// copy cannot live beside the widgets that use it.
///
/// The UNIT is spelled differently by design, and the spec fixes both: the
/// fixed-width column packs it (`Ha 300s`, spec §2) because the space is dead
/// pixels in a 70 px cell, while the chip and the rollup read as prose
/// (`300 s ×12 each`, spec §3 and §6). Only the digits are shared.
String formatLedgerSeconds(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toStringAsFixed(1);
}
