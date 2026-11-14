import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'link_rig_actions.dart';
import 'link_rig_dialog.dart';

/// The top of Settings > Remote access on a desktop: which computer runs the
/// rig, and the controls to change that.
///
/// * On a linked desktop: the imaging computer's name, the link's state and
///   access, and Pair again / Link with admin access / Use this computer
///   instead.
/// * On a desktop that owns its own equipment: Connect to an imaging computer,
///   plus the rig it linked to before, when there is one.
///
/// Shows nothing where the app cannot change role (mobile, web).
class LinkedRigPanel extends ConsumerWidget {
  const LinkedRigPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!canSwitchRole(ref)) return const SizedBox.shrink();
    final target = ref.watch(remoteLaunchTargetProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      child:
          target != null ? _LinkedCard(target: target) : const _ConnectCard(),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
    this.detail,
    this.actions = const [],
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;
  final String? detail;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              style: SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, children: actions),
          ],
        ],
      ),
    );
  }
}

class _ConnectCard extends ConsumerWidget {
  const _ConnectCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final remembered = ref.watch(rememberedRigProvider).valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          icon: LucideIcons.monitorSmartphone,
          iconColor: colors.primary,
          title: 'Connect to an imaging computer',
          body: 'Run a rig whose camera and mount are plugged into another '
              'computer, as if they were plugged into this one. Skotiq '
              'restarts to link, and starts linked from then on.',
          actions: [
            SkotiqButton(
              key: const ValueKey('linkRig.connect'),
              label: 'Connect',
              icon: LucideIcons.link,
              size: ButtonSize.small,
              onPressed: () => unawaited(showLinkRigDialog(context)),
            ),
          ],
        ),
        if (remembered != null && !remembered.active) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          _Card(
            icon: LucideIcons.history,
            iconColor: colors.textMuted,
            title: 'Linked before: ${remembered.name}',
            body: 'This computer is still paired with ${remembered.name}. '
                'Linking again does not need a new pairing unless it was '
                'removed there.',
            detail: remembered.address,
            actions: [
              SkotiqButton(
                label: 'Link again',
                icon: LucideIcons.link,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () =>
                    unawaited(linkRememberedRig(context, ref, remembered)),
              ),
              SkotiqButton(
                label: 'Forget',
                icon: LucideIcons.trash2,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () =>
                    unawaited(forgetRememberedRig(context, ref, remembered)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _LinkedCard extends ConsumerWidget {
  const _LinkedCard({required this.target});

  final RemoteLaunchTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final rig = ref.watch(launchLinkedRigProvider);
    final status = ref.watch(remoteLaunchStatusProvider);
    final name = rig?.name ?? target.name ?? target.host;
    final live = ref.watch(isRemoteModeProvider) &&
        status.phase != RemoteLaunchPhase.failed;

    final String access;
    if (rig == null) {
      access = 'Linked by launch settings (--remote-host or '
          'SKOTIQ_REMOTE_HOST).';
    } else if (rig.hasFullAccess) {
      access = "Admin access: this computer runs the rig and manages $name's "
          'stored passwords, backups, plugins and updates too.';
    } else {
      access = "This computer runs the rig and changes $name's settings. "
          'Stored passwords, backups, plugins and updates are managed on '
          '$name; pair with a code to manage them from here.';
    }

    return _Card(
      icon: live ? LucideIcons.link : LucideIcons.unlink,
      iconColor: live ? colors.success : colors.warning,
      title: live ? 'Linked to $name' : 'Linked to $name, not connected',
      body: 'The camera, mount and other equipment shown in this window are '
          'the ones plugged into $name. $access',
      detail: target.label == name ? null : '${target.host}:${target.port}',
      actions: [
        if (rig != null && !rig.hasFullAccess)
          SkotiqButton(
            key: const ValueKey('linkRig.fullAccess'),
            label: 'Link with admin access',
            icon: LucideIcons.keyRound,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => unawaited(
              showLinkRigDialog(
                context,
                request: LinkRigRequest.repair(
                  rig,
                  preferCode: true,
                  fullAccess: true,
                ),
              ),
            ),
          ),
        if (rig != null)
          SkotiqButton(
            label: 'Pair again',
            icon: LucideIcons.refreshCw,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => unawaited(
              showLinkRigDialog(context, request: LinkRigRequest.repair(rig)),
            ),
          ),
        SkotiqButton(
          key: const ValueKey('linkRig.useThisComputer'),
          label: 'Use this computer instead',
          icon: LucideIcons.monitor,
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () =>
              unawaited(useThisComputerInstead(context, ref, rigName: name)),
        ),
      ],
    );
  }
}
