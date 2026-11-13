import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

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
    final text = onHost
        ? 'Saved on the imaging host (${linkedHost.link.serverHost}). A change '
            'here changes the rig for everyone linked to it.'
        : 'Saved on this device only. The imaging host keeps its own.';
    return Padding(
      padding: padding,
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
