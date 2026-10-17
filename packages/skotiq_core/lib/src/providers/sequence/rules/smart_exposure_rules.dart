import '../../../models/equipment/equipment_models.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../equipment_provider.dart';
import '../../profiles_provider.dart';
import '../sequence_validation.dart';

/// SmartExposure validation rules.
///
/// These rules cover the three failure modes the brief calls out:
///   * empty plans (executable but pointless — error)
///   * any plan with count == 0 (silently never runs — warning)
///   * no filters on the active equipment profile (the rows have nothing
///     to select, so the node cannot execute — error)
///
/// All three are pure structural rules apart from
/// [SmartExposureFilterWheelMissingRule] which needs `Ref` to read the
/// active profile.

/// Empty plans = nothing to do. Sequence will still run, but the
/// SmartExposure node returns Success immediately without capturing any
/// frames. Treat as an error so the user fixes it before pressing Start.
class SmartExposureEmptyPlansRule implements SequenceValidator {
  @override
  String get name => 'SmartExposureEmptyPlans';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! SmartExposureNode) continue;
      if (!node.isEnabled) continue;
      if (node.plans.isEmpty) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.exposures,
            title: 'SmartExposure has no filter plans',
            description:
                'Smart Exposure "${node.name}" has no filter plans. It will run but capture no images.',
            affectedNodeId: node.id,
            resolutionHint:
                'Add at least one filter plan (filter + count + duration).',
          ),
        );
      }
    }
    return issues;
  }
}

/// Any plan with count <= 0 will never execute a single exposure. Treat
/// as a warning — the rest of the SmartExposure run still works — but
/// surface it so the user notices the dead row.
class SmartExposureNegativeCountRule implements SequenceValidator {
  @override
  String get name => 'SmartExposureNegativeCount';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! SmartExposureNode) continue;
      if (!node.isEnabled) continue;
      for (var i = 0; i < node.plans.length; i++) {
        final p = node.plans[i];
        // In loop-until-stopped mode the per-plan count is ignored entirely
        // (1 sub per filter, looping), so a zero/negative count is not a
        // dead row — skip the warning to avoid a false positive.
        if (!node.loopUntilStopped && p.count <= 0) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.warning,
              category: ValidationCategory.exposures,
              title: 'SmartExposure plan never runs',
              description:
                  'Smart Exposure "${node.name}": plan ${i + 1} ("${p.filterName}") has count ${p.count} — no frames will be taken for this filter.',
              affectedNodeId: node.id,
              resolutionHint:
                  'Set count to a positive number, or remove the row entirely.',
            ),
          );
        }
        if (p.durationSecs <= 0) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              category: ValidationCategory.exposures,
              title: 'SmartExposure plan has invalid duration',
              description:
                  'Smart Exposure "${node.name}": plan ${i + 1} ("${p.filterName}") has duration ${p.durationSecs}s.',
              affectedNodeId: node.id,
              resolutionHint: 'Set a positive sub-exposure duration.',
            ),
          );
        }
        if (p.filterName.trim().isEmpty) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              category: ValidationCategory.exposures,
              title: 'SmartExposure plan has no filter',
              description:
                  'Smart Exposure "${node.name}": plan ${i + 1} has an empty filter name. The runtime cannot route the filter change.',
              affectedNodeId: node.id,
              resolutionHint:
                  'Pick a filter from the active equipment profile.',
            ),
          );
        }
      }

      // Duplicate filter names: legal but usually a UX mistake.
      if (node.hasDuplicateFilter && node.plans.length > 1) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            category: ValidationCategory.exposures,
            title: 'SmartExposure has duplicate filter rows',
            description:
                'Smart Exposure "${node.name}" has two or more rows for the same filter — usually a mistake. SmartExposure tracks per-filter completed counts by name, so duplicate rows compete for the same counter.',
            affectedNodeId: node.id,
            resolutionHint:
                'Merge duplicate filter rows, or rename one to a different filter.',
          ),
        );
      }
    }
    return issues;
  }
}

