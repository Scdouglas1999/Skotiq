import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../screens/equipment/dialogs/fujifilm_disclaimer_dialog.dart';
import 'startup_ui_context.dart';

/// Shows the Fujifilm notice once after a Fujifilm camera connected without
/// anyone being asked: auto-connect at launch connects every camera of the
/// profile and never waits on a question. A connect the operator started
/// asked before it began, which already recorded the notice.
class FujifilmNoticeAfterConnect extends ConsumerStatefulWidget {
  const FujifilmNoticeAfterConnect({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<FujifilmNoticeAfterConnect> createState() =>
      _FujifilmNoticeAfterConnectState();
}

class _FujifilmNoticeAfterConnectState
    extends ConsumerState<FujifilmNoticeAfterConnect> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<CameraStateSnapshot>(cameraStateProvider, (
      previous,
      next,
    ) {
      final connectedNow =
          next.connectionState == DeviceConnectionState.connected &&
              previous?.connectionState != DeviceConnectionState.connected;
      if (!connectedNow || _shown) return;
      if (!isFujifilmDevice(next.deviceId ?? '', next.deviceName ?? '')) {
        return;
      }
      final uiContext = resolveStartupUiContext(ref, context);
      if (uiContext == null || !uiContext.mounted) return;
      _shown = true;
      unawaited(showFujifilmNoticeAfterConnect(uiContext));
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
