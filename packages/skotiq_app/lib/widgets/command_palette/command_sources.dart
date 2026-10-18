import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../localization/skotiq_localizations.dart';
import '../../screens/settings/settings_catalog.dart';
import '../../screens/settings/settings_screen.dart'
    show SettingsSectionRequest;
import '../../screens/equipment/utils/connect_all_action.dart';
import '../../screens/settings/settings_search_index.g.dart';
import '../../screens/shell/shell_navigation.dart';
import '../../services/mount_command_service.dart';
import '../../services/sequence_action_service.dart';
import 'command_entry.dart';

/// Every rail destination, every Settings section, and the screens that own a
/// route but no rail slot.
///
/// That last set is the point of the group: `/polar-alignment`,
/// `/flat-wizard`, `/session-review`, `/mosaic`, `/pairing` and `/diagnostics`
/// are reachable from inside other screens and from deep links, and the rail
/// deliberately does not carry nine more items to name them. The palette is
/// how an operator who knows the screen exists gets to it.
List<CommandEntry> buildScreenEntries(BuildContext context) {
  final l10n = context.l10n;
  final entries = <CommandEntry>[];

  void screen({
    required String id,
    required IconData icon,
    required String label,
    required String route,
    String? hint,
    List<String> keywords = const [],
  }) {
    entries.add(
      CommandEntry(
        id: id,
        group: CommandGroup.screens,
        icon: icon,
        label: label,
        hint: hint,
        keywords: keywords,
        invoke: (context, ref) => context.go(route),
      ),
    );
  }

  for (final dest in ShellNavigation.primaryDestinations) {
    screen(
      id: 'screen:${dest.route}',
      icon: dest.icon,
      label: dest.label(l10n),
      route: dest.route,
    );
  }

  screen(
    id: 'screen:/settings',
    icon: ShellNavigation.settings.icon,
    label: ShellNavigation.settings.label(l10n),
    route: ShellNavigation.settings.route,
  );

  // Route-only screens (04 §7). Each keeps the label the screen itself uses.
  screen(
    id: 'screen:/polar-alignment',
    icon: LucideIcons.compass,
    label: 'Polar alignment',
    route: '/polar-alignment',
    keywords: const ['polar', 'align', 'drift', 'tppa'],
  );
  screen(
    id: 'screen:/flat-wizard',
    icon: LucideIcons.sun,
    label: l10n.text('navFlatWizard'),
    route: '/flat-wizard',
    keywords: const ['flat', 'calibration', 'wizard'],
  );
  screen(
    id: 'screen:/session-review',
    icon: LucideIcons.clipboardList,
    label: 'Session review',
    route: '/session-review',
    keywords: const ['session', 'review', 'night', 'report'],
  );
  screen(
    id: 'screen:/mosaic',
    icon: LucideIcons.layoutGrid,
    label: 'Mosaic',
    route: '/mosaic',
    keywords: const ['mosaic', 'panel', 'tile'],
  );
  screen(
    id: 'screen:/pairing',
    icon: LucideIcons.smartphone,
    label: 'Pairing',
    route: '/pairing',
    keywords: const ['pair', 'phone', 'remote', 'device'],
  );
  screen(
    id: 'screen:/diagnostics',
    icon: LucideIcons.stethoscope,
    label: 'Diagnostics',
    route: '/diagnostics',
    keywords: const ['diagnostics', 'logs', 'dump', 'support'],
  );

  // Settings sections are screens too: they are where you GO, as opposed to
  // the individual settings in the Settings group, which are what you change.
  for (final group in buildSettingsGroups(context)) {
    for (final section in group.sections) {
      entries.add(
        CommandEntry(
          id: 'settings-section:${section.key}',
          group: CommandGroup.screens,
          icon: section.icon,
          label: section.label,
          hint: group.displayTitle,
          keywords: section.keywords,
          invoke: (context, ref) => _openSettingsSection(context, section.key),
        ),
      );
    }
  }

  return entries;
}

