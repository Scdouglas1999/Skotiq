import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../screens/equipment/dialogs/fujifilm_disclaimer_dialog.dart';
import '../utils/startup_surface_queue.dart';
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
  /// How many frames to wait for the Navigator before giving up.
  static const _maxNavigatorWaits = 30;

  bool _shown = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<CameraStateSnapshot>(
      cameraStateProvider,
      (previous, next) {
        if (previous?.connectionState != DeviceConnectionState.connected) {
          _check(next);
        }
      },
      // A camera auto-connect brought up before this mounted counts too.
      fireImmediately: true,
    );
  }

  void _check(CameraStateSnapshot camera, {int waits = 0}) {
    if (_shown || !mounted) return;
    if (camera.connectionState != DeviceConnectionState.connected) return;
    final deviceId = camera.deviceId;
    if (deviceId == null || !isFujifilmDevice(deviceId, camera.deviceName)) {
      return;
    }
    final uiContext = resolveStartupUiContext(ref, context);
    if (uiContext == null || !uiContext.mounted) {
      // The router has not built its Navigator yet; try again next frame.
      if (waits >= _maxNavigatorWaits) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _check(ref.read(cameraStateProvider), waits: waits + 1);
      });
      return;
    }
    _shown = true;
    unawaited(
      ref.read(startupSurfaceQueueProvider).run(
            () => showFujifilmNoticeAfterConnect(uiContext),
          ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
