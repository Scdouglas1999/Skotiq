import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

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
      Log.debug(
        'Failed to read the view overlays: $e',
        source: 'ImagingViewPrefs',
      );
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
        Log.debug(
          'Failed to store the view overlays: $e',
          source: 'ImagingViewPrefs',
        );
      }
    }());
  });
});
