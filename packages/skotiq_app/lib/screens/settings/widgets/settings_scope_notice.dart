import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../link_rig/link_rig_dialog.dart';
import '../settings_sections.dart';

/// On a linked client, one line above a Settings section, or above one group
/// of a section that keeps groups in both places, saying whose settings these
/// are. Shows nothing on the machine that owns the rig.
class SettingsScopeNotice extends ConsumerWidget {
  const SettingsScopeNotice({
    super.key,
    required this.onHost,
    this.padding = EdgeInsets.zero,
  });

  /// The line above [section]; nothing for a section that labels each of its
  /// groups.
  static Widget forSection(SettingsSectionId section) {
    const padding = EdgeInsets.fromLTRB(
      SkotiqTokens.spaceLg,
      SkotiqTokens.spaceMd,
      SkotiqTokens.spaceLg,
      0,
    );
    return switch (section.scope) {
      SettingsScope.imagingHost =>
        const SettingsScopeNotice(onHost: true, padding: padding),
      SettingsScope.thisDevice =>
        const SettingsScopeNotice(onHost: false, padding: padding),
      SettingsScope.eachGroup => const SizedBox.shrink(),
    };
  }

  /// Whether these settings are stored on the imaging host rather than on
  /// this device.
  final bool onHost;

  /// Space around the line when it shows.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(backendProvider);
    final linkedHost = backend.remoteHost;
    if (linkedHost == null) return const SizedBox.shrink();
    final colors = SkotiqColors.of(context);
    // A desktop linked with the one-tap pairing holds a control token, which
    // the host refuses for settings writes. Say so before the operator edits
    // anything, and offer the code pairing that grants the access.
    final rig = ref.watch(launchLinkedRigProvider);
    final readOnly = onHost && rig != null && !rig.hasFullAccess;
    final text = readOnly
        ? 'These are the imaging host\'s settings (${rig.name}). This '
            'computer was linked with one tap, so it can view them but '
            '${rig.name} refuses changes from here.'
        : onHost
            ? 'Saved on the imaging host (${linkedHost.link.serverHost}). A change '
                'here changes the rig for everyone linked to it.'
            : 'Saved on this computer only. The imaging host keeps its own.';
    return Padding(
      padding: padding,
      child: Semantics(
        container: true,
        label: readOnly ? null : text,
        // The button must stay reachable, so only the plain notice folds its
        // children into the label.
        excludeSemantics: !readOnly,
        child: Row(
          children: [
            Icon(
              onHost ? LucideIcons.server : LucideIcons.monitor,
              size: 14,
              color: colors.textMuted,
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                text,
                style: SkotiqTypography.labelSm.copyWith(
                  color: readOnly ? colors.warning : colors.textSecondary,
                ),
              ),
            ),
            if (readOnly) ...[
              const SizedBox(width: SkotiqTokens.spaceSm),
              SkotiqButton(
                key: const ValueKey('settingsScope.allowChanges'),
                label: 'Allow changes',
                icon: LucideIcons.keyRound,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () => showLinkRigDialog(
                  context,
                  request: LinkRigRequest.repair(
                    rig,
                    preferCode: true,
                    fullAccess: true,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
