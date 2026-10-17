// ignore_for_file: invalid_annotation_target

part of '../sequence_models.dart';

// Sequence

/// Complete sequence.
///
/// **Tree representation contract**:
///
///   * `nodes` (a flat `Map<String, SequenceNode>`) remains the canonical
///     content store and the on-disk serialization shape. Every node carries
///     its own `childIds: List<String>` and `parentId: String?`. The on-the-
///     wire JSON (executor payload + `.nseq.json` export) is unchanged.
///
///   * The parent/child indexes are **derived** from `nodes` and live in
///     [SequenceTreeIndex] (sibling class, cached per-instance via an
///     [Expando]). They make `childrenOf(p)`, `parentOf(c)`, and descendant
///     walks O(1) per hop without scanning the full node map.
///
///   * The runtime invariant is: `treeIndex.childrenOf(parentId)` is the
///     authoritative ordering of children under `parentId`, and the
///     `parentId` field on each node matches `treeIndex.parentOf(node.id)`.
///     The index is built FROM `nodes[*].childIds` + `nodes[*].parentId`,
///     so the two representations are kept consistent by construction —
///     every mutation goes through `CurrentSequenceNotifier`, which
///     produces a fresh `Sequence` via `copyWith(nodes: ...)`; the new
///     instance rebuilds its index from the new `nodes` map on first
///     access.
///
///   * `orderIndex` on each node is preserved as a load-bearing persistence
///     field (Drift uses it for `ORDER BY` on load). The editor renumbers
///     `orderIndex` only within the affected parent's children list — never
///     a tree-wide rewrite — so reorder/insert/remove cost is bounded by the
///     parent's sibling count, not by the total tree size.
///
/// Construction: use [Sequence.create] for auto-filled id + createdAt +
/// modifiedAt. The bare freezed factory requires every load-bearing field
/// explicitly — useful for code paths (deserialization, database load, file
/// import) that already have the authoritative values.
@freezed
abstract class Sequence with _$Sequence {
  const Sequence._();

  /// Raw freezed-generated constructor. Every field is explicit — no
  /// auto-generated UUID, no `DateTime.now()` defaults. Use this from
  /// code paths that already have the authoritative `id` / timestamps
  /// (deserialization, database load, etc.); use [Sequence.create] from
  /// app / UI code that wants id / timestamp defaulting.
  const factory Sequence({
    required String id,
    int? databaseId,
    required String name,
    @Default('') String description,
    @Default(<String, SequenceNode>{}) Map<String, SequenceNode> nodes,
    String? rootNodeId,
    required DateTime createdAt,
    required DateTime modifiedAt,
    @Default(false) bool isTemplate,
    int? estimatedDurationMins,
  }) = _Sequence;

  /// Friendly factory matching the pre-freezed `Sequence(...)` signature:
  /// `id`, `createdAt`, and `modifiedAt` are auto-generated when omitted,
  /// `nodes` defaults to an empty map. Used by editor / template / planner
  /// code that just wants a fresh sequence.
  factory Sequence.create({
    String? id,
    int? databaseId,
    required String name,
    String description = '',
    Map<String, SequenceNode>? nodes,
    String? rootNodeId,
    DateTime? createdAt,
    DateTime? modifiedAt,
    bool isTemplate = false,
    int? estimatedDurationMins,
  }) {
    final now = DateTime.now();
    return Sequence(
      id: id ?? const Uuid().v4(),
      databaseId: databaseId,
      name: name,
      description: description,
      nodes: nodes ?? const <String, SequenceNode>{},
      rootNodeId: rootNodeId,
      createdAt: createdAt ?? now,
      modifiedAt: modifiedAt ?? now,
      isTemplate: isTemplate,
      estimatedDurationMins: estimatedDurationMins,
    );
  }

  // Derived tree-index API (delegates to [SequenceTreeIndex]).
  //
  // The index lives off the model so freezed-generated equality / hashCode do
  // not see it. Its per-instance cache is `sequenceTreeIndexCache` ([Expando]),
  // keyed by instance identity: each `Sequence` computes the index once on
  // first access, and a fresh instance built from the same `nodes` map starts
  // with an empty cache.

  /// Materialized [SequenceTreeIndex] for this sequence, lazily built on
  /// first access and cached on the instance via [Expando]. Hot-path code
  /// that does many lookups against the same `Sequence` reuses the single
  /// pre-built index — there is no per-call rebuild.
  SequenceTreeIndex get treeIndex => sequenceTreeIndexFor(this);

