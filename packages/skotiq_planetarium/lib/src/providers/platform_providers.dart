import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _platformProvidersLog = Logger('skotiq.PlatformProviders');

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
        _platformProvidersLog.warning(
          '[Platform] Invalid SKOTIQ_REFRESH_RATE="$override", using $defaultHz Hz.',
        );
      }
    }
  }

  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) {
    if (kDebugMode) {
      _platformProvidersLog.warning(
        '[Platform] No Flutter views available, using $defaultHz Hz.',
      );
    }
    return defaultHz;
  }

  final refreshRate = views.first.display.refreshRate;
  return refreshRate > 0 ? refreshRate : defaultHz;
});
