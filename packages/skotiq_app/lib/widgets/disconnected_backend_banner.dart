import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show DiscoveredServer;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../localization/skotiq_localizations.dart';
import '../screens/link_rig/link_rig_actions.dart';
import '../screens/link_rig/link_rig_dialog.dart';
import 'work_locally.dart';

/// Full-width banner shown while no backend is installed.
///
/// Desktop can restore its local backend directly; client-only platforms do
/// not offer that action. A process launched as a companion of an imaging host
/// instead names the host, says why it is not connected, and offers Retry.
class DisconnectedBackendBanner extends ConsumerWidget {
  const DisconnectedBackendBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(sequencerBackendProvider) is! DisconnectedBackend) {
      return const SizedBox.shrink();
    }

    final remoteTarget = ref.watch(remoteLaunchTargetProvider);
    if (remoteTarget != null) {
      return _RemoteHostUnavailableBanner(target: remoteTarget);
    }

    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    return Material(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.text('disconnectedBanner'),
                textAlign: canWorkLocally ? TextAlign.start : TextAlign.center,
                style: SkotiqTypography.labelQuiet.copyWith(
                  color: colors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (canWorkLocally)
              const WorkLocallyButton(
                variant: ButtonVariant.destructive,
              ),
          ],
        ),
      ),
    );
  }
}

class _RemoteHostUnavailableBanner extends ConsumerWidget {
  const _RemoteHostUnavailableBanner({required this.target});

  final RemoteLaunchTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final status = ref.watch(remoteLaunchStatusProvider);
    final connecting = status.phase == RemoteLaunchPhase.connecting;
    final failure = status.failure;

    final rig = ref.watch(launchLinkedRigProvider);
    final canSwitch = canSwitchRole(ref);
    final retrySeconds = RemoteLaunchStatusNotifier.autoRetryInterval.inSeconds;

    final String title;
    final String hint;
    if (connecting || failure == null) {
      title = 'Connecting to the imaging host at ${target.label}…';
      hint = '';
    } else {
      title = remoteLaunchFailureMessage(target, failure);
      hint = switch (failure) {
        RemoteLaunchFailure.unreachable =>
          'Check that Skotiq is running on the host and that both machines '
              'are on the same network. Retrying every $retrySeconds s.',
        RemoteLaunchFailure.tokenRejected => canSwitch
            ? "This computer's pairing was removed on the host or has "
                'expired. Pair again to keep using it from here.'
            : 'Pair this companion with the host again (Settings > Remote '
                'access on the host).',
        RemoteLaunchFailure.refused =>
          'Both machines may need the same Skotiq version.',
        RemoteLaunchFailure.hostChanged =>
          'Its identity does not match the computer this one paired with, so '
              'the access token was not sent. Pair again if Skotiq was '
              'reinstalled there.',
      };
    }

    final needsPairing = failure == RemoteLaunchFailure.tokenRejected ||
        failure == RemoteLaunchFailure.hostChanged;
    final actions = <Widget>[
      if (!connecting && needsPairing && canSwitch)
        SkotiqButton(
          key: const ValueKey('remoteBanner.pairAgain'),
          label: 'Pair again',
          icon: LucideIcons.link,
          size: ButtonSize.small,
          onPressed: () => showLinkRigDialog(
            context,
            request: rig != null
                ? LinkRigRequest.repair(rig)
                : LinkRigRequest.pair(
                    DiscoveredServer(
                      host: target.host,
                      webPort: target.port,
                      name: target.name ?? target.host,
                      scheme: target.scheme,
                    ),
                    refresh: true,
                  ),
          ),
        )
      else if (!needsPairing || !canSwitch)
        SkotiqButton(
          label: connecting ? 'Connecting…' : 'Retry',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: connecting
              ? null
              : () => ref.read(remoteLaunchStatusProvider.notifier).connect(),
        ),
      // Offered from the first failed attempt on: an unreachable rig must
      // never leave this computer unusable until it comes back.
      if (canSwitch && (failure != null || !connecting))
        SkotiqButton(
          key: const ValueKey('remoteBanner.useThisComputer'),
          label: 'Use this computer instead',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () =>
              useThisComputerInstead(context, ref, rigName: target.name),
        ),
    ];

    return Material(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceMd,
          vertical: SkotiqTokens.spaceSm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: SkotiqTypography.labelQuiet.copyWith(
                      color: connecting ? colors.textSecondary : colors.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (hint.isNotEmpty)
                    Text(
                      hint,
                      style: SkotiqTypography.labelQuiet.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceXs,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }
}
