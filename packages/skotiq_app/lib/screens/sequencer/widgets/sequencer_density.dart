import 'package:flutter/widgets.dart' show IconData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// How dense the sequencer tree draws a step.
///
/// A full night — setup, two targets with narrowband and LRGB loops, triggers,
/// shutdown — is ~40 steps. At the comfortable card size that tree is
/// thousands of pixels tall, so the operator scrolls blind and cannot evaluate
/// the plan they just built. The three modes trade detail for the ability to
/// see the whole night at once:
///
///   * [comfortable] — today's card rows with their inline extras (progress
///     panels, thumbnail strips, notes).
///   * [compact] — the same rows with the inline extras suppressed.
///   * [ledger] — a fixed 28 px line with four aligned readout columns.
enum SequencerDensity {
  comfortable(label: 'Comfortable', icon: LucideIcons.layoutList),
  compact(label: 'Compact', icon: LucideIcons.rows),
  ledger(label: 'Ledger', icon: LucideIcons.alignJustify);

  const SequencerDensity({required this.label, required this.icon});

  /// The user-facing name of the mode, used by every surface that offers it
  /// (the canvas bar's segmented control, its glyph tier's tooltips and its
  /// overflow menu) so the three can never drift apart.
  final String label;

  /// The glyph the canvas bar shows when it is too narrow for [label].
  final IconData icon;

  /// Whether a row of this density keeps the extras that render BELOW it in
  /// the tree — the progress panel, the frame thumbnail strip, the container
  /// duration chip and the node's comment line. Only [comfortable] does; the
  /// other two move that content to the node inspector.
  bool get showsInlineExtras => this == SequencerDensity.comfortable;

  /// Ledger is the shipped default: the whole point of the mode is that a
  /// night fits on one screen, and a preference the user has to find first
  /// does not deliver that.
  static const defaultDensity = SequencerDensity.ledger;
}

/// The density the tree may actually render at.
///
/// The phone builder has its own row design (48 dp touch rows, no columns to
/// align, no hover to reveal actions), so it always draws comfortable rows
/// regardless of the stored preference — one settings row serves both
/// builders, and only the desktop one offers the control.
SequencerDensity effectiveSequencerDensity(
  SequencerDensity preference, {
  required bool isMobile,
}) {
  return isMobile ? SequencerDensity.comfortable : preference;
}

/// Settings key holding the persisted [SequencerDensity].
///
/// Stored as the bare enum name rather than a JSON object (the shape
/// `thumbnail_strip_prefs_v1` uses) because the preference is a single value:
/// there is no second knob for an object to hold.
const _sequencerDensityKey = 'sequencer_density_v1';

/// Persisted sequencer row density, backed by the `settingsDaoProvider`
/// persistence pattern. A read or write failure surfaces through the
/// [AsyncValue] rather than being swallowed — a silent fallback hides bugs.
final sequencerDensityPrefsProvider =
    AsyncNotifierProvider<SequencerDensityNotifier, SequencerDensity>(
  SequencerDensityNotifier.new,
);

class SequencerDensityNotifier extends AsyncNotifier<SequencerDensity> {
  @override
  Future<SequencerDensity> build() async {
    final dao = ref.read(settingsDaoProvider);
    final stored = await dao.getSetting(_sequencerDensityKey);
    if (stored == null || stored.trim().isEmpty) {
      return SequencerDensity.defaultDensity;
    }
    // An unrecognised value is a setting written by a newer build (or a
    // renamed mode). Falling back to the default keeps the sequencer usable
    // after a downgrade instead of leaving the canvas on an error state.
    return SequencerDensity.values.firstWhere(
      (density) => density.name == stored.trim(),
      orElse: () => SequencerDensity.defaultDensity,
    );
  }

  Future<void> setDensity(SequencerDensity density) async {
    final dao = ref.read(settingsDaoProvider);
    await dao.setSetting(_sequencerDensityKey, density.name);
    state = AsyncData(density);
  }
}

/// The density the tree renders at RIGHT NOW.
///
/// Synchronous on purpose: the tree is built on the first frame, before the
/// settings read has resolved, and an [AsyncValue] there would paint
/// comfortable cards and then snap to ledger rows a frame later. Falling back
/// to [SequencerDensity.defaultDensity] while loading means the first frame
/// is already the mode the user will keep, and a stored preference only ever
/// changes it away from the default.
final sequencerDensityProvider = Provider<SequencerDensity>((ref) {
  return ref.watch(sequencerDensityPrefsProvider).valueOrNull ??
      SequencerDensity.defaultDensity;
});

/// The density the canvas RESOLVED for the tree it is drawing, published by
/// `SequenceTree` once its `LayoutBuilder` knows how wide the canvas is.
///
/// The preference is only half the answer: the phone builder always draws
/// comfortable rows, and a desktop canvas narrower than the ledger's column
/// floor falls back to compact rows. Surfaces that have to agree with what is
/// ON SCREEN — the visible-row order behind the arrow keys, the gutter map and
/// the step finder — must read the resolved value, or they fold away rows the
/// tree is drawing one by one.
///
/// Null until a tree mounts, and null again once it unmounts, so a screen with
/// no sequencer on it falls back to the preference rather than to a stale
/// width decision. Not autoDispose for the same reason
/// `treeNodeKeyRegistryProvider` is not: the consumers rebuild independently
/// of the tree and must keep resolving the value.
final resolvedSequencerDensityProvider =
    StateProvider<SequencerDensity?>((ref) => null);

/// The density the tree is actually drawing right now: the canvas's resolved
/// value while a tree is mounted, the stored preference otherwise.
final canvasSequencerDensityProvider = Provider<SequencerDensity>((ref) {
  return ref.watch(resolvedSequencerDensityProvider) ??
      ref.watch(sequencerDensityProvider);
});
