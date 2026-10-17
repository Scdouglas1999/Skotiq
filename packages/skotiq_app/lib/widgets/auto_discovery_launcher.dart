import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Widget that triggers device discovery in the background after app launch.
///
/// This uses several techniques to avoid freezing the UI:
/// 1. Uses addPostFrameCallback to wait until the first frame is rendered
/// 2. Adds an additional delay to ensure the UI is fully interactive
/// 3. Fire-and-forget pattern - doesn't await the discovery completion
/// 4. Discovery itself runs backends in parallel for speed
class AutoDiscoveryLauncher extends ConsumerStatefulWidget {
  final Widget child;

  const AutoDiscoveryLauncher({
    super.key,
    required this.child,
  });

  @override
  ConsumerState<AutoDiscoveryLauncher> createState() =>
      _AutoDiscoveryLauncherState();
}

class _AutoDiscoveryLauncherState extends ConsumerState<AutoDiscoveryLauncher> {
  bool _consumed = false;
  ProviderSubscription<SkotiqBackend>? _backendSub;

  LoggingService get _logger => ref.read(loggingServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _arm());
  }

  void _arm() {
    if (_consumed || !mounted) return;
    if (_classify(ref.read(backendProvider))) return;

    _backendSub = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) => _classify(next),
    );
    _classify(ref.read(backendProvider));
  }

  bool _classify(SkotiqBackend backend) {
    if (_consumed || !mounted) return true;
    if (backend is FfiBackend) {
      _consumed = true;
      _stopWaiting();
      unawaited(_triggerAutoDiscovery(backend));
      return true;
    }
    if (backend is NetworkBackend) {
      _consumed = true;
      _stopWaiting();
      _logger.info(
        '[AutoDiscovery] Skipped — connected to remote Skotiq host',
        source: 'AutoDiscoveryLauncher',
      );
      return true;
    }
    return false;
  }

  void _stopWaiting() {
    _backendSub?.close();
    _backendSub = null;
  }

  Future<void> _triggerAutoDiscovery(FfiBackend authority) async {
    if (!mounted) return;

    try {
      // Wait for settings to load
      final settings = await ref.read(appSettingsProvider.future);

      // Check if auto-discovery is enabled
      if (!settings.autoDiscoverOnLaunch) {
        _logger.info('[AutoDiscovery] Auto-discovery disabled in settings',
            source: 'AutoDiscoveryLauncher');
        return;
      }

      // Additional delay to ensure UI is fully interactive
      // This prevents any perceived stutter during app startup
      await Future.delayed(const Duration(milliseconds: 800));

      if (!mounted) return;
      if (!identical(ref.read(backendProvider), authority)) {
        _logger.info(
          '[AutoDiscovery] Skipped — backend changed before discovery began',
          source: 'AutoDiscoveryLauncher',
        );
        return;
      }

      _logger.info('[AutoDiscovery] Starting background device discovery...',
          source: 'AutoDiscoveryLauncher');

      // Fire-and-forget: Start discovery without awaiting completion
      // This allows the UI to remain responsive while discovery runs
      _runDiscoveryInBackground(
        includeIndi: settings.indiAutoConnect,
        includeAlpaca: settings.alpacaAutoDiscover,
      );
    } catch (e) {
      _logger.error('[AutoDiscovery] Error during auto-discovery setup: $e',
          source: 'AutoDiscoveryLauncher', fields: {'error': e.toString()});
      // Don't show error to user - this is a background operation
    }
  }

  @override
  void dispose() {
    _stopWaiting();
    super.dispose();
  }

  void _runDiscoveryInBackground({
    required bool includeIndi,
    required bool includeAlpaca,
  }) {
    // Use Future.microtask to ensure this doesn't block the current frame
    Future.microtask(() async {
      try {
        if (!mounted) return;

        final discoveryNotifier = ref.read(unifiedDiscoveryProvider.notifier);

        // Run discovery - this already runs backends in parallel internally
        await discoveryNotifier.discoverAll(
          includeIndi: includeIndi,
          includeAlpaca: includeAlpaca,
        );

        _logger.info('[AutoDiscovery] Background discovery completed',
            source: 'AutoDiscoveryLauncher');
      } catch (e) {
        _logger.warning('[AutoDiscovery] Discovery error (non-fatal): $e',
            source: 'AutoDiscoveryLauncher', fields: {'error': e.toString()});
        // Errors during discovery are non-fatal - user can manually refresh
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