  /// Children of [parentId] in their canonical order. See
  /// [SequenceTreeIndex.childrenOf] for the full contract.
  List<SequenceNode> childrenOf(String parentId) =>
      treeIndex.childrenOf(parentId);

  /// Parent ID of [nodeId], or `null` if [nodeId] is a root node OR is not
  /// in this sequence. See [SequenceTreeIndex.parentOf].
  String? parentOf(String nodeId) => treeIndex.parentOf(nodeId);

  /// IDs of all descendants of [nodeId] in DFS pre-order. See
  /// [SequenceTreeIndex.descendantsOf].
  List<String> descendantsOf(String nodeId) => treeIndex.descendantsOf(nodeId);

  /// Verify the structural invariants of this sequence. See
  /// [SequenceTreeIndex.invariants] for the full set of checks.
  List<String> invariants() => treeIndex.invariants();

  /// Get total exposure count.
  ///
  /// Walks the tree from [rootNodeId] applying loop multipliers, mirroring
  /// [_calculateOverhead] / [estimateIntegrationSecs] so the progress
  /// denominator counts looped frames the same way the integration estimate
  /// does. Falls back to the flat sum over [nodes] when there is no tree
  /// structure (no root node), matching the fallback in
  /// [estimateIntegrationSecs].
  int get totalExposures {
    if (rootNodeId != null && nodes[rootNodeId] != null) {
      return _countExposures(rootNodeId!, 1);
    }
    int count = 0;
    for (final node in nodes.values) {
      if (node is ExposureNode && node.isEnabled) {
        count += node.count;
      } else if (node is SmartExposureNode && node.isEnabled) {
        count += node.plans.fold(0, (s, p) => s + p.count);
      } else if (node is SciencePhotometryNode && node.isEnabled) {
        count += node.count;
      }
    }
    return count;
  }

  /// Recursively count planned exposures under [nodeId], scaling by [mult]
  /// (the accumulated loop multiplier). Count loops multiply the child
  /// multiplier by their iteration count; unbounded / other loops keep the
  /// single-iteration multiplier (matching how [_calculateOverhead] treats
  /// them so the denominator never reports an unbounded total).
  int _countExposures(String nodeId, int mult) {
    final node = nodes[nodeId];
    if (node == null || !node.isEnabled) return 0;

    int count = 0;
    if (node is ExposureNode) {
      count += node.count * mult;
    } else if (node is SmartExposureNode) {
      count += node.plans.fold(0, (s, p) => s + p.count) * mult;
    } else if (node is SciencePhotometryNode) {
      // A photometry burst captures `count` frames through the standard
      // TakeExposure pipeline. Omitting it made the sequence header read
      // "0 frames" for a node whose own properties panel said 60.
      count += node.count * mult;
    }

    int childMultiplier = mult;
    if (node is LoopNode && node.conditionType == LoopConditionType.count) {
      childMultiplier = mult * (node.repeatCount ?? 1);
    }

    for (final childId in node.childIds) {
      count += _countExposures(childId, childMultiplier);
    }
    return count;
  }

  /// Get total integration time in seconds
  /// This walks the tree structure and accounts for loop iterations
  double get totalIntegrationSecs {
    return estimateIntegrationSecs().estimatedSecs;
  }

  /// Estimate integration time with overhead awareness.
  /// Walks the sequence tree counting occurrences of each operation type
  /// and applies configurable per-operation overhead estimates.
  ///
  /// NOT the model any UI surface bills against — do not reach for it from one.
  /// Its per-node costs are flat constants that know nothing about a node's own
  /// configuration (a Cool Camera is billed a fixed "cooling" figure rather
  /// than its configured duration) and it has no entry at all for the
  /// clock-dependent nodes. Pointing the Builder's estimate chip at it while
  /// the Pre-Flight panel used [SequenceTimeEstimator] is what made the two
  /// print different totals for the same sequence. Every estimate surface now
  /// goes through [SequenceTimeEstimator.nodeDuration] with the overhead config
  /// from `sequencerOverheadConfigProvider`.
  SequenceEstimate estimateWithOverhead({
    SequenceOverheadConfig config = const SequenceOverheadConfig(),
    DateTime? referenceTime,
  }) {
    final base = estimateIntegrationSecs(referenceTime: referenceTime);

    // Walk tree counting overhead-generating operations
    double overheadSecs = 0;

    if (rootNodeId != null && nodes[rootNodeId] != null) {
      overheadSecs = _calculateOverhead(rootNodeId!, config, 1);
    } else {
      // No tree structure - just count nodes directly
      for (final node in nodes.values) {
        if (!node.isEnabled) continue;
        overheadSecs += _nodeOverhead(node, config);
      }
    }

    return SequenceEstimate(
      estimatedSecs: base.estimatedSecs,
      overheadSecs: overheadSecs,
      singleIterationSecs: base.singleIterationSecs,
      isUnbounded: base.isUnbounded,
      untilTime: base.untilTime,
      conditionType: base.conditionType,
    );
  }

