import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../utils/snackbar_helper.dart';

/// Set true when the WebSocket connection to a remote backend has been
/// down briefly but is still within the reconnect grace window. The mobile app
/// drives this; desktop/headless do not flip it.
final connectionStaleProvider = StateProvider<bool>((_) => false);

/// Inline banner shown across all screens while the mobile app is mid-
/// reconnect.
///
/// During the 30-second grace window the operator gets a "Retry" button to
/// force an immediate reconnect attempt instead of waiting for the
/// exponential-backoff timer. The button is a no-op when the current backend is
/// not a [NetworkBackend] (e.g. host-side desktop).
class ConnectionStaleBanner extends ConsumerStatefulWidget {
  const ConnectionStaleBanner({super.key});

  @override
  ConsumerState<ConnectionStaleBanner> createState() =>
      _ConnectionStaleBannerState();
}

class _ConnectionStaleBannerState extends ConsumerState<ConnectionStaleBanner> {
  bool _retrying = false;
  int _retryGeneration = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (!_retrying || previous == null || identical(previous, next)) return;
        _retryGeneration++;
        if (mounted) setState(() => _retrying = false);
      },
    );
  }

  @override
  void dispose() {
    _retryGeneration++;
    _backendSubscription?.close();
    super.dispose();
  }

  Future<void> _handleRetry() async {
    if (_retrying) return;
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) {
      if (mounted) {
        context.showErrorSnackBar(
          'The remote session is no longer available. Reconnect from the '
          'server screen.',
        );
      }
      return;
    }
    final generation = ++_retryGeneration;
    setState(() => _retrying = true);
    try {
      await backend.reconnectNow();
    } catch (e) {
      if (mounted && _isCurrentRetry(generation, backend)) {
        context.showErrorSnackBar('Reconnect failed: $e');
      }
    } finally {
      if (_isCurrentRetry(generation, backend)) {
        setState(() => _retrying = false);
      }
    }
  }

  bool _isCurrentRetry(int generation, NetworkBackend backend) =>
      mounted &&
      generation == _retryGeneration &&
      identical(ref.read(backendProvider), backend);

  @override
  Widget build(BuildContext context) {
    final stale = ref.watch(connectionStaleProvider);
    if (!stale) return const SizedBox.shrink();
    final canRetry = ref.watch(backendProvider) is NetworkBackend;

    final colors = SkotiqColors.of(context);
    final bg = colors.warning;
    final fg = colors.background;

    return Material(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: SkotiqSpinner(size: 14, color: fg),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Reconnecting to server… session controls may be stale.',
                style: TextStyle(
                  color: fg,
                  fontSize: SkotiqTypography.fontSize12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _retrying || !canRetry ? null : _handleRetry,
              child: Text(
                _retrying
                    ? 'Retrying…'
                    : canRetry
                        ? 'Retry'
                        : 'Reconnect required',
                style: TextStyle(
                  color:
                      _retrying || !canRetry ? fg.withValues(alpha: 0.5) : fg,
                  fontSize: SkotiqTypography.fontSize12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
