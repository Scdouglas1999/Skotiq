import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../utils/startup_ui_context.dart';

/// Shows what the night-end automation did as a toast on whatever screen is
/// open. The automation itself is an always-on service.
class NightEndToasts extends ConsumerStatefulWidget {
  const NightEndToasts({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<NightEndToasts> createState() => _NightEndToastsState();
}

class _NightEndToastsState extends ConsumerState<NightEndToasts> {
  @override
  void initState() {
    super.initState();
    ref.listenManual<NightEndCompletion?>(
      nightEndCompletionProvider,
      (previous, next) {
        if (!mounted || next == null) return;
        if (previous?.generation == next.generation) return;
        final overlay = resolveStartupOverlay(ref, context);
        if (overlay == null || !overlay.mounted) return;
        SkotiqToastHelper.showInOverlay(
          overlay: overlay,
          message: next.toast.message,
          severity: next.toast.failed
              ? SkotiqAlertSeverity.error
              : SkotiqAlertSeverity.success,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
