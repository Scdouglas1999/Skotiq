import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Where a Settings section's values live on a linked client.
enum SettingsScope { imagingHost, thisDevice }

/// Sections whose values belong to the device showing them: its look, its
/// own link to the host, its help and its own app version. Every other
/// section reads and writes the imaging host's settings.
const Set<String> _thisDeviceSections = {
  'appearance',
  'connection',
  'help',
  'about',
  'updates',
  'replay-debug',
};

SettingsScope settingsScopeFor(String sectionKey) =>
    _thisDeviceSections.contains(sectionKey)
        ? SettingsScope.thisDevice
        : SettingsScope.imagingHost;

/// On a linked client, one line above a Settings section saying whose
/// settings these are. Shows nothing on the machine that owns the rig.
class SettingsScopeNotice extends ConsumerWidget {
  const SettingsScopeNotice({super.key, required this.sectionKey});

  final String sectionKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(backendProvider);
    if (backend is! NetworkBackend) return const SizedBox.shrink();
    final colors = SkotiqColors.of(context);
    final onHost = settingsScopeFor(sectionKey) == SettingsScope.imagingHost;
    final text = onHost
        ? 'Saved on the imaging host (${backend.serverHost}). A change here '
            'changes the rig for everyone linked to it.'
        : 'Saved on this computer only. The imaging host keeps its own.';
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
