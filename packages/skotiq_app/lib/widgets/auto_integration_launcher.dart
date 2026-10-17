import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../screens/session_review/auto_integration_service.dart';
import '../utils/startup_ui_context.dart';

/// Keeps host-side post-session integration alive independently of navigation
/// and surfaces its result through the app-wide toast overlay.
class AutoIntegrationLauncher extends ConsumerStatefulWidget {
  const AutoIntegrationLauncher({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AutoIntegrationLauncher> createState() =>
      _AutoIntegrationLauncherState();
}

class _AutoIntegrationLauncherState
    extends ConsumerState<AutoIntegrationLauncher> {
  @override
  void initState() {
    super.initState();
    ref.read(autoIntegrationCoordinatorProvider);
    ref.listenManual<AutoIntegrationCompletion?>(
      autoIntegrationCompletionProvider,
      (previous, next) {
        if (!mounted || next == null) return;
        if (previous?.generation == next.generation) return;
        final overlay = resolveStartupOverlay(ref, context);
        if (overlay == null || !overlay.mounted) return;
        SkotiqToastHelper.showInOverlay(
          overlay: overlay,
          message: next.result.message,
          severity: next.result.failed
              ? SkotiqAlertSeverity.error
              : SkotiqAlertSeverity.success,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
