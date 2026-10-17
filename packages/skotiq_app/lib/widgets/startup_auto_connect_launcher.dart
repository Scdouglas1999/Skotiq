import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// One-shot launcher that runs equipment auto-connect once per process on the
/// LOCAL hardware-owning master GUI (desktop [FfiBackend]).
///
/// The production call site for `ProfileService.autoConnectOnStartup()`, which
/// is what the Settings "Auto-connect equipment" toggle promises. Mirrors
/// [AutoDiscoveryLauncher]'s pattern (post-first-frame, fire-once,
/// fire-and-forget) with strict role gating.
///
/// Role gating (contract): a passive remote/mobile SLAVE launch must NEVER
/// drive host hardware merely because the host-synced setting is true, so this
/// runs ONLY when the active backend is a local [FfiBackend]. A
/// [NetworkBackend] (mobile app, or a desktop GUI launched with
/// `--remote-host`) is skipped; those clients can still call
/// `ProfileService.loadProfile` explicitly. Persisted device ids mean
/// auto-connect does not wait for discovery, so it does not race
/// [AutoDiscoveryLauncher] / `QuickStartChecker`.
///
/// Backend-classification race: at the first frame the desktop GUI may still be
/// swapping `DisconnectedBackend -> FfiBackend`. The launcher stays ARMED on the
/// backend stream until a DEFINITIVE classification lands — an [FfiBackend] runs
/// auto-connect, a [NetworkBackend] definitively skips — rather than reading
/// `DisconnectedBackend` once (or after a fixed timeout) and permanently
/// skipping. A slow first backend swap (even past 10s) is therefore still
/// honoured; the timeout only logs a diagnostic and never consumes the one shot.
class StartupAutoConnectLauncher extends ConsumerStatefulWidget {
  final Widget child;

  const StartupAutoConnectLauncher({
    super.key,
    required this.child,
  });

  @override
  ConsumerState<StartupAutoConnectLauncher> createState() =>
      _StartupAutoConnectLauncherState();
}

class _StartupAutoConnectLauncherState
    extends ConsumerState<StartupAutoConnectLauncher> {
  /// One-shot guard. Set the instant we reach a DEFINITIVE classification —
  /// either we start the [FfiBackend] auto-connect run or we skip a passive
  /// [NetworkBackend]. A rebuild / hot reload (which re-runs `build` but not
  /// `initState`) can therefore never launch a second sweep, and an
  /// indeterminate `DisconnectedBackend` (even past the diagnostic timeout)
  /// does NOT set it, so a late FFI swap is still honoured.
  bool _consumed = false;

  /// Live subscription to the backend classification, held while we wait out an
  /// indeterminate `DisconnectedBackend`. Closed on classification or disposal
  /// so a late swap after the widget is gone can never fire auto-connect.
  ProviderSubscription<SkotiqBackend>? _backendSub;

  /// Diagnostic-only timer: logs that classification is taking unusually long.
  /// It NEVER consumes the one shot — [_backendSub] stays armed for a late swap.
  Timer? _slowClassificationTimer;

  static const _source = 'StartupAutoConnectLauncher';
  static const _slowClassificationWarning = Duration(seconds: 10);

  LoggingService get _logger => ref.read(loggingServiceProvider);

  @override
  void initState() {
    super.initState();
    // Wait until the first frame is rendered so MaterialApp is mounted and the
    // non-blocking toast surface is available for a failure notification.
    WidgetsBinding.instance.addPostFrameCallback((_) => _arm());
  }

  /// Evaluate the current backend and, if it is not yet definitively
  /// classified, stay armed on the backend stream for a late
  /// `DisconnectedBackend -> FfiBackend` swap. Runs once from the
  /// post-first-frame callback.
  void _arm() {
    if (_consumed || !mounted) return;

    // Act immediately if the backend is already definitively classified.
    if (_classify(ref.read(backendProvider))) return;

    // Still indeterminate (DisconnectedBackend): remain armed until a definite
    // FfiBackend / NetworkBackend classification (or disposal).
    _backendSub = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) => _classify(next),
    );

    // Guard the read/listen gap: a swap that landed between the read above and
    // attaching the listener would otherwise be missed (the listener only fires
    // on FUTURE changes). Re-check now; _classify is idempotent via _consumed.
    if (_classify(ref.read(backendProvider))) return;

    // Diagnostic only. Logs that classification is slow but leaves the launcher
    // ARMED — a bounded wait here would resolve to a permanent skip.
    _slowClassificationTimer = Timer(_slowClassificationWarning, () {
      if (!_consumed && mounted) {
        _logger.info(
          '[StartupAutoConnect] Backend still unclassified after '
          '${_slowClassificationWarning.inSeconds}s; staying armed for a late '
          'local-backend swap',
          source: _source,
        );
      }
    });
  }

  /// Returns true once a DEFINITIVE classification is reached (and the one shot
  /// consumed): [FfiBackend] => run auto-connect; [NetworkBackend] => skip. Any
  /// other state ([DisconnectedBackend]) is indeterminate and returns false so
  /// the caller stays armed.
  bool _classify(SkotiqBackend backend) {
    if (_consumed || !mounted) return true;

    if (backend is FfiBackend) {
      _consumed = true;
      _stopWaiting();
      unawaited(_runAutoConnect());
      return true;
    }
    if (backend is NetworkBackend) {
      // Passive remote slave (mobile / `--remote-host` desktop): a passive
      // client launch must never connect host hardware. Definitively skip.
      _consumed = true;
      _stopWaiting();
      _logger.info(
        '[StartupAutoConnect] Skipped — passive remote client '
        '(backend=${backend.runtimeType})',
        source: _source,
      );
      return true;
    }
    // DisconnectedBackend / unresolved: not definitive yet — keep waiting.
    return false;
  }

  void _stopWaiting() {
    _slowClassificationTimer?.cancel();
    _slowClassificationTimer = null;
    _backendSub?.close();
    _backendSub = null;
  }

  Future<void> _runAutoConnect() async {
    try {
      await ref.read(profileServiceProvider).autoConnectOnStartup();
      _logger.info(
        '[StartupAutoConnect] Startup auto-connect completed',
        source: _source,
      );
    } catch (error, stack) {
      // Loud, contextual error log for the operator's diagnostics.
      _logger.error(
        '[StartupAutoConnect] Startup auto-connect failed: $error',
        source: _source,
        fields: {'error': error.toString(), 'stack': stack.toString()},
      );
      // Non-blocking, user-visible surface via the toast queue — safe now that
      // MaterialApp is mounted, and never a modal that could stack over the
      // onboarding / database-recovery gates. Fired exactly once because the
      // one shot is already consumed.
      if (mounted) {
        ref.read(uiNotificationProvider.notifier).showError(
              _describeFailure(error),
              title: 'Equipment auto-connect',
            );
      }
    }
  }

  String _describeFailure(Object error) {
    if (error is ProfileAutoConnectException) {
      return 'Some equipment did not connect on startup: '
          '${error.failures.join('; ')}';
    }
    return 'Equipment auto-connect failed on startup: $error';
  }

  @override
  void dispose() {
    _stopWaiting();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
