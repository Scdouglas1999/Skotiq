import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

import '../../models/sequence/sequence_models.dart';
import '../../services/logging_service.dart';
import '../profiles_provider.dart';
import '../session_optimizer_provider.dart';
import '../settings_provider.dart';
import 'sequencer_defaults.dart';

/// A plugin-contributed sequence node as the palette shows it, in a top-level
/// "Plugins" category the user drags or double-clicks from like a built-in
/// node.
class PluginNodeBlueprint {
  /// Stable plugin id (mirrors `SkotiqPlugin.id`).
  final String pluginId;

  /// Stable per-plugin node-type id (mirrors `SequenceNodeDefinition.id`).
  final String nodeTypeId;

  /// Human-readable plugin name surfaced in the palette item tooltip.
  final String pluginName;

  /// Display name of the node itself (mirrors `SequenceNodeDefinition.name`).
  final String name;

  /// Plugin-authored description (mirrors `SequenceNodeDefinition.description`).
  final String description;

  /// Category hint from the plugin (mirrors `SequenceNodeDefinition.category`).
  /// Used to group the entry inside the "Plugins" palette section so plugins
  /// that publish multiple nodes don't get one giant flat list.
  final String category;

  /// Icon hint (Lucide icon name). Plugins MAY supply any of the names
  /// understood by the palette widget; unknown icons fall back to the
  /// generic puzzle-piece glyph.
  final String iconHint;

  /// Default opaque JSON config the palette stamps onto a freshly-dropped
  /// node.
  final String defaultConfigJson;

  const PluginNodeBlueprint({
    required this.pluginId,
    required this.nodeTypeId,
    required this.pluginName,
    required this.name,
    required this.description,
    required this.category,
    this.iconHint = 'puzzle',
    this.defaultConfigJson = '{}',
  });

  /// Composite registry key — matches `PluginNodeRegistration.composeKey`.
  String get registrationKey => '$pluginId::$nodeTypeId';
}

/// The sequence nodes of the registered, enabled plugins, updated as plugins
/// load, unload or are switched on and off.
final pluginNodeBlueprintsProvider = Provider<List<PluginNodeBlueprint>>((
  ref,
) {
  final registrations = ref
      .watch(pluginNodeRegistrationsStreamProvider)
      .maybeWhen(
        data: (data) => data,
        orElse: () => ref.read(pluginNodeRegistryProvider).registrations,
      );
  return pluginNodeBlueprints(registrations);
});

/// The palette entries for [registrations]. A registration without a plugin
/// id, node id or name is a broken plugin: it is logged and left out.
List<PluginNodeBlueprint> pluginNodeBlueprints(
  List<PluginNodeRegistration> registrations,
) {
  final out = <PluginNodeBlueprint>[];
  for (final reg in registrations) {
    final definition = reg.definition;
    if (reg.pluginId.isEmpty ||
        definition.id.isEmpty ||
        definition.name.isEmpty) {
      Log.warning(
        'Skipping malformed plugin sequence node registration: '
        'pluginId=${reg.pluginId}, nodeTypeId=${definition.id}, '
        'name=${definition.name}',
        source: 'PluginNodePalette',
      );
      continue;
    }
    out.add(
      PluginNodeBlueprint(
        pluginId: reg.pluginId,
        nodeTypeId: definition.id,
        pluginName: reg.pluginName,
        name: definition.name,
        description: definition.description,
        category: definition.category,
      ),
    );
  }
  return List<PluginNodeBlueprint>.unmodifiable(out);
}

/// Map a profile's integer binning (1..4) to the [BinningMode] enum used by the
/// palette's default factories. Falls back to 1x1 for any unexpected value
/// because the palette must always produce a runnable default.
BinningMode _binningModeFromInt(int binning) {
  switch (binning) {
    case 1:
      return BinningMode.one;
    case 2:
      return BinningMode.two;
    case 3:
      return BinningMode.three;
    case 4:
      return BinningMode.four;
    default:
      return BinningMode.one;
  }
}

