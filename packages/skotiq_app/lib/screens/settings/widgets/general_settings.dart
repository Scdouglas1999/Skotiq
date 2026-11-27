import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';

import '../../../localization/skotiq_localizations.dart';
import 'settings_widgets.dart';

class GeneralSettings extends ConsumerWidget {
  const GeneralSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    final l10n = context.l10n;

    return settingsAsync.when(
      loading: () => const SettingsLoadingState(),
      error: (error, stack) => SettingsErrorState(
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) => SettingsPage(
        title: l10n.text('generalTitle'),
        description: l10n.text('generalDescription'),
        children: [
          SettingsSection(
            title: l10n.text('generalStartup'),
            children: [
              // `start_minimized` is intentionally non-remotable (host-only);
              // hide the row over a remote session so it can't throw.
              if (!isRemoteMode)
                SettingRow(
                  title: l10n.text('generalStartMinimized'),
                  subtitle: l10n.text('generalStartMinimizedDesc'),
                  trailing: SettingsSwitch(
                    value: settings.startMinimized,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setStartMinimized(value);
                    },
                  ),
                ),
              SettingRow(
                title: l10n.text('generalAutoConnect'),
                subtitle: l10n.text('generalAutoConnectDesc'),
                trailing: SettingsSwitch(
                  value: settings.autoConnectEquipment,
                  onChanged: (value) {
                    return ref
                        .read(appSettingsProvider.notifier)
                        .setAutoConnectEquipment(value);
                  },
                ),
              ),
            ],
          ),
          // `confirm_before_closing` is intentionally non-remotable
          // (host-only); hide it over a remote session. Language is on the
          // Appearance page: each device keeps its own.
          if (!isRemoteMode)
            SettingsSection(
              title: l10n.text('generalBehavior'),
              children: [
                SettingRow(
                  title: l10n.text('generalConfirmBeforeClosing'),
                  subtitle: l10n.text('generalConfirmBeforeClosingDesc'),
                  trailing: SettingsSwitch(
                    value: settings.confirmBeforeClosing,
                    onChanged: (value) {
                      return ref
                          .read(appSettingsProvider.notifier)
                          .setConfirmBeforeClosing(value);
                    },
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
