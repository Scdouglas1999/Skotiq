import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../../utils/confirm_dialog.dart';
import 'link_rig_dialog.dart';
import '../../utils/snackbar_helper.dart';

/// True when this process can change role at all: a desktop build whose entry
/// point installed a relauncher.
bool canSwitchRole(WidgetRef ref) => ref.watch(appRelauncherProvider) != null;

/// "Use this computer instead": stop launching as the linked client and
/// restart as this computer's own host. The pairing is kept (inactive), so
/// linking again later is one tap with no new pairing.
Future<void> useThisComputerInstead(
  BuildContext context,
  WidgetRef ref, {
  String? rigName,
}) async {
  final relauncher = ref.read(appRelauncherProvider);
  if (relauncher == null) return;
  final name = rigName ?? 'the imaging computer';
  final confirmed = await ConfirmDialog.show(
    context: context,
    title: 'Use this computer instead?',
    message: 'Skotiq restarts and runs the equipment plugged into this '
        'computer. $name stays paired, so you can link to it again later '
        'from Settings > Remote access.',
    confirmLabel: 'Restart',
  );
  if (!confirmed) return;
  final store = ref.read(linkedRigStoreProvider);
  await store.setActive(false);
  ref.invalidate(rememberedRigProvider);
  final restarted = await relauncher.relaunch(
    reason: 'Use this computer instead of $name',
  );
  if (!restarted) {
    // The quit was cancelled: this window keeps running linked, so the record
    // must say so too, or the next launch would silently change role.
    await store.setActive(true);
    ref.invalidate(rememberedRigProvider);
  }
}

/// Link again to a rig kept after "Use this computer instead". Reuses the
/// stored token when the host still accepts it; otherwise opens pairing.
Future<void> linkRememberedRig(
  BuildContext context,
  WidgetRef ref,
  LinkedRig rig,
) async {
  final store = ref.read(linkedRigStoreProvider);
  final token = await store.readToken();
  final outcome = token == null
      ? ServerProbeOutcome.authRejected
      : await ref
          .read(rigLinkServiceProvider)
          .checkToken(rig.host, rig.port, token, scheme: rig.scheme);
  if (!context.mounted) return;
  switch (outcome) {
    case ServerProbeOutcome.reachable:
      await store.setActive(true);
      ref.invalidate(rememberedRigProvider);
      final restarted = await ref
              .read(appRelauncherProvider)
              ?.relaunch(reason: 'Linked to ${rig.name}') ??
          false;
      if (!restarted) {
        await store.setActive(false);
        ref.invalidate(rememberedRigProvider);
      }
    // The dialog asks the host who it is now and, for another release,
    // says which side to update.
    case ServerProbeOutcome.authRejected || ServerProbeOutcome.incompatible:
      await showLinkRigDialog(context, request: LinkRigRequest.repair(rig));
    case ServerProbeOutcome.unreachable:
      context.showErrorSnackBar(
        "Can't reach ${rig.name} at ${rig.address}. Check that Skotiq is "
        'open there with Remote access on.',
      );
  }
}

/// Forget the remembered rig entirely (record and token).
Future<void> forgetRememberedRig(
  BuildContext context,
  WidgetRef ref,
  LinkedRig rig,
) async {
  final confirmed = await ConfirmDialog.show(
    context: context,
    title: 'Forget ${rig.name}?',
    message: 'This computer deletes its pairing with ${rig.name}. Linking '
        'again needs a new pairing. To remove this computer from the list on '
        '${rig.name} too, use its Paired devices list.',
    confirmLabel: 'Forget',
    isDestructive: true,
  );
  if (!confirmed) return;
  await ref.read(linkedRigStoreProvider).forget();
  ref.invalidate(rememberedRigProvider);
}
