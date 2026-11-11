import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../link_rig/link_rig_dialog.dart';

/// What a linked client says where the imaging host lets only a link with
/// admin access act: credentials, backups, plugins, updates, clearing logs,
/// catalogs and the host's folders.
const String adminOnlyAdvice =
    'Change this on the imaging computer, or link with admin access.';

/// True on a linked client whose link the imaging host says lacks admin
/// access. False on the host itself, and while the host has not said.
bool hostRefusesAdminOnly(WidgetRef ref) =>
    ref.watch(hostAdminAccessProvider).valueOrNull == false;

/// [child], or on a linked client without admin access, the line saying where
/// to change it instead.
class AdminOnlyControl extends ConsumerWidget {
  const AdminOnlyControl({
    super.key,
    required this.child,
    this.text = adminOnlyAdvice,
  });

  final Widget child;

  /// What the line says in its place.
  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      hostRefusesAdminOnly(ref) ? AdminOnlyNotice(text: text) : child;
}

/// The line that stands in for an admin-only control in a settings row.
class AdminOnlyNotice extends ConsumerWidget {
  const AdminOnlyNotice({super.key, this.text = adminOnlyAdvice});

  /// The advice, or for an action rather than a value, a sentence naming it:
  /// "Clear logs on the imaging computer, or link with admin access."
  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final relink = _relinkWithAdminAccess(context, ref);
    return Column(
      key: const ValueKey('adminOnly.notice'),
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                LucideIcons.lock,
                size: SkotiqTokens.iconXs,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.end,
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
        if (relink != null)
          SkotiqButton(
            key: const ValueKey('adminOnly.relink'),
            label: 'Link with admin access',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: relink,
          ),
      ],
    );
  }
}

/// A whole card or page the imaging host keeps for links with admin access,
/// said once in place of its controls.
class AdminOnlyBanner extends ConsumerWidget {
  const AdminOnlyBanner({super.key, required this.title});

  /// What is kept on the imaging computer, as a sentence:
  /// "Backups are made on the imaging computer".
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final relink = _relinkWithAdminAccess(context, ref);
    return SkotiqBanner(
      key: const ValueKey('adminOnly.banner'),
      title: title,
      message: adminOnlyAdvice,
      icon: LucideIcons.lock,
      action: relink == null
          ? null
          : SkotiqButton(
              key: const ValueKey('adminOnly.relink'),
              label: 'Link with admin access',
              icon: LucideIcons.keyRound,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: relink,
            ),
    );
  }
}

/// Opens the code pairing that grants admin access, where this app linked to
/// the host itself. A phone, or a launch linked by flags, has no remembered
/// link to repair here.
VoidCallback? _relinkWithAdminAccess(BuildContext context, WidgetRef ref) {
  final rig = ref.watch(launchLinkedRigProvider);
  if (rig == null) return null;
  return () => unawaited(
        showLinkRigDialog(
          context,
          request:
              LinkRigRequest.repair(rig, preferCode: true, fullAccess: true),
        ),
      );
}
