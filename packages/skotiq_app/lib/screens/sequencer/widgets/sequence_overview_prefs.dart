import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';

import 'sequencer_density.dart';

/// Whether the sequence overview (the 80 px strip under the tree) is showing,
/// remembered per density. Comfortable and Compact each keep the operator's
/// own choice, which a density switch gives back; Ledger draws no overview.
@immutable
class SequenceOverviewPrefs {
  /// The densities the user has actually chosen in. A density they have never
  /// toggled in is absent rather than stored at its default, so a later change
  /// to a default reaches everyone who never disagreed with it.
  final Map<SequencerDensity, bool> _chosen;

  const SequenceOverviewPrefs._(this._chosen);

  /// Nothing chosen yet: every density answers with its own default.
  static const defaults = SequenceOverviewPrefs._(<SequencerDensity, bool>{});

  /// The overview strip is off until asked for: it costs 80 px of the tree
  /// the rows already need.
  static bool defaultVisibleIn(SequencerDensity density) => false;

  /// Ledger has no overview: its colored blocks repeated the rows beside
  /// them and took width the step names need.
  bool visibleIn(SequencerDensity density) =>
      density != SequencerDensity.ledger &&
      (_chosen[density] ?? defaultVisibleIn(density));

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
    final stored = await ref
        .read(settingsDaoProvider)
        .read(StoreSettings.sequenceOverview);
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
    await ref
        .read(settingsDaoProvider)
        .write(StoreSettings.sequenceOverview, jsonEncode(updated.toJson()));
    state = AsyncData(updated);
  }
}

/// Whether the overview is showing RIGHT NOW, in the density the canvas is
/// actually drawing.
///
/// Synchronous for the same reason [sequencerDensityProvider] is: the tree is
/// built on the first frame, before the settings read has resolved, and an
/// [AsyncValue] here would open the strip a frame after the rows it belongs
/// to. It reads [canvasSequencerDensityProvider], not the preference, so a
/// canvas too narrow to host Ledger toggles the strip it is really drawing.
final sequenceOverviewVisibleProvider = Provider<bool>((ref) {
  final prefs = ref.watch(sequenceOverviewPrefsProvider).valueOrNull ??
      SequenceOverviewPrefs.defaults;
  return prefs.visibleIn(ref.watch(canvasSequencerDensityProvider));
});

/// What the canvas bar's overview control does if it is pressed now.
String sequenceOverviewToggleLabel({required bool visible}) =>
    visible ? 'Hide the map' : 'Show the map';

/// The one word the labelled tier puts on the overview button.
const String sequenceOverviewButtonLabel = 'Map';
