import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
