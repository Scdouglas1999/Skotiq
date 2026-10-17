import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'sequencer_density.dart';

/// Whether the sequence overview is showing, remembered per density.
///
/// The overview is one feature with two shapes: the 80 px strip under the tree
/// in Comfortable and Compact, and the 34 px gutter down the tree's right edge
/// in Ledger. They cost the canvas different things — the strip takes height
/// the rows were using, the gutter takes width the ledger columns were using —
/// so one shared on/off would make the canvas bar's toggle undo a trade the
/// user made somewhere else. A choice per density is what the operator
/// actually expressed, and it is what a density switch has to give back.
@immutable
class SequenceOverviewPrefs {
  /// The densities the user has actually chosen in. A density they have never
  /// toggled in is absent rather than stored at its default, so a later change
  /// to a default reaches everyone who never disagreed with it.
  final Map<SequencerDensity, bool> _chosen;

  const SequenceOverviewPrefs._(this._chosen);

  /// Nothing chosen yet: every density answers with its own default.
  static const defaults = SequenceOverviewPrefs._(<SequencerDensity, bool>{});

  /// Ledger's overview is on out of the box and the other two densities' is
  /// off (spec §7): the gutter is the only thing that makes a 40-step night
  /// navigable at 28 px a row, while the strip costs 80 px of the tree the
  /// comfortable rows already need.
  static bool defaultVisibleIn(SequencerDensity density) =>
      density == SequencerDensity.ledger;

  /// Whether the overview shows while the tree is drawing [density].
  bool visibleIn(SequencerDensity density) =>
      _chosen[density] ?? defaultVisibleIn(density);

  SequenceOverviewPrefs withVisibility(
    SequencerDensity density,
    bool visible,
  ) =>
      SequenceOverviewPrefs._({..._chosen, density: visible});

  Map<String, dynamic> toJson() => {
        for (final entry in _chosen.entries) entry.key.name: entry.value,
      };

  /// Reads back what [toJson] wrote, ignoring keys that name no density (a
  /// mode this build has dropped, or one a newer build added) and values that
  /// are not booleans, so one bad row cannot cost the user the rest of them.
  factory SequenceOverviewPrefs.fromJson(Map<String, dynamic> json) {
    final chosen = <SequencerDensity, bool>{};
    for (final density in SequencerDensity.values) {
      final stored = json[density.name];
      if (stored is bool) chosen[density] = stored;
    }
    return SequenceOverviewPrefs._(chosen);
  }

  @override
  bool operator ==(Object other) =>
      other is SequenceOverviewPrefs && mapEquals(_chosen, other._chosen);

  @override
  int get hashCode => Object.hashAllUnordered(
        [for (final entry in _chosen.entries) (entry.key, entry.value)],
      );
}

/// Settings key holding the persisted [SequenceOverviewPrefs].
///
/// A JSON object rather than one row per density (the shape
/// `sequencer_density_v1` uses) because the value is a map: densities come and
/// go with the spec, and a key per mode would leave orphan rows behind.
const _sequenceOverviewKey = 'sequence_overview_visible_v1';

/// Persisted overview visibility, backed by the `settingsDaoProvider`
/// persistence pattern. A read or write failure surfaces through the
/// [AsyncValue] rather than being swallowed — a silent fallback hides bugs.
final sequenceOverviewPrefsProvider =
    AsyncNotifierProvider<SequenceOverviewPrefsNotifier, SequenceOverviewPrefs>(
  SequenceOverviewPrefsNotifier.new,
);

class SequenceOverviewPrefsNotifier
    extends AsyncNotifier<SequenceOverviewPrefs> {
  @override
  Future<SequenceOverviewPrefs> build() async {
    final dao = ref.read(settingsDaoProvider);
    final stored = await dao.getSetting(_sequenceOverviewKey);
    if (stored == null || stored.trim().isEmpty) {
      return SequenceOverviewPrefs.defaults;
    }
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Sequence overview prefs JSON is not an object: $stored',
      );
    }
    return SequenceOverviewPrefs.fromJson(decoded);
  }

  Future<void> setVisible(SequencerDensity density, bool visible) async {
    final updated = (state.value ?? SequenceOverviewPrefs.defaults)
        .withVisibility(density, visible);
    final dao = ref.read(settingsDaoProvider);
    await dao.setSetting(_sequenceOverviewKey, jsonEncode(updated.toJson()));
    state = AsyncData(updated);
  }
}

/// Whether the overview is showing RIGHT NOW, in the density the canvas is
/// actually drawing.
///
/// Synchronous for the same reason [sequencerDensityProvider] is: the tree is
/// built on the first frame, before the settings read has resolved, and an
/// [AsyncValue] here would open the gutter a frame after the rows it belongs
/// to. It reads [canvasSequencerDensityProvider], not the preference, so a
/// canvas too narrow to host Ledger toggles the strip it is really drawing
/// instead of the gutter it is not.
final sequenceOverviewVisibleProvider = Provider<bool>((ref) {
  final prefs = ref.watch(sequenceOverviewPrefsProvider).valueOrNull ??
      SequenceOverviewPrefs.defaults;
  return prefs.visibleIn(ref.watch(canvasSequencerDensityProvider));
});

/// What the canvas bar's overview control does if it is pressed now.
///
/// The two densities hide two different things in two different places, and a
/// control that named neither is how "Show the map" came to do nothing in
/// Ledger: it was talking about a strip that density does not draw.
String sequenceOverviewToggleLabel({
  required SequencerDensity density,
  required bool visible,
}) {
  final noun = density == SequencerDensity.ledger ? 'overview gutter' : 'map';
  return visible ? 'Hide the $noun' : 'Show the $noun';
}

/// The one word the labelled tier puts on the button, for the same reason.
String sequenceOverviewButtonLabel(SequencerDensity density) =>
    density == SequencerDensity.ledger ? 'Gutter' : 'Map';