/// SmartExposure picks its per-row filters from the active equipment
/// profile's filter list, so an empty list leaves every row unselectable
/// and the node cannot run.
///
/// The condition tested is the profile's filter list — NOT whether a filter
/// wheel is attached. Those are different facts and the app can show them
/// disagreeing: a wheel connected and green on the Equipment screen while
/// the profile still lists no filters. Reporting the empty list as "no
/// filter wheel" sent users to Equipment to look at a wheel that was fine,
/// so the wheel's real state is read here and the wording follows it.
class SmartExposureFilterWheelMissingRule implements RefAwareSequenceValidator {
  @override
  String get name => 'SmartExposureFilterWheelMissing';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    // Bail early when no SmartExposure node uses a filter — the rule has
    // nothing to check.
    final hasSmartExposureNode = sequence.nodes.values
        .whereType<SmartExposureNode>()
        .any((n) => n.isEnabled);
    if (!hasSmartExposureNode) return const [];

    // Read the active profile via the same provider the editor uses. If
    // it's null we can't decide; emit an `info` issue rather than silently
    // passing — matches the validator contract ("must not silently swallow
    // missing context").
    final profile = ctx.ref.read(activeEquipmentProfileProvider);
    if (profile == null) {
      return [
        const ValidationIssue(
          severity: ValidationSeverity.info,
          category: ValidationCategory.equipment,
          title: 'Cannot check SmartExposure filters',
          description:
              'No active equipment profile is selected, so the filter list SmartExposure draws its rows from could not be read.',
        ),
      ];
    }

    // The profile's `filterNames` list is what the SmartExposure editor
    // offers as row filters; empty means the rows have nothing to select.
    if (profile.filterNames.isNotEmpty) return const [];

    // Same source of truth the Equipment screen shows, so the message
    // cannot contradict what the user sees there.
    final wheel = ctx.ref.read(filterWheelStateProvider);
    final wheelConnected =
        wheel.connectionState == DeviceConnectionState.connected;
    final wheelAssignedToProfile = profile.filterWheelId?.isNotEmpty == true;
    final wheelLabel =
        wheel.deviceName ?? profile.filterWheelName ?? 'The filter wheel';

    final String title;
    final String cause;
    final String hint;
    if (wheelConnected || wheelAssignedToProfile) {
      title = 'No filters configured for SmartExposure';
      cause = wheelConnected
          ? '$wheelLabel is connected, but the active equipment profile "${profile.name}" lists no filters, so its rows have nothing to select.'
          : 'the active equipment profile "${profile.name}" assigns a filter wheel but lists no filters, so its rows have nothing to select.';
      // Echoing the slots the driver reports turns "add some filters" into
      // a list the user can copy, instead of a guess at their own hardware.
      hint = wheelConnected && wheel.filterNames.isNotEmpty
          ? 'Edit the active profile and name its filters — the wheel reports ${wheel.filterNames.length} slots: ${wheel.filterNames.join(', ')}.'
          : 'Edit the active profile and add at least one filter, or remove the SmartExposure node.';
    } else {
      title = 'No filter wheel for SmartExposure';
      cause =
          'no filter wheel is connected and the active equipment profile "${profile.name}" has none assigned, so there are no filters for its rows to select.';
      hint =
          'Assign a filter wheel to the active profile and add its filters, or remove the SmartExposure node.';
    }

    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! SmartExposureNode) continue;
      if (!node.isEnabled) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.equipment,
          title: title,
          description: 'Smart Exposure "${node.name}": $cause',
          affectedNodeId: node.id,
          resolutionHint: hint,
        ),
      );
    }
    return issues;
  }
}

/// Per-row check: every SmartExposure plan whose `filterName` is non-empty
/// must reference a filter that the active equipment profile actually has.
///
/// Without this check, a user can save (and start) a sequence that calls
/// for filter "OIII" while the profile only carries `L, R, G, B` — the
/// runtime then either silently routes to the wrong slot or fails partway
/// through. Audit item C6 ("SmartExposure validation doesn't verify per-row
/// filter names against the active profile") is exactly this gap.
///
/// Pairs with [SmartExposureFilterWheelMissingRule] (no filters at all) and
/// the per-row empty-name check inside [SmartExposureNegativeCountRule]
/// (empty `filterName`). This rule is the case in between: the row has a
/// name, the profile has names, they just don't agree. Comparison is
/// case-insensitive, matching the convention used by [FilterInWheelRule]
/// for ExposureNode/FilterChangeNode against the live wheel.
class SmartExposureFilterUnknownRule implements RefAwareSequenceValidator {
  @override
  String get name => 'SmartExposureFilterUnknown';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    // Bail early when no enabled SmartExposure node is in the sequence.
    final smartExposureNodes = sequence.nodes.values
        .whereType<SmartExposureNode>()
        .where((n) => n.isEnabled)
        .toList();
    if (smartExposureNodes.isEmpty) return const [];