final nodePaletteProvider = Provider<List<NodePaletteCategory>>((ref) {
  final defaults = ref.watch(sequencerDefaultsProvider);
  final profile = ref.watch(activeEquipmentProfileProvider);
  final exposureContext = ref
      .watch(smartNightExposureContextProvider)
      .valueOrNull;
  // Read user-tuned adaptive-swap defaults so new
  // TargetScheduler nodes pick up the operator's preferred conditions
  // floor + hysteresis. Falls back to the constructor defaults when
  // settings haven't loaded yet so the palette is never empty.
  final appSettings = ref.watch(appSettingsProvider).valueOrNull;
  final pluginBlueprints = ref.watch(pluginNodeBlueprintsProvider);

  final effectiveGain = defaults.exposureGain ?? profile?.defaultGain;
  final effectiveOffset = defaults.exposureOffset ?? profile?.defaultOffset;
  final effectiveBinning = defaults.exposureBinning != BinningMode.one
      ? defaults.exposureBinning
      : _binningModeFromInt(profile?.defaultBinX ?? 1);
  final effectiveFilter =
      defaults.exposureFilter ?? profile?.filterNames.firstOrNull;
  final effectiveExposureDuration = defaults.isExposureDurationConfigured
      ? defaults.exposureDuration
      : exposureContext?.recommendForFilter(effectiveFilter).seconds ??
            defaults.exposureDuration;

  return [
    NodePaletteCategory(
      name: 'Target',
      icon: 'target',
      items: [
        NodePaletteItem(
          name: 'Target',
          icon: 'target',
          description: 'Root node containing imaging instructions for a target',
          createNode: () => TargetHeaderNode(
            targetName: 'New Target',
            raHours: 0,
            decDegrees: 0,
          ),
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Imaging',
      icon: 'camera',
      items: [
        NodePaletteItem(
          name: 'Take exposures',
          icon: 'camera',
          description: 'Capture images with specified settings',
          createNode: () => ExposureNode(
            durationSecs: effectiveExposureDuration,
            count: defaults.exposureCount,
            filter: effectiveFilter,
            gain: effectiveGain,
            offset: effectiveOffset,
            binning: effectiveBinning,
            ditherEvery: defaults.exposureDitherEvery,
          ),
        ),
        NodePaletteItem(
          name: 'Change filter',
          icon: 'circle',
          description: 'Change the filter wheel position',
          createNode: () =>
              FilterChangeNode(filterName: effectiveFilter ?? 'L'),
        ),
        // SmartExposure — multi-filter container instruction
        // that internally handles filter changes, dither cadence, and
        // rotation order. Adds a single row using the current profile
        // filter so the user has a working starting point.
        NodePaletteItem(
          name: 'Smart exposure',
          icon: 'layers',
          description: 'One row per filter; handles rotation + dither',
          createNode: () => SmartExposureNode(
            plans: [
              FilterPlan(
                filterName: effectiveFilter ?? 'L',
                count: defaults.exposureCount,
                durationSecs: effectiveExposureDuration,
                gain: effectiveGain,
                offset: effectiveOffset,
                binning: effectiveBinning,
                ditherEvery: defaults.exposureDitherEvery,
              ),
            ],
          ),
        ),
        NodePaletteItem(
          name: 'Dither',
          icon: 'shuffle',
          description: 'Dither the guiding for better results',
          createNode: () => DitherNode(
            pixels: defaults.ditherPixels,
            settleTime: defaults.ditherSettleTime,
            settlePixels: defaults.ditherSettlePixels,
            settleTimeout: defaults.ditherSettleTimeout,
            raOnly: defaults.ditherRaOnly,
          ),
        ),
        // LiveStacking — EAA / outreach broadcast node.
        // Defaults pulled from settings so the palette-drop user gets a
        // working private broadcast; flipping
        // to public is an explicit edit in the properties panel.
        NodePaletteItem(
          name: 'Live stacking',
          icon: 'cast_connected',
          description:
              'Broadcast a building live stack to a public/private URL',
          createNode: () => LiveStackingNode(
            stackMethod: defaults.livestackingDefaultStackMethod,
            watermarkText: defaults.livestackingDefaultWatermark,
            // The palette default is *private* (no public access)
            // because public broadcasting at outreach events is the
            // opt-in case, not the default.
            authToken: defaults.livestackingPublicByDefault ? null : '',
          ),
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Science',
      icon: 'lineChart',
      items: [
        NodePaletteItem(
          name: 'Science photometry',
          icon: 'analytics',
          description:
              'Cadence-enforced photometric capture with live reduction',
          createNode: () => SciencePhotometryNode(
            filter: effectiveFilter ?? 'Clear',
            exposureSecs: effectiveExposureDuration,
            gain: effectiveGain,
            offset: effectiveOffset,
            binning: effectiveBinning,
          ),
        ),
        NodePaletteItem(
          name: 'Photometry run (template)',
          icon: 'lineChart',
          description: 'Center, start guiding, then run AAVSO-grade photometry',
          createNode: () => InstructionSetNode(name: 'Photometry run'),
          createChildren: () => [
            CenterNode(),
            StartGuidingNode(
              settlePixels: defaults.ditherSettlePixels,
              settleTime: defaults.ditherSettleTime,
            ),
            SciencePhotometryNode(
              filter: effectiveFilter ?? 'Clear',
              exposureSecs: effectiveExposureDuration,
              gain: effectiveGain,
              offset: effectiveOffset,
              binning: effectiveBinning,
              quality: const PhotometryQualityGates(),
            ),
          ],
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Guiding',
      icon: 'crosshair',
      items: [
        NodePaletteItem(
          name: 'Start guiding',
          icon: 'crosshair',
          description: 'Start the guider and wait for it to settle',
          createNode: () => StartGuidingNode(
            settlePixels: defaults.ditherSettlePixels,
            settleTime: defaults.ditherSettleTime,
          ),
        ),
        NodePaletteItem(
          name: 'Stop guiding',
          icon: 'x-circle',
          description: 'Stop the guider',
          createNode: () => StopGuidingNode(),
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Mount',
      icon: 'compass',
      items: [
        NodePaletteItem(
          name: 'Slew to target',
          icon: 'compass',
          description: 'Slew mount to target coordinates',
          createNode: () => SlewNode(),
        ),
        NodePaletteItem(
          name: 'Center target',
          icon: 'crosshair',
          description: 'Plate solve and center on target',
          createNode: () => CenterNode(),
        ),
        NodePaletteItem(
          name: 'Park mount',
          icon: 'parking-circle',
          description: 'Park the mount',
          createNode: () => ParkNode(),
        ),
        NodePaletteItem(
          name: 'Unpark mount',
          icon: 'unlock',
          description: 'Unpark the mount',
          createNode: () => UnparkNode(),
        ),
        NodePaletteItem(
          name: 'Home mount',
          icon: 'home',
          description: 'Send the mount to its home position without parking it',
          createNode: () => HomeMountNode(),
        ),
        NodePaletteItem(
          name: 'Meridian flip',
          icon: 'refresh-cw',
          description: 'Perform meridian flip',
          createNode: () => MeridianFlipNode(),
        ),
        // `isNorth` follows the observer latitude, matching what
        // SmartNightService derives: a southern-hemisphere run must rotate
        // about the SOUTH celestial pole.
        NodePaletteItem(
          name: 'Polar alignment',
          icon: 'compass',
          description: 'Measure polar error by rotating in RA',
          createNode: () =>
              PolarAlignmentNode(isNorth: (appSettings?.latitude ?? 0.0) >= 0),
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Dome',
      icon: 'home',
      items: [
        NodePaletteItem(
          name: 'Open dome',
          icon: 'home',
          description: 'Open dome shutter',
          createNode: () => OpenDomeNode(),
        ),
        NodePaletteItem(
          name: 'Close dome',
          icon: 'home',
          description: 'Close dome shutter',
          createNode: () => CloseDomeNode(),
        ),
        NodePaletteItem(
          name: 'Park dome',
          icon: 'parking-circle',
          description: 'Park the dome',
          createNode: () => ParkDomeNode(),
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Flat panel',
      icon: 'lightbulb',
      items: [
        NodePaletteItem(
          name: 'Open cover',
          icon: 'door-open',
          description: 'Open dust cover / flat panel lid',
          createNode: () => OpenCoverNode(),
        ),
        NodePaletteItem(
          name: 'Close cover',
          icon: 'door-closed',
          description: 'Close dust cover / flat panel lid',
          createNode: () => CloseCoverNode(),
        ),
        NodePaletteItem(
          name: 'Calibrator on',
          icon: 'lightbulb',
          description: 'Turn on flat panel at brightness',
          createNode: () => CalibratorOnNode(),
        ),
        NodePaletteItem(
          name: 'Calibrator off',
          icon: 'lightbulb-off',
          description: 'Turn off flat panel light',
          createNode: () => CalibratorOffNode(),
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Focus',
      icon: 'focus',
      items: [
        NodePaletteItem(
          name: 'Autofocus',
          icon: 'focus',
          description: 'Run autofocus routine',
          createNode: () => AutofocusNode(
            stepSize: defaults.autofocusStepSize,
            stepsOut: defaults.autofocusStepsOut,
            exposureDuration: defaults.autofocusExposureDuration,
          ),
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Camera',
      icon: 'aperture',
      items: [
        NodePaletteItem(
          name: 'Cool camera',
          icon: 'snowflake',
          description: 'Cool camera to target temperature',
          createNode: () => CoolCameraNode(),
        ),
        NodePaletteItem(
          name: 'Warm camera',
          icon: 'flame',
          description: 'Warm camera at controlled rate',
          createNode: () => WarmCameraNode(),
        ),
        NodePaletteItem(
          name: 'Move rotator',
          icon: 'rotate-cw',
          description: 'Move rotator to angle',
          createNode: () => RotatorNode(),
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Logic',
      icon: 'workflow',
      items: [
        NodePaletteItem(
          name: 'Instruction set',
          icon: 'list',
          description: 'Group instructions sequentially (no loop)',
          createNode: () => InstructionSetNode(),
        ),
        NodePaletteItem(
          name: 'Loop',
          icon: 'repeat',
          description: 'Repeat instructions',
          createNode: () => LoopNode(),
        ),
        NodePaletteItem(
          name: 'Conditional',
          icon: 'git-merge',
          description: 'Execute if condition is met',
          createNode: () => ConditionalNode(),
        ),
        NodePaletteItem(
          name: 'Parallel',
          icon: 'git-branch',
          description: 'Execute instructions in parallel',
          createNode: () => ParallelNode(),
        ),
        NodePaletteItem(
          name: 'Recovery',
          icon: 'shield-check',
          description: 'Handle errors with recovery logic',
          createNode: () => RecoveryNode(),
        ),
        // Target Scheduler — picks the highest-scoring child
        // target at runtime. Drop TargetHeader children under it.
        // UI close: seed the new node with the user's adaptive-swap
        // defaults from `appSettings` so a brand-new scheduler honours
        // the operator's Settings → Adaptive Conditions preferences
        // without needing to retouch every knob.
        NodePaletteItem(
          name: 'Target scheduler',
          icon: 'scheduler',
          description: 'Dynamically pick the best target right now',
          createNode: () => TargetSchedulerNode(
            swapOnConditionsBelow:
                (appSettings?.adaptiveSwapEnabledByDefault ?? false)
                ? (appSettings?.adaptiveSwapDefaultThreshold ?? 50.0)
                : null,
            swapHysteresisSecs:
                appSettings?.adaptiveSwapDefaultHysteresisSecs ?? 180.0,
          ),
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Timing',
      icon: 'clock',
      items: [
        NodePaletteItem(
          name: 'Wait for time',
          icon: 'clock',
          description: 'Wait until specific time',
          createNode: () => WaitTimeNode(),
        ),
        NodePaletteItem(
          name: 'Delay',
          icon: 'timer',
          description: 'Wait for duration',
          createNode: () => DelayNode(),
        ),
      ],
    ),
    NodePaletteCategory(
      name: 'Utilities',
      icon: 'wrench',
      items: [
        NodePaletteItem(
          name: 'Notification',
          icon: 'bell',
          description: 'Send notification',
          createNode: () => NotificationNode(),
        ),
        NodePaletteItem(
          name: 'Run script',
          icon: 'code',
          description: 'Execute custom script',
          createNode: () => ScriptNode(),
        ),
      ],
    ),
    // Plugin-contributed categories go last so they sit at the bottom of the
    // palette without re-ordering the familiar built-in groups. One or more
    // "Plugins / <category>" sections give plugins that publish multiple nodes
    // a clean sub-grouping (matching `SequenceNodeDefinition.category`). With
    // no plugins loaded the expression below evaluates to an empty spread and
    // the palette holds only the built-in groups.
    ..._buildPluginPaletteCategories(pluginBlueprints),
  ];
});

/// Convert the plugin blueprint list into one or more palette categories so
/// plugin nodes are first-class palette members. Grouping rules:
///
///   * Blueprints are grouped by their plugin-supplied `category` (case-
///     preserving). Empty / whitespace-only categories fall into a
///     generic "Plugins" bucket.
///   * Each emitted category name is prefixed with "Plugins / " so the
///     section stays visually distinct from the built-in categories no
///     matter what name the plugin chose.
///   * Inside a category, items are sorted by `name` so the palette has
///     a stable order regardless of plugin registration order.
///   * Blueprints with empty `pluginId` / `nodeTypeId` / `name` are dropped.
///     The app-layer adapter is the primary defence; this second check keeps a
///     malformed blueprint from crashing the palette.
List<NodePaletteCategory> _buildPluginPaletteCategories(
  List<PluginNodeBlueprint> blueprints,
) {
  if (blueprints.isEmpty) return const [];

  final Map<String, List<PluginNodeBlueprint>> grouped = {};
  for (final blueprint in blueprints) {
    if (blueprint.pluginId.isEmpty ||
        blueprint.nodeTypeId.isEmpty ||
        blueprint.name.isEmpty) {
      // Skip malformed entries; the adapter logs the issue.
      continue;
    }
    final rawCategory = blueprint.category.trim();
    final categoryKey = rawCategory.isEmpty ? 'General' : rawCategory;
    grouped.putIfAbsent(categoryKey, () => []).add(blueprint);
  }
  if (grouped.isEmpty) return const [];

  // Stable ordering: categories alphabetically, items by display name.
  final orderedCategories = grouped.keys.toList()..sort();
  return orderedCategories
      .map((categoryName) {
        final items = grouped[categoryName]!
          ..sort((a, b) => a.name.compareTo(b.name));
        return NodePaletteCategory(
          name: 'Plugins / $categoryName',
          icon: 'puzzle',
          items: items
              .map(
                (blueprint) => NodePaletteItem(
                  name: blueprint.name,
                  icon: blueprint.iconHint,
                  description: blueprint.description.isEmpty
                      ? '${blueprint.pluginName} plugin node'
                      : blueprint.description,
                  createNode: () => PluginInstructionNode(
                    name: blueprint.name,
                    pluginId: blueprint.pluginId,
                    nodeTypeId: blueprint.nodeTypeId,
                    pluginName: blueprint.pluginName,
                    configJson: blueprint.defaultConfigJson,
                    iconHint: blueprint.iconHint,
                  ),
                ),
              )
              .toList(growable: false),
        );
      })
      .toList(growable: false);
}

class NodePaletteCategory {
  final String name;
  final String icon;
  final List<NodePaletteItem> items;

  NodePaletteCategory({
    required this.name,
    required this.icon,
    required this.items,
  });
}

class NodePaletteItem {
  final String name;
  final String icon;
  final String description;
  final SequenceNode Function() createNode;
  final List<SequenceNode> Function()? createChildren;

  NodePaletteItem({
    required this.name,
    required this.icon,
    required this.description,
    required this.createNode,
    this.createChildren,
  });
}
