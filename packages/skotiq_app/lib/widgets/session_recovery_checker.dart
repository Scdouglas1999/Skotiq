import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'session_recovery_dialog.dart';

/// Widget that checks for incomplete sessions on startup and shows recovery dialog
class SessionRecoveryChecker extends ConsumerStatefulWidget {
  final Widget child;

  const SessionRecoveryChecker({
    super.key,
    required this.child,
  });

  @override
  ConsumerState<SessionRecoveryChecker> createState() =>
      _SessionRecoveryCheckerState();
}

class _SessionRecoveryCheckerState
    extends ConsumerState<SessionRecoveryChecker> {
  bool _hasChecked = false;

  @override
  void initState() {
    super.initState();
    // Schedule check after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForIncompleteSessions();
    });
  }

  Future<void> _checkForIncompleteSessions() async {
    if (_hasChecked || !mounted) return;

    _hasChecked = true;

    try {
      // Wait for the provider to complete
      final incompleteSessions =
          await ref.read(incompleteSessionsProvider.future);

      if (incompleteSessions.isNotEmpty && mounted) {
        // Delay to ensure UI is ready
        await Future.delayed(const Duration(milliseconds: 500));

        if (mounted) {
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => SessionRecoveryDialog(
              incompleteSessions: incompleteSessions,
            ),
          );
        }
      }
    } catch (e, stackTrace) {
      ref.read(loggingServiceProvider).warning(
        '[SessionRecovery] Error checking for incomplete sessions: $e',
        source: 'SessionRecoveryChecker',
        fields: {
          'error': e.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
      if (!mounted) return;

      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.clearSnackBars();
      messenger?.showSnackBar(
        SnackBar(
          content: const Text(
            'Skotiq could not check for an interrupted imaging session. '
            'Recovery status is unknown.',
          ),
          duration: const Duration(days: 1),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () {
              _hasChecked = false;
              ref.invalidate(incompleteSessionsProvider);
              unawaited(_checkForIncompleteSessions());
            },
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