    final profile = ctx.ref.read(activeEquipmentProfileProvider);
    if (profile == null) {
      // No profile → SmartExposureFilterWheelMissingRule already emits an
      // info issue explaining that the check is skipped. Returning empty here
      // avoids double-reporting.
      return const [];
    }

    // Empty profile filter list is already flagged as an error by
    // SmartExposureFilterWheelMissingRule. Nothing useful to add here.
    if (profile.filterNames.isEmpty) return const [];

    // Case-insensitive lookup set, matching FilterInWheelRule's convention.
    final availableLower = profile.filterNames
        .map((f) => f.toLowerCase())
        .toSet();
    final availableLabel = profile.filterNames.join(', ');

    final issues = <ValidationIssue>[];
    for (final node in smartExposureNodes) {
      for (var i = 0; i < node.plans.length; i++) {
        final plan = node.plans[i];
        final raw = plan.filterName;
        // Empty filter names are handled by SmartExposureNegativeCountRule's
        // per-row empty-filter check — skip to avoid double-counting.
        if (raw.trim().isEmpty) continue;
        if (availableLower.contains(raw.toLowerCase())) continue;
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.equipment,
            title: 'SmartExposure plan filter not in profile',
            description:
                'Smart Exposure "${node.name}": plan ${i + 1} uses filter "$raw" '
                'which is not in the active equipment profile. Available: $availableLabel.',
            affectedNodeId: node.id,
            resolutionHint:
                'Pick a filter from the active profile, or add "$raw" to the profile\'s filter list.',
          ),
        );
      }
    }
    return issues;
  }
}

/// Loop-until-stopped mode is bounded by EITHER an integration budget OR the
/// surrounding target's end window (`endWhen` / legacy `endBefore`). With
/// neither, the Rust executor fails closed at runtime rather than looping
/// forever (errors-are-a-feature). This rule surfaces that at edit time as an
/// error so the user fixes it before pressing Start instead of hitting a
/// runtime failure.
class SmartExposureUnboundedLoopRule implements SequenceValidator {
  @override
  String get name => 'SmartExposureUnboundedLoop';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! SmartExposureNode) continue;
      if (!node.isEnabled) continue;
      if (!node.loopUntilStopped) continue;
      // A positive integration budget is a valid automatic bound.
      if (node.integrationBudgetSecs > 0) continue;
      // Otherwise, the only automatic bound is a parent target window.
      if (_hasBoundingTargetWindow(sequence, node)) continue;

      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          category: ValidationCategory.exposures,
          title: 'SmartExposure loop is unbounded',
          description:
              'Smart Exposure "${node.name}" is in "switch filter every frame" '
              '(loop until stopped) mode but has no integration budget and is not '
              'under a target with an end condition. It would loop forever, so the '
              'run will refuse to start.',
          affectedNodeId: node.id,
          resolutionHint:
              'Set an integration budget on the node, or place it under a target '
              'with an ends-when / ends-before condition.',
        ),
      );
    }
    return issues;
  }

  /// Walk parents to find a [TargetHeaderNode] with an end condition.
  bool _hasBoundingTargetWindow(Sequence sequence, SequenceNode node) {
    var currentId = node.parentId;
    final seen = <String>{};
    while (currentId != null && seen.add(currentId)) {
      final parent = sequence.nodes[currentId];
      if (parent == null) break;
      if (parent is TargetHeaderNode &&
          (parent.endWhen != null || parent.endBefore != null)) {
        return true;
      }
      currentId = parent.parentId;
    }
    return false;
  }
}
