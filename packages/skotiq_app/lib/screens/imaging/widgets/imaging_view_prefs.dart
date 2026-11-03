import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// An on/off view choice of this device, remembered across restarts.
class PersistedBoolNotifier extends StateNotifier<bool> {
  PersistedBoolNotifier(this.prefsKey, {bool defaultValue = false})
      : super(defaultValue) {
    unawaited(_hydrate(defaultValue));
  }

  final String prefsKey;

  /// Set once the operator chose, so a slow first read of the stored value
  /// cannot overwrite a choice made while it was in flight.
  bool _chosen = false;

  Future<void> _hydrate(bool defaultValue) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _chosen) return;
      state = prefs.getBool(prefsKey) ?? defaultValue;
    } catch (e) {
      developer.log('Failed to read $prefsKey: $e', name: 'ImagingViewPrefs');
    }
  }

  /// Sets the value and remembers it.
  Future<void> set(bool value) async {
    _chosen = true;
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, value);
    } catch (e) {
      developer.log('Failed to store $prefsKey: $e', name: 'ImagingViewPrefs');
    }
  }
}

const String _crosshairKey = 'imaging.showCrosshair';
const String _starOverlayKey = 'imaging.showStarOverlay';

/// Keeps the Imaging preview's crosshair and star-detection overlays as the
/// operator left them across restarts (the histogram overlay already was;
/// these came back off). Watch it from the screen that shows them.
final imagingViewPrefsBinderProvider = Provider<void>((ref) {
  var hydrated = false;
  Future<void> hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final viewer = ref.read(imagingViewerStateProvider.notifier);
      final state = ref.read(imagingViewerStateProvider);
      if ((prefs.getBool(_crosshairKey) ?? false) != state.showCrosshair) {
        viewer.toggleCrosshair();
      }
      if ((prefs.getBool(_starOverlayKey) ?? false) != state.showStarOverlay) {
        viewer.toggleStarOverlay();
      }
    } catch (e) {
      developer.log('Failed to read the view overlays: $e',
          name: 'ImagingViewPrefs');
    } finally {
      hydrated = true;
    }
  }

  unawaited(hydrate());
  ref.listen<ImagingViewerState>(imagingViewerStateProvider, (prev, next) {
    if (!hydrated || prev == null) return;
    if (prev.showCrosshair == next.showCrosshair &&
        prev.showStarOverlay == next.showStarOverlay) {
      return;
    }
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_crosshairKey, next.showCrosshair);
        await prefs.setBool(_starOverlayKey, next.showStarOverlay);
      } catch (e) {
        developer.log('Failed to store the view overlays: $e',
            name: 'ImagingViewPrefs');
      }
    }());
  });
});
