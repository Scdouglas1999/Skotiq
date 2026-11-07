import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../screens/sequencer/widgets/mount_unpark_dialog.dart';
import '../utils/startup_ui_context.dart';

/// Puts up the "Mount is parked, unparking in N s" countdown when the window
/// at the other end of a link pressed Start, so this window sees the unpark
/// coming and can cancel it. The window that pressed Start shows its own.
///
/// Mounted high in the app shell, above the router's Navigator.
class LinkedPendingStartListener extends ConsumerStatefulWidget {
  const LinkedPendingStartListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LinkedPendingStartListener> createState() =>
      _LinkedPendingStartListenerState();
}

class _LinkedPendingStartListenerState
    extends ConsumerState<LinkedPendingStartListener> {
  static const _maxNavigatorWaits = 30;

  String? _showing;

  @override
  void initState() {
    super.initState();
    ref.listenManual<PendingSequenceStart?>(
      pendingSequenceStartProvider,
      (_, next) => _maybeShow(next),
      fireImmediately: true,
    );
  }

  void _maybeShow(PendingSequenceStart? pending, {int waits = 0}) {
    if (pending == null ||
        pending.owner == runtimeMirrorOrigin ||
        pending.phase == PendingStartPhase.cancelled ||
        _showing == pending.id ||
        !mounted) {
      return;
    }
    final uiContext = resolveStartupUiContext(ref, context);
    if (uiContext == null || !uiContext.mounted) {
      if (waits >= _maxNavigatorWaits) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _maybeShow(ref.read(pendingSequenceStartProvider), waits: waits + 1);
        }
      });
      return;
    }
    final id = pending.id;
    _showing = id;
    unawaited(
      showDialog<void>(
        context: uiContext,
        barrierDismissible: false,
        builder: (_) => LinkedMountUnparkDialog(startId: id),
      ).whenComplete(() {
        if (_showing == id) _showing = null;
      }),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