  /// Calculate overhead for a node and its subtree, respecting loop multipliers
  double _calculateOverhead(
    String nodeId,
    SequenceOverheadConfig config,
    int multiplier,
  ) {
    final node = nodes[nodeId];
    if (node == null || !node.isEnabled) return 0;

    // Leaf node overhead
    final selfOverhead = _nodeOverhead(node, config) * multiplier;

    // Children overhead
    double childrenOverhead = 0;
    int childMultiplier = multiplier;
    if (node is LoopNode) {
      if (node.conditionType == LoopConditionType.count) {
        childMultiplier = multiplier * (node.repeatCount ?? 1);
      }
      // For unbounded loops, keep multiplier at 1 for overhead
    }

    for (final childId in node.childIds) {
      childrenOverhead += _calculateOverhead(childId, config, childMultiplier);
    }

    return selfOverhead + childrenOverhead;
  }

  /// Get the overhead contribution for a single node instance
  double _nodeOverhead(SequenceNode node, SequenceOverheadConfig config) {
    if (node is SlewNode) return config.slewSecs;
    if (node is CenterNode) return config.centerTargetSecs;
    if (node is AutofocusNode) return config.autofocusSecs;
    if (node is FilterChangeNode) return config.filterChangeSecs;
    if (node is DitherNode) return config.ditherSecs;
    if (node is StartGuidingNode) return config.guideAcquireSecs;
    if (node is MeridianFlipNode) return config.meridianFlipSecs;
    if (node is CoolCameraNode) return config.coolingSecs;
    if (node is WarmCameraNode) return config.warmingSecs;
    if (node is OpenCoverNode || node is CloseCoverNode) {
      return config.coverMoveSecs;
    }
    if (node is ExposureNode) {
      // Download overhead per exposure
      return config.downloadOverheadPerExposureSecs * node.count;
    }
    return 0;
  }

  /// Estimate integration time with detailed info about bounded/unbounded status
  /// [referenceTime] is used for calculating time-based loop durations (default: now)
  SequenceEstimate estimateIntegrationSecs({DateTime? referenceTime}) {
    referenceTime ??= DateTime.now();

    // If no root node, fall back to simple sum of all exposures
    if (rootNodeId == null || nodes[rootNodeId] == null) {
      double total = 0;
      for (final node in nodes.values) {
        if (node is ExposureNode && node.isEnabled) {
          total += node.totalDurationSecs;
        } else if (node is SmartExposureNode && node.isEnabled) {
          // Same omission as the tree walk below, on the flat fallback path:
          // [totalExposures] already counts SmartExposure frames here, so
          // leaving them out of the duration made the two disagree.
          total += _smartExposureIntegration(node).estimatedSecs;
        }
      }
      return SequenceEstimate(
        estimatedSecs: total,
        singleIterationSecs: total,
        isUnbounded: false,
      );
    }

    // Walk the tree from root
    return _estimateNodeIntegration(rootNodeId!, referenceTime);
  }

  /// Integration a [SmartExposureNode] will actually accumulate, following the
  /// executor's own stopping rules (`smart_exposure.rs`):
  ///
  ///  * `loopUntilStopped` ignores the per-plan counts entirely and rotates one
  ///    sub per filter until the budget or the surrounding target window ends
  ///    it. With a budget that IS the estimate; without one the only bound is
  ///    the target window, so the node is unbounded and we report a single
  ///    rotation the way the unbounded loop kinds do.
  ///  * Otherwise the plans run to completion, but a positive budget
  ///    short-circuits them, so the estimate cannot exceed it.
  SequenceEstimate _smartExposureIntegration(SmartExposureNode node) {
    final oneRotation = node.plans.fold<double>(
      0,
      (sum, plan) => sum + plan.durationSecs,
    );
    final budget = node.integrationBudgetSecs;

    if (node.loopUntilStopped) {
      if (budget > 0) {
        return SequenceEstimate(
          estimatedSecs: budget,
          singleIterationSecs: oneRotation,
          isUnbounded: false,
        );
      }
      return SequenceEstimate(
        estimatedSecs: oneRotation,
        singleIterationSecs: oneRotation,
        isUnbounded: true,
      );
    }

    var duration = node.totalIntegrationSecs;
    if (budget > 0 && budget < duration) duration = budget;
    return SequenceEstimate(
      estimatedSecs: duration,
      singleIterationSecs: duration,
      isUnbounded: false,
    );
  }

