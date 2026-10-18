import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key holding whether the live-view histogram is drawn
/// over the frame.
const String previewHistogramVisiblePrefsKey =
    'imaging.previewHistogramVisible';

/// Whether the histogram panel is drawn over the live-view frame.
///
/// Off by default: the canvas belongs to the frame, and the histogram is a
/// reading most operators look at while setting up, not all night. Turning it
/// on (Overlays → Histogram) is remembered across restarts, so an operator who
/// wants it does not have to ask again every session.
final previewHistogramVisibleProvider =
    StateNotifierProvider<PreviewHistogramVisibleNotifier, bool>(
  (ref) => PreviewHistogramVisibleNotifier(),
);

class PreviewHistogramVisibleNotifier extends StateNotifier<bool> {
  PreviewHistogramVisibleNotifier() : super(false) {
    unawaited(_hydrate());
  }

  /// Set once the operator has toggled the overlay, so a slow first read of
  /// the stored value cannot overwrite a choice made while it was in flight.
  bool _chosen = false;

  Future<void> _hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _chosen) return;
      state = prefs.getBool(previewHistogramVisiblePrefsKey) ?? false;
    } catch (e, st) {
      developer.log(
        'Failed to read the histogram overlay preference: $e',
        name: 'PreviewHistogramVisible',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Shows or hides the histogram and remembers the choice.
  Future<void> setVisible(bool visible) async {
    _chosen = true;
    state = visible;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(previewHistogramVisiblePrefsKey, visible);
    } catch (e, st) {
      developer.log(
        'Failed to store the histogram overlay preference: $e',
        name: 'PreviewHistogramVisible',
        error: e,
        stackTrace: st,
      );
    }
  }
}
