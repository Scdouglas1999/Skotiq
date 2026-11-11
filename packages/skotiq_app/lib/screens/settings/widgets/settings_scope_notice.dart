import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../settings_sections.dart';

/// On a linked client, one line above a Settings section saying whose
/// settings these are. Shows nothing on the machine that owns the rig.
class SettingsScopeNotice extends ConsumerWidget {
  const SettingsScopeNotice({super.key, required this.section});

  final SettingsSectionId section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(backendProvider);
    final linkedHost = backend.remoteHost;
    if (linkedHost == null) return const SizedBox.shrink();
    final colors = SkotiqColors.of(context);
    final onHost = !section.onThisDevice;
    final text = onHost
        ? 'Saved on the imaging host (${linkedHost.link.serverHost}). A change '
            'here changes the rig for everyone linked to it.'
        : 'Saved on this device only. The imaging host keeps its own.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceLg,
        0,
      ),
      child: Semantics(
        container: true,
        label: text,
        excludeSemantics: true,
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
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