  /// Recursively estimate integration time for a node and its children
  SequenceEstimate _estimateNodeIntegration(
    String nodeId,
    DateTime referenceTime,
  ) {
    final node = nodes[nodeId];
    if (node == null || !node.isEnabled) {
      return const SequenceEstimate(
        estimatedSecs: 0,
        singleIterationSecs: 0,
        isUnbounded: false,
      );
    }

    // For exposure nodes, return the direct duration
    if (node is ExposureNode) {
      final duration = node.totalDurationSecs;
      return SequenceEstimate(
        estimatedSecs: duration,
        singleIterationSecs: duration,
        isUnbounded: false,
      );
    }

    // Smart Exposure is an imaging node like any other: its per-filter plans
    // are frames on disk. Omitting it made [totalIntegrationSecs] — and the
    // `estimated_duration_mins` column the library card renders — report only
    // the plain ExposureNodes, so a sequence of one 10x60s TakeExposure plus
    // one 10x60s SmartExposure was stored and shown as "10m" for 20 frames.
    if (node is SmartExposureNode) {
      return _smartExposureIntegration(node);
    }

    // A photometry burst is integration time like any other: `count` frames of
    // `exposureSecs`. Leaving it out reported "0m" for a node that occupies an
    // hour of the night.
    if (node is SciencePhotometryNode) {
      final duration = node.exposureSecs * node.count;
      return SequenceEstimate(
        estimatedSecs: duration,
        singleIterationSecs: duration,
        isUnbounded: false,
      );
    }

    // For nodes with children, sum up children's estimates
    double childrenSecs = 0;
    double childrenSingleIteration = 0;
    bool anyChildUnbounded = false;

    for (final childId in node.childIds) {
      final childEstimate = _estimateNodeIntegration(childId, referenceTime);
      childrenSecs += childEstimate.estimatedSecs;
      childrenSingleIteration += childEstimate.singleIterationSecs;
      if (childEstimate.isUnbounded) anyChildUnbounded = true;
    }

    // For loop nodes, apply the loop multiplier
    if (node is LoopNode) {
      switch (node.conditionType) {
        case LoopConditionType.count:
          // Fixed iteration count
          final iterations = node.repeatCount ?? 1;
          return SequenceEstimate(
            estimatedSecs: childrenSecs * iterations,
            singleIterationSecs: childrenSingleIteration,
            isUnbounded: anyChildUnbounded,
          );

        case LoopConditionType.untilTime:
          // Time-based loop: estimate iterations based on available time
          if (node.repeatUntil != null && childrenSingleIteration > 0) {
            final availableSecs = node.repeatUntil!
                .difference(referenceTime)
                .inSeconds
                .toDouble();
            if (availableSecs > 0) {
              // Estimate how many iterations can fit in the time window
              final estimatedIterations =
                  (availableSecs / childrenSingleIteration).floor();
              final estimatedTotal =
                  childrenSingleIteration * estimatedIterations;
              return SequenceEstimate(
                estimatedSecs: estimatedTotal,
                singleIterationSecs: childrenSingleIteration,
                isUnbounded: false,
                untilTime: node.repeatUntil,
              );
            }
          }
          // If repeatUntil is in the past or not set, return single iteration
          return SequenceEstimate(
            estimatedSecs: childrenSingleIteration,
            singleIterationSecs: childrenSingleIteration,
            isUnbounded: false,
            untilTime: node.repeatUntil,
          );

        case LoopConditionType.forever:
        case LoopConditionType.whileDark:
        case LoopConditionType.untilAltitude:
        case LoopConditionType.altitudeAbove:
          // Unbounded loops - return single iteration time but mark as unbounded
          return SequenceEstimate(
            estimatedSecs: childrenSingleIteration,
            singleIterationSecs: childrenSingleIteration,
            isUnbounded: true,
            conditionType: node.conditionType,
          );

        case LoopConditionType.integrationTime:
          // Integration time loop: estimate iterations based on target integration time
          if (node.integrationTimeTarget != null &&
              node.integrationTimeTarget! > 0 &&
              childrenSingleIteration > 0) {
            // Find total exposure time per iteration from children
            double exposurePerIteration = 0;
            for (final childId in node.childIds) {
              final child = nodes[childId];
              if (child is ExposureNode && child.isEnabled) {
                exposurePerIteration += child.totalDurationSecs;
              }
            }
            if (exposurePerIteration > 0) {
              final estimatedIterations =
                  (node.integrationTimeTarget! / exposurePerIteration).ceil();
              return SequenceEstimate(
                estimatedSecs: childrenSingleIteration * estimatedIterations,
                singleIterationSecs: childrenSingleIteration,
                isUnbounded: false,
              );
            }
          }
          // If we can't estimate, treat as unbounded
          return SequenceEstimate(
            estimatedSecs: childrenSingleIteration,
            singleIterationSecs: childrenSingleIteration,
            isUnbounded: true,
            conditionType: node.conditionType,
          );
      }
    }

    // For other container nodes (Parallel, Conditional, etc.), just return children sum
    return SequenceEstimate(
      estimatedSecs: childrenSecs,
      singleIterationSecs: childrenSingleIteration,
      isUnbounded: anyChildUnbounded,
    );
  }