/// Individual settings, from the generated index.
///
/// Only entries that MATCH are built, and only once the operator has typed:
/// the index holds several hundred row titles, and listing them unfiltered
/// would bury the nine screens the palette exists to reach. The rows come from
/// `settings_search_index.g.dart`, which is generated from what each section
/// actually renders, so typing a setting's visible name finds it.
List<CommandEntry> buildSettingEntries(BuildContext context, String query) {
  if (query.isEmpty) return const [];
  final entries = <CommandEntry>[];
  final sectionLabels =
      <String, ({String label, IconData icon, String group})>{};
  for (final group in buildSettingsGroups(context)) {
    for (final section in group.sections) {
      sectionLabels[section.key] = (
        label: section.label,
        icon: section.icon,
        group: group.displayTitle,
      );
    }
  }

  kSettingsSearchTerms.forEach((sectionKey, terms) {
    final section = sectionLabels[sectionKey];
    if (section == null) return;
    final rowTitles = kSettingsSearchRowTitles[sectionKey] ?? const {};
    final listed = <String>{};
    for (final term in terms) {
      if (!term.toLowerCase().contains(query)) continue;
      // A row's description is indexed so it can be FOUND by, but it names
      // the same setting as the row's title; listing both showed "Polar
      // alignment stale after" and "If the last polar alignment is older
      // than" as two results for one control.
      final label = rowTitles[term] ?? term;
      if (!listed.add(label.toLowerCase())) continue;
      // The section's own title is already a Screens row; a duplicate here
      // would put the same destination on screen twice under two headings.
      if (label.toLowerCase() == section.label.toLowerCase()) continue;
      entries.add(
        CommandEntry(
          id: 'setting:$sectionKey:$label',
          group: CommandGroup.settings,
          icon: section.icon,
          label: label,
          hint: section.label,
          keywords: label == term ? const [] : [term],
          invoke: (context, ref) => _openSettingsSection(context, sectionKey),
        ),
      );
    }
  });
  return entries;
}

/// Deep-link into a Settings section.
///
/// Raised as an EVENT as well as a route, because a second invocation while
/// Settings is already open carries an identical route and would otherwise
/// move nothing. This is the same pair the top bar's Settings shortcut used.
void _openSettingsSection(BuildContext context, String sectionKey) {
  SettingsSectionRequest.raise(sectionKey);
  context.go('/settings?section=$sectionKey');
}

/// The things the palette DOES.
///
/// Every one of these calls the same service the screen's own button calls —
/// `SequenceActionService`, `MountCommandService`, `ImagingService`,
/// `runConnectAllForProfile` — rather than re-deriving the operation. A second
/// implementation of "stop the sequence" is a second thing that can be wrong
/// about whether the hardware stopped.
List<CommandEntry> buildActionEntries(BuildContext context, WidgetRef ref) {
  final l10n = context.l10n;
  final executionState = ref.watch(sequenceExecutionStateProvider);
  final mountConnected = ref.watch(mountStateProvider).connectionState ==
      DeviceConnectionState.connected;
  final cameraState = ref.watch(cameraStateProvider);
  final cameraConnected =
      cameraState.connectionState == DeviceConnectionState.connected;
  final profile = ref.watch(activeEquipmentProfileProvider);

  final isRunning = executionState == SequenceExecutionState.running ||
      executionState == SequenceExecutionState.paused ||
      executionState == SequenceExecutionState.recovering;

  return [
    CommandEntry(
      id: 'action:sequence-start',
      group: CommandGroup.actions,
      icon: LucideIcons.play,
      label: 'Start sequence',
      enabled: !isRunning,
      disabledReason: isRunning ? 'Already running' : null,
      keywords: const ['run', 'begin', 'sequence'],
      invoke: (context, ref) => ref.read(sequenceActionServiceProvider).start(),
    ),
    CommandEntry(
      id: 'action:sequence-stop',
      group: CommandGroup.actions,
      icon: LucideIcons.square,
      label: 'Stop sequence',
      enabled: isRunning,
      disabledReason: isRunning ? null : 'Nothing is running',
      keywords: const ['halt', 'abort', 'sequence'],
      invoke: (context, ref) => ref.read(sequenceActionServiceProvider).stop(),
    ),
    CommandEntry(
      id: 'action:connect-all',
      group: CommandGroup.actions,
      icon: LucideIcons.plug,
      label: 'Connect all',
      hint: profile?.name,
      enabled: profile != null,
      disabledReason: profile == null ? 'No active profile' : null,
      keywords: const ['equipment', 'devices', 'attach'],
      invoke: (context, ref) {
        final active = ref.read(activeEquipmentProfileProvider);
        if (active == null) return;
        runConnectAllForProfile(context, ref, active);
      },
    ),
    CommandEntry(
      id: 'action:park',
      group: CommandGroup.actions,
      icon: LucideIcons.parkingCircle,
      label: l10n.text('park'),
      enabled: mountConnected,
      disabledReason: mountConnected ? null : 'No mount connected',
      keywords: const ['mount', 'stow', 'home'],
      invoke: (context, ref) => ref.read(mountCommandServiceProvider).park(),
    ),
    CommandEntry(
      id: 'action:snapshot',
      group: CommandGroup.actions,
      icon: LucideIcons.camera,
      label: l10n.text('snapshot'),
      enabled: cameraConnected && !cameraState.isExposing,
      disabledReason: !cameraConnected
          ? 'No camera connected'
          : cameraState.isExposing
              ? 'Already exposing'
              : null,
      keywords: const ['capture', 'expose', 'frame', 'single'],
      invoke: (context, ref) => ref
          .read(imagingServiceProvider)
          .captureImage(settings: ref.read(exposureSettingsProvider)),
    ),
  ];
}
