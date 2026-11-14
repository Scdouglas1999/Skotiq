import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/services.dart';

import 'startup_ui_context.dart';
import '../utils/snackbar_helper.dart';

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
        final ui = resolveStartupUiContext(ref, context);
        if (ui == null || !ui.mounted) return;
        if (next.toast.failed) {
          ui.showErrorSnackBar(next.toast.message);
        } else {
          ui.showSuccessSnackBar(next.toast.message);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
