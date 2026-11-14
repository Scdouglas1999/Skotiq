import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show loadedDsosProvider, loadedStarsProvider;
import 'package:skotiq_astro/skotiq_astro.dart' show CelestialObject;

import '../../../localization/skotiq_localizations.dart';
import '../../../router/show_in_sky.dart';
import '../../settings/settings_catalog.dart';
import '../../equipment/utils/connect_all_action.dart';
import '../../settings/settings_search_index.g.dart';
import '../../../router/app_routes.dart';
import '../../../router/planner_route.dart';
import '../shell_navigation.dart';
import '../../../services/mount_command_service.dart';
import '../../../services/sequence_action_service.dart';
import 'command_entry.dart';

/// Every rail destination, every Settings section, and the screens that own a
/// route but no rail slot.
///
/// That last set is the point of the group: Polar alignment, Session review,
/// Mosaic, Pairing and Diagnostics are reachable from inside other screens and
/// from deep links, and the rail deliberately does not carry them. The palette
/// is how an operator who knows the screen exists gets to it.
List<CommandEntry> buildScreenEntries(BuildContext context) {
  final l10n = context.l10n;
  final entries = <CommandEntry>[
    for (final route in [
      ...ShellNavigation.rail,
      for (final route in AppRoute.values)
        if (route.palette && route.group == null) route,
    ])
      CommandEntry(
        id: 'screen:${route.path}',
        group: CommandGroup.screens,
        icon: route.icon!,
        label: route.label!.of(l10n),
        keywords: route.keywords,
        invoke: (context, ref) => context.go(route.path),
      ),
  ];

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
          invoke: (context, ref) => openSettings(context, section.id),
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
          invoke: (context, ref) =>
              openSettings(context, SettingsSectionId.resolve(sectionKey)),
        ),
      );
    }
  });
  return entries;
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

const int _maxTargetEntries = 8;

String _normalizeDesignation(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'\s+'), '');

typedef TargetSearchIndex = ({
  List<_SearchableTarget> dsos,
  List<_SearchableTarget> stars,
});

/// One catalog object as the palette searches it.
class _SearchableTarget {
  const _SearchableTarget({
    required this.object,
    required this.label,
    required this.designations,
    required this.names,
  });

  final CelestialObject object;
  final String label;

  /// Its catalog designations, lower-cased and without spaces.
  final List<String> designations;

  /// Its name and common names, lower-cased; a star's proper name.
  final List<String> names;
}

/// The installed catalogs as the palette searches them, built once per
/// catalog load.
///
/// A keystroke used to walk both catalogs (some 13,000 objects and 118,000
/// stars), normalizing every designation with a regular expression and
/// lower-casing every name: 50 to 100 ms on the UI isolate per letter typed.
/// Only the 400 or so stars that have a name can be found, so the rest are
/// not kept.
final targetSearchIndexProvider = Provider<TargetSearchIndex>((ref) {
  final dsos = ref.watch(loadedDsosProvider).valueOrNull ?? const [];
  final stars = ref.watch(loadedStarsProvider).valueOrNull ?? const [];
  return (
    dsos: [
      for (final dso in dsos)
        () {
          final common = dso.commonNames;
          final designation =
              dso.name == dso.id ? dso.id : '${dso.name} (${dso.id})';
          final firstCommon = common?.split(',').first.trim();
          return _SearchableTarget(
            object: dso,
            label: firstCommon != null &&
                    firstCommon.isNotEmpty &&
                    firstCommon != dso.name
                ? '$designation · $firstCommon'
                : designation,
            designations: [
              _normalizeDesignation(dso.id),
              for (final id in dso.catalogIds) _normalizeDesignation(id),
            ],
            names: [
              dso.name.toLowerCase(),
              if (common != null) common.toLowerCase(),
            ],
          );
        }(),
    ],
    stars: [
      for (final star in stars)
        if (star.name.isNotEmpty)
          _SearchableTarget(
            object: star,
            label: star.name,
            designations: const [],
            names: [star.name.toLowerCase()],
          ),
    ],
  );
});

/// Deep-sky objects and named stars from the installed catalogs that match
/// [query]. Choosing one opens it in Framing, or, [inSky] (the planetarium on
/// screen), centers the sky on it; Shift+Enter does the other.
///
/// Designations match with or without spaces ("NGC 891", "ngc891", "M31"),
/// common names by substring, and stars by their proper name. Nothing is
/// listed before two characters are typed or while the catalogs load.
List<CommandEntry> buildTargetEntries(
  WidgetRef ref,
  String query, {
  bool inSky = false,
}) {
  final normalized = _normalizeDesignation(query);
  if (normalized.length < 2) return const [];
  final index = ref.read(targetSearchIndexProvider);

  final found = <(int, CelestialObject, String)>[];
  for (final dso in index.dsos) {
    final exact = dso.designations.contains(normalized);
    final prefix =
        !exact && dso.designations.any((id) => id.startsWith(normalized));
    final byName =
        normalized.length >= 3 && dso.names.any((name) => name.contains(query));
    if (!exact && !prefix && !byName) continue;
    found.add((exact ? 0 : (prefix ? 1 : 2), dso.object, dso.label));
  }
  if (normalized.length >= 3) {
    for (final star in index.stars) {
      final name = star.names.first;
      if (!name.startsWith(query)) continue;
      found.add((name == query ? 0 : 1, star.object, star.label));
    }
  }
  found.sort((a, b) {
    final byMatch = a.$1.compareTo(b.$1);
    if (byMatch != 0) return byMatch;
    return (a.$2.magnitude ?? 99).compareTo(b.$2.magnitude ?? 99);
  });

  return [
    for (final (_, object, label) in found.take(_maxTargetEntries))
      CommandEntry(
        id: 'target:${object.id}',
        group: CommandGroup.targets,
        icon: LucideIcons.crosshair,
        label: label,
        hint: inSky
            ? 'Show in sky · Shift+Enter: Framing'
            : 'Open in Framing · Shift+Enter: sky',
        // Matched here already; the query must not filter these out again
        // when the label shows a different designation than the one typed.
        keywords: [query],
        invoke: inSky ? _showInSky(object) : _openInFraming(object),
        invokeAlternate: inSky ? _openInFraming(object) : _showInSky(object),
      ),
  ];
}

void Function(BuildContext, WidgetRef) _openInFraming(CelestialObject object) =>
    (context, ref) {
      ref.read(framingProvider.notifier).setTargetCoordinates(
            object.coordinates.ra,
            object.coordinates.dec,
            name: object.name,
          );
      context.go(AppRoutes.planner(tab: PlannerTab.framing));
    };

void Function(BuildContext, WidgetRef) _showInSky(CelestialObject object) =>
    (context, ref) => showTargetInSky(
          context,
          ref,
          raHours: object.coordinates.ra,
          decDegrees: object.coordinates.dec,
          name: object.name,
        );