  /// Get target headers (root nodes for each target).
  ///
  /// Flattens every enabled [TargetHeaderNode] in the tree regardless of
  /// nesting depth (targets may live under root, under a loop, or under any
  /// container). Sorted by `orderIndex` to keep the legacy UI ordering — the
  /// alternative (tree-walk-canonical-order) would not work for sequences
  /// where targets are spread across multiple parent containers, which the
  /// `CrossParentReorderException` test in `sequence_editor_trust_patch_test`
  /// pins as supported behavior.
  List<TargetHeaderNode> get targetHeaders {
    return nodes.values
        .whereType<TargetHeaderNode>()
        .where((n) => n.isEnabled)
        .toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  /// Get node by ID
  SequenceNode? getNode(String id) => nodes[id];

  /// Get root node
  SequenceNode? get rootNode => rootNodeId != null ? nodes[rootNodeId] : null;

  /// Get children of a node. See [childrenOf] for the index-backed equivalent;
  /// this is the legacy entry point kept for backward compatibility with
  /// consumers that already use `getChildren`. Both return the same list.
  List<SequenceNode> getChildren(String parentId) => childrenOf(parentId);

  /// Count all descendants of [nodeId] (children, grandchildren, ...).
  ///
  /// Returns 0 when [nodeId] does not exist or is a leaf. The node itself
  /// is **not** counted — only its subtree. Used by the UI to decide
  /// whether deleting a node warrants a confirmation dialog (e.g.,
  /// "Delete N nodes?" for non-leaf containers).
  ///
  /// Backed by the parent-keyed index (single DFS over the subtree), so
  /// the cost is O(size-of-subtree) — no nodes outside the subtree are
  /// visited. The defensive cycle guard from the pre-W1.7 implementation is
  /// preserved as defense-in-depth against malformed import data, even
  /// though [invariants] would have rejected it.
  int countDescendants(String nodeId) => treeIndex.countDescendants(nodeId);
}

/// Progress of sequence execution.
///
/// Phase 3 Step 2 resolved the freezed-incompatibility blocker on this
/// class by rewriting `SequenceProgressNotifier.updateProgress` to build
/// the next `SequenceProgress` explicitly (no reliance on the pre-freezed
/// `copyWith(x: x ?? this.x)` quirk). Step 3 then converted this class to
/// freezed; the rewritten `updateProgress` continues to work because it
/// constructs a fresh `SequenceProgress` rather than calling `copyWith`.
@freezed
abstract class SequenceProgress with _$SequenceProgress {
  const SequenceProgress._();

  const factory SequenceProgress({
    @Default(SequenceExecutionState.idle) SequenceExecutionState state,
    String? currentNodeId,
    String? currentNodeName,
    NodeStatus? currentNodeStatus,
    @Default(0) int totalExposures,
    @Default(0) int completedExposures,
    @Default(0.0) double totalIntegrationSecs,
    @Default(0.0) double completedIntegrationSecs,
    @Default(0.0) double elapsedSecs,
    double? estimatedRemainingSecs,
    String? currentTarget,
    String? currentFilter,
    String? message,
    @Default(<String, NodeStatus>{}) Map<String, NodeStatus> nodeStatuses,

    /// Per-node instruction progress (0-100 percent)
    @Default(<String, double>{}) Map<String, double> nodeProgressPercent,

    /// Per-node instruction progress detail message
    @Default(<String, String>{}) Map<String, String> nodeProgressDetail,

    /// Per-node structured instruction progress detail.
    @Default(<String, InstructionProgressDetail>{})
    Map<String, InstructionProgressDetail> nodeProgressStructuredDetail,
  }) = _SequenceProgress;

  double get progressPercent {
    if (totalExposures == 0) return 0;
    return completedExposures / totalExposures;
  }
}

// Science — SciencePhotometryNode + transparency-adaptive support.
