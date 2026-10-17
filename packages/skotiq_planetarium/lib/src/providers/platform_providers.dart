import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Display refresh rate in Hz.
///
/// Uses the platform display when available, with an optional override
/// via SKOTIQ_REFRESH_RATE for headless environments.
final displayRefreshRateProvider = Provider<double>((ref) {
  const defaultHz = 60.0;

  if (!kIsWeb) {
    final override = Platform.environment['SKOTIQ_REFRESH_RATE'];
    if (override != null) {
      final parsed = double.tryParse(override);
      if (parsed != null && parsed > 0) {
        return parsed;
      }
      if (kDebugMode) {
        developer.log(
          '[Platform] Invalid SKOTIQ_REFRESH_RATE="$override", using $defaultHz Hz.',
          name: 'PlatformProviders',
          level: 900,
        );
      }
    }
  }

  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) {
    if (kDebugMode) {
      developer.log(
        '[Platform] No Flutter views available, using $defaultHz Hz.',
        name: 'PlatformProviders',
        level: 900,
      );
    }
    return defaultHz;
  }

  final refreshRate = views.first.display.refreshRate;
  return refreshRate > 0 ? refreshRate : defaultHz;
});
