import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

/// Safe the rig as the desktop app shuts down, when this app owns the rig.
///
/// A linked client owns no hardware: its rig is the host's, and closing the
/// viewer must not park the host's mount, end its exposure or close its dome.
/// Disconnected (UI-only) mode has nothing to safe either. Returns whether
/// safing ran.
Future<bool> safeRigForDesktopShutdown(ProviderContainer container) async {
  if (!container.read(backendProvider).runsRigHere) return false;
  await container
      .read(safeRigServiceProvider)
      .safeTheRig(
        reason: 'Skotiq is shutting down',
        park: true,
        // Quitting is not a reason to move an idle mount: it parks only
        // when a run was in progress.
        idleMount: IdleMountPolicy.leave,
        closeDome: true,
        closeCover: true,
        abortExposure: true,
        disableCooling: true,
        notify: false,
      );
  return true;
}
