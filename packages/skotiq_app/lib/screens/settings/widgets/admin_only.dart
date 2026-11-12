import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../link_rig/link_rig_dialog.dart';

/// What a linked client says where the imaging host lets only a link with
/// admin access act: credentials, the programs it runs, backups, plugins,
/// updates, clearing logs, catalogs and the host's folders.
const String adminOnlyAdvice =
    'Change this on the imaging computer, or link with admin access.';

/// The admin-only line for a credential: whether it is set, which is all the
/// host tells a link without admin access ([credentialSetMarker]).
String adminOnlyCredentialAdvice(String value) => value.isEmpty
    ? 'Not set. Set it on the imaging computer, or link with admin access.'
    : 'Set. Change it on the imaging computer, or link with admin access.';

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
///
/// Where this app linked to the host itself, its closing "link with admin
/// access" opens the code pairing that grants it.
class AdminOnlyNotice extends ConsumerWidget {
  const AdminOnlyNotice({super.key, this.text = adminOnlyAdvice});

  /// The advice, or for an action rather than a value, a sentence naming it:
  /// "Clear the logs on the imaging computer, or link with admin access."
  final String text;

  static const String _linkPhrase = 'link with admin access';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final relink = _relinkWithAdminAccess(context, ref);
    final style = SkotiqTypography.caption.copyWith(
      color: colors.textSecondary,
    );
    final at = text.lastIndexOf(_linkPhrase);
    final words = relink == null || at < 0
        ? Text(text, textAlign: TextAlign.end, style: style)
        : Text.rich(
            TextSpan(
              children: [
                TextSpan(text: text.substring(0, at)),
                TextSpan(
                  text: _linkPhrase,
                  style: style.copyWith(
                    color: colors.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: colors.primary,
                  ),
                ),
                TextSpan(text: text.substring(at + _linkPhrase.length)),
              ],
            ),
            textAlign: TextAlign.end,
            style: style,
          );
    final line = Row(
      key: const ValueKey('adminOnly.notice'),
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
        Flexible(child: words),
      ],
    );
    if (relink == null) return line;
    return Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      onTap: relink,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('adminOnly.relink'),
          behavior: HitTestBehavior.opaque,
          onTap: relink,
          child: line,
        ),
      ),
    );
  }
}

/// A whole card or page the imaging host keeps for links with admin access,
/// said once in place of its controls.
class AdminOnlyBanner extends ConsumerWidget {
  const AdminOnlyBanner({super.key, required this.title});

  /// What is kept on the imaging computer, as a sentence:
  /// "Backups and cloud sync are managed on the imaging computer".
  final String title;

  static const String advice = 'Use Skotiq there, or link with admin access.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final relink = _relinkWithAdminAccess(context, ref);
    return SkotiqBanner(
      key: const ValueKey('adminOnly.banner'),
      title: title,
      message: advice,
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
