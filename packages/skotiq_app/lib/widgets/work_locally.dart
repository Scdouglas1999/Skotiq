import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../utils/snackbar_helper.dart';

/// Whether this build can stand up a local backend at all.
///
/// Only the desktop/headless entry points install an FfiBackend
/// (`apps/desktop/lib/main.dart`); the phone app is a client of a rig it never
/// owns, so offering "work locally" there would be a button to nowhere.
bool get canWorkLocally =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

/// Reinstate the local [FfiBackend] on a machine sitting on a
/// [DisconnectedBackend], and say what happened.
///
/// Shared by Settings, the disconnected banner, and the title-bar popover so
/// superseded transitions are handled consistently.
Future<void> switchToLocalBackend(BuildContext context, WidgetRef ref) async {
  try {
    await ref.read(backendProvider.notifier).useLocalBackend();
    if (context.mounted) {
      context
          .showSuccessSnackBar('Now driving the equipment on this computer.');
    }
  } on BackendTransitionSupersededException {
    // A newer connect/disconnect took ownership of the backend; that request
    // owns the visible outcome, so say nothing here.
  } catch (error) {
    if (context.mounted) {
      context.showErrorSnackBar('Could not switch to local mode: $error');
    }
  }
}

/// Design-system "Work Locally" button, with the double-tap guard the swap
/// needs (it quiesces the outgoing device service, so it is not instant).
class WorkLocallyButton extends ConsumerStatefulWidget {
  const WorkLocallyButton({
    super.key,
    this.variant = ButtonVariant.outline,
    this.icon,
    this.fullWidth = false,
  });

  final ButtonVariant variant;
  final IconData? icon;

  /// Stretch to the available width (the connection popover stacks its
  /// actions full-bleed; the settings row wants an intrinsic button).
  final bool fullWidth;

  @override
  ConsumerState<WorkLocallyButton> createState() => _WorkLocallyButtonState();
}

class _WorkLocallyButtonState extends ConsumerState<WorkLocallyButton> {
  bool _switching = false;

  Future<void> _run() async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      await switchToLocalBackend(context, ref);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final button = SkotiqButton(
      label: 'Work locally',
      icon: widget.icon,
      variant: widget.variant,
      size: ButtonSize.small,
      isLoading: _switching,
      onPressed: _switching ? null : _run,
    );
    return widget.fullWidth
        ? SizedBox(width: double.infinity, child: button)
        : button;
  }
}
