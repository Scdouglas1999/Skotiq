// Conversational sequence builder service.
//
// Architecture:
//
//   ConversationalBuilderService.buildSequenceFromPrompt
//     1. Gather context (active profile, location, observable targets,
//        weather forecast, supported node types).
//     2. Compose the system prompt + JSON schema reference + few-shot
//        examples.
//     3. Send to the configured LLM provider.
//     4. Parse the reply as a Sequence JSON via SequenceFileService.
//     5. Run the structural validator (validateSequence).
//     6. If errors, send the issue list back to the LLM with an
//        explicit "fix the following errors and re-emit JSON" prompt,
//        and loop up to maxSelfCorrection times.
//     7. Return ConversationalBuildResult — the best Sequence we got
//        + the validation issues + the LLM trace.
//
// Why a separate service from SmartNightService:
//   * SmartNightService is the *deterministic* tree-builder that takes
//     a list of selected targets + a strategy and emits a Sequence.
//     It's pure-Dart and never talks to a remote endpoint.
//   * ConversationalBuilderService is the *non-deterministic* layer:
//     user prompt → LLM → Sequence. It uses SequenceFileService to
//     parse the LLM's JSON (so the on-disk schema is the single
//     source of truth for what the LLM is expected to emit) and the
//     validator to gate the output.
//
// Failure handling:
//   * If no provider is configured the service throws
//     [ConversationalBuilderUnconfigured].
//   * If the LLM produces JSON that can't be parsed, that *counts as a
//     validation issue* — the loop tries to fix it. After
//     maxSelfCorrection rounds it returns the best attempt with the
//     issue list set, the caller surfaces it as a dialog warning, and
//     the user can still inspect the raw LLM response.
//   * If the LLM provider raises [LlmProviderException] (HTTP / auth /
//     network), we DO NOT swallow it — we rethrow as
//     [ConversationalBuilderException]. The dialog surfaces the
//     network error with a "Retry" button.

import 'dart:async';
import 'dart:convert';

import '../../models/planning/target_suggestion.dart';
import '../../models/sequence/sequence_models.dart';
import '../../providers/profiles_provider.dart' show EquipmentProfileModel;
import '../../providers/sequence/sequence_validation.dart';
import '../logging_service.dart';
import '../sequence_file_service.dart';
import 'llm_provider.dart';
import 'system_prompt_builder.dart';

/// Thrown by [ConversationalBuilderService.buildSequenceFromPrompt] when
/// the user has not configured a provider. The dialog catches this and
/// shows the "Configure an AI provider in Settings" empty state.
class ConversationalBuilderUnconfigured implements Exception {
  final String message;
  const ConversationalBuilderUnconfigured([
    this.message =
        'No AI provider configured. Open Settings → AI Assistant to set one up.',
  ]);
  @override
  String toString() => 'ConversationalBuilderUnconfigured: $message';
}

/// Thrown when the LLM provider raised a wire-level failure that we
/// don't want to swallow (auth, network, decode). The dialog catches
/// this and surfaces the underlying message + a Retry action.
class ConversationalBuilderException implements Exception {
  final String message;
  final LlmProviderException? cause;
  const ConversationalBuilderException(this.message, {this.cause});
  @override
  String toString() => 'ConversationalBuilderException: $message';
}

/// Outcome of [ConversationalBuilderService.buildSequenceFromPrompt].
///
/// On the happy path:
///   * [sequence] is non-null and [validationIssues] has no errors.
///   * [rounds] is the number of LLM round-trips it took (1 in the
///     best case, up to `maxSelfCorrection + 1` when the model needed
///     correction).
///
/// On the failure path (the model couldn't produce valid JSON within
/// the self-correction budget):
///   * [sequence] is null OR contains the best attempt the model made.
///   * [validationIssues] holds every issue from the final attempt so
///     the dialog can surface them.
///   * [rawReplies] holds the LLM's text for each round (for the "Show
///     conversation" expand-on-failure UX).
class ConversationalBuildResult {
  /// Best parsed Sequence. Null when no round produced valid JSON.
  final Sequence? sequence;

  /// Validation issues from the final round (empty on success).
  final List<ValidationIssue> validationIssues;

  /// Number of LLM round-trips (>=1).
  final int rounds;

  /// Total tokens consumed across all rounds, when the provider
  /// reported usage. Null for providers that don't return usage info.
  final LlmUsage? totalUsage;

  /// Raw model replies, one per round. Surfaced in the "show details"
  /// expansion of the dialog so a power user can copy-paste the
  /// conversation into a bug report.
  final List<String> rawReplies;

  /// The composed system prompt (frozen at build time). Logged with
  /// the history entry so the user can reconstruct what the model
  /// saw.
  final String systemPrompt;

  /// The user's original prompt — echoed back so callers don't have
  /// to thread it through their own state.
  final String userPrompt;

  const ConversationalBuildResult({
    required this.sequence,
    required this.validationIssues,
    required this.rounds,
    required this.totalUsage,
    required this.rawReplies,
    required this.systemPrompt,
    required this.userPrompt,
  });

  bool get isValid =>
      sequence != null &&
      !validationIssues.any((i) => i.severity == ValidationSeverity.error);
}

/// Lightweight envelope of "everything the LLM should know about the
/// user's rig + tonight + the targets they care about". Owned by the
/// dialog (which fills it from Riverpod providers) and passed to the
/// service.
class ConversationalBuilderContext {
  /// Active equipment profile — drives the camera, filters, focal
  /// length, aperture passed into the prompt.
  final EquipmentProfileModel profile;

  /// Observer location + dark-window bounds. Optional — the service
  /// falls back to "tonight" boilerplate when null.
  final double? latitudeDeg;
  final double? longitudeDeg;
  final DateTime? windowStart;
  final DateTime? windowEnd;

  /// Optional list of candidate targets — the user's observing list or
  /// the Smart Night scored shortlist. The system prompt enumerates
  /// these by name + coordinates so the LLM can pick from them
  /// instead of inventing arbitrary objects (avoids "imagine M999").
  final List<TargetSuggestion> candidates;

  /// Optional weather note — "cloud cover 30% expected after 02:00".
  /// Surfaced into the prompt so the LLM can decide whether to add a
  /// CloudArriving recovery node.
  final String? weatherNote;

  /// User options passed via the dialog toggles. Maps cleanly into
  /// the prompt's instruction block.
  final ConversationalBuilderOptions options;

  /// Optional refinement context — when the user clicks "Refine" we
  /// carry the previous result through so the LLM can amend rather
  /// than start from scratch.
  final ConversationalBuildResult? refineFrom;

  const ConversationalBuilderContext({
    required this.profile,
    this.latitudeDeg,
    this.longitudeDeg,
    this.windowStart,
    this.windowEnd,
    this.candidates = const [],
    this.weatherNote,
    this.options = const ConversationalBuilderOptions(),
    this.refineFrom,
  });
}

/// Discrete user-facing options surfaced in the dialog. Kept here (not
/// in the dialog widget) so the service can be tested without Flutter.
class ConversationalBuilderOptions {
  /// Force the LLM to draw from [ConversationalBuilderContext.candidates]
  /// instead of inventing arbitrary catalogue objects.
  final bool restrictToCandidates;

  /// Hard cap on total session length, in hours. Translates to a
  /// "session should fit in `N` hours" instruction.
  final double? maxSessionHours;

  /// Add a flats sub-tree at the end of the sequence.
  final bool includeFlatsAtEnd;

  /// Prefer the TargetSchedulerNode when more than one target is in
  /// play (vs. a linear TargetHeader chain).
  final bool useSchedulerForMultiTarget;

  const ConversationalBuilderOptions({
    this.restrictToCandidates = true,
    this.maxSessionHours,
    this.includeFlatsAtEnd = false,
    this.useSchedulerForMultiTarget = true,
  });

  ConversationalBuilderOptions copyWith({
    bool? restrictToCandidates,
    double? maxSessionHours,
    bool? includeFlatsAtEnd,
    bool? useSchedulerForMultiTarget,
  }) {
    return ConversationalBuilderOptions(
      restrictToCandidates: restrictToCandidates ?? this.restrictToCandidates,
      maxSessionHours: maxSessionHours ?? this.maxSessionHours,
      includeFlatsAtEnd: includeFlatsAtEnd ?? this.includeFlatsAtEnd,
      useSchedulerForMultiTarget:
          useSchedulerForMultiTarget ?? this.useSchedulerForMultiTarget,
    );
  }
}

/// The conversational builder.
///
/// Stateless: every call to [buildSequenceFromPrompt] is a fresh
/// transaction. The history layer (see [ConversationalHistoryService])
/// is a separate component that subscribes to results via the dialog.
class ConversationalBuilderService {
  /// LLM instance to talk to. The dialog constructs one per build via
  /// [LlmSettingsService.buildActiveProvider] and closes it when the
  /// dialog dismisses.
  final LlmProvider provider;

  /// Parses JSON ⇆ Sequence. Reused so the on-disk schema is the
  /// single source of truth.
  final SequenceFileService fileService;

  /// Optional logging — the service uses debug level for round
  /// traces so a "didn't pass validation" can be inspected post-hoc.
  final LoggingService? logging;

  /// Max additional rounds the service will request after the first
  /// reply. Per the task spec the loop runs up to 3 self-corrections
  /// before giving up.
  final int maxSelfCorrection;

  /// Optional system-prompt builder — exposed for tests so a stub can
  /// keep the prompt deterministic.
  final SystemPromptBuilder promptBuilder;

  ConversationalBuilderService({
    required this.provider,
    required this.fileService,
    this.logging,
    this.maxSelfCorrection = 3,
    SystemPromptBuilder? promptBuilder,
  }) : promptBuilder = promptBuilder ?? const SystemPromptBuilder();

  /// Main entry point.
  ///
  /// Throws [ConversationalBuilderUnconfigured] when [provider] reports
  /// `isConfigured == false`, and [ConversationalBuilderException] for
  /// wire-level provider failures (after the first round-trip — we
  /// short-circuit further attempts so the dialog can show a Retry).
  Future<ConversationalBuildResult> buildSequenceFromPrompt({
    required String userPrompt,
    required ConversationalBuilderContext context,
  }) async {
    if (!provider.isConfigured) {
      throw const ConversationalBuilderUnconfigured();
    }
    if (userPrompt.trim().isEmpty) {
      throw const ConversationalBuilderException('User prompt is empty.');
    }

    final systemPrompt = promptBuilder.build(context);

    final rawReplies = <String>[];
    Sequence? bestSequence;
    List<ValidationIssue> bestIssues = const [];
    LlmUsage? aggregateUsage;
    int rounds = 0;

    String currentUserPrompt = _composeInitialUserPrompt(
      userPrompt: userPrompt,
      context: context,
    );

    for (var attempt = 0; attempt <= maxSelfCorrection; attempt++) {
      rounds = attempt + 1;
      final LlmResponse reply;
      try {
        reply = await provider.generate(
          systemPrompt: systemPrompt,
          userPrompt: currentUserPrompt,
        );
      } on LlmProviderException catch (e) {
        // First round — bubble up so the dialog can surface a Retry.
        // Later rounds — also bubble up; the user can retry from the
        // same dialog state.
        throw ConversationalBuilderException(
          'LLM provider error: ${e.message}',
          cause: e,
        );
      }
      rawReplies.add(reply.text);
      aggregateUsage = _accumulate(aggregateUsage, reply.usage);

      // Parse the reply.
      Sequence? candidateSequence;
      List<ValidationIssue> issues;
      try {
        final extracted = extractJsonObject(reply.text);
        final map = jsonDecode(extracted);
        if (map is! Map<String, dynamic>) {
          throw const FormatException('Top-level value is not a JSON object.');
        }
        candidateSequence = fileService.parseFromMap(map);
        issues = validateSequence(candidateSequence);
      } on FormatException catch (e) {
        logging?.debug(
          'Conversational round ${attempt + 1} parse failed: $e',
          source: 'ConversationalBuilder',
        );
        issues = [
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.structure,
            title: 'LLM did not produce valid sequence JSON',
            description: e.message,
            resolutionHint:
                'Re-emit the entire sequence object — only JSON, no prose.',
          ),
        ];
        candidateSequence = null;
      } catch (e) {
        logging?.debug(
          'Conversational round ${attempt + 1} threw $e',
          source: 'ConversationalBuilder',
        );
        issues = [
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.structure,
            title: 'LLM JSON could not be parsed into a Sequence',
            description: e.toString(),
          ),
        ];
        candidateSequence = null;
      }

      // Keep the best attempt — even if invalid, we want to surface
      // *something* the user can inspect rather than a blank state.
      if (candidateSequence != null) {
        bestSequence = candidateSequence;
        bestIssues = issues;
      } else if (bestSequence == null) {
        // No prior parse succeeded — surface this round's issues.
        bestIssues = issues;
      }

      final hasErrors = issues.any(
        (i) => i.severity == ValidationSeverity.error,
      );
      if (!hasErrors) {
        // Success — return immediately.
        return ConversationalBuildResult(
          sequence: candidateSequence,
          validationIssues: issues,
          rounds: rounds,
          totalUsage: aggregateUsage,
          rawReplies: rawReplies,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
        );
      }

      // Compose a correction request for the next round, unless we've
      // exhausted the budget.
      if (attempt == maxSelfCorrection) break;
      currentUserPrompt = _composeCorrectionPrompt(
        previousReply: reply.text,
        issues: issues,
        originalUserPrompt: userPrompt,
      );
    }

    return ConversationalBuildResult(
      sequence: bestSequence,
      validationIssues: bestIssues,
      rounds: rounds,
      totalUsage: aggregateUsage,
      rawReplies: rawReplies,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
    );
  }

  String _composeInitialUserPrompt({
    required String userPrompt,
    required ConversationalBuilderContext context,
  }) {
    final refine = context.refineFrom;
    if (refine != null && refine.rawReplies.isNotEmpty) {
      // Refinement: re-show the previous best reply and ask for an
      // amended version.
      final priorJson = refine.sequence != null
          ? jsonEncode(_sequenceToMap(refine.sequence!))
          : refine.rawReplies.last;
      return [
        'You previously produced this sequence:',
        '```json',
        priorJson,
        '```',
        '',
        'The user now requests the following refinement. Re-emit the '
            'entire updated Sequence JSON (NOT a patch).',
        '',
        'Refinement: $userPrompt',
      ].join('\n');
    }
    return userPrompt;
  }

  String _composeCorrectionPrompt({
    required String previousReply,
    required List<ValidationIssue> issues,
    required String originalUserPrompt,
  }) {
    final issuesBlock = issues
        .map(
          (i) =>
              '- [${i.severity.name.toUpperCase()}] ${i.title}: ${i.description}'
              '${i.resolutionHint != null ? '\n  Resolution hint: ${i.resolutionHint}' : ''}',
        )
        .join('\n');
    return [
      'Your previous reply (verbatim) was:',
      '```',
      previousReply.length > 4000
          ? '${previousReply.substring(0, 4000)}\n…[truncated]…'
          : previousReply,
      '```',
      '',
      'It failed validation with the following issues:',
      issuesBlock,
      '',
      'Re-emit the entire corrected Sequence JSON. Address every issue '
          'above. Output ONLY the JSON object, no prose, no markdown '
          'code fences.',
      '',
      'Original user request: $originalUserPrompt',
    ].join('\n');
  }

  /// Helper used by the refinement path to serialise the prior
  /// Sequence back into the same JSON shape the LLM will produce.
  Map<String, dynamic> _sequenceToMap(Sequence sequence) {
    // The file service's _sequenceToJson is private; we reproduce the
    // public shape by round-tripping through the encoder/decoder used
    // by SequenceFileService.parseFromMap (which expects 'nodes' map
    // + nodeType strings). We rebuild via SequenceImportExportShape
    // below.
    return _serialiseSequence(sequence);
  }

  LlmUsage? _accumulate(LlmUsage? running, LlmUsage? next) {
    if (next == null) return running;
    if (running == null) return next;
    return LlmUsage(
      promptTokens: running.promptTokens + next.promptTokens,
      completionTokens: running.completionTokens + next.completionTokens,
      totalTokens: running.totalTokens + next.totalTokens,
    );
  }
}

/// Extract a JSON object from an LLM reply. The model often wraps its
/// answer in markdown code fences — `\`\`\`json … \`\`\`` — or precedes
/// it with a "Here's the JSON:" preamble even when we asked for JSON
/// only. This helper carves out the first balanced `{...}` substring so
/// the parser sees clean input.
///
/// Public so tests can assert directly against the parser without going
/// through a mock provider.
String extractJsonObject(String raw) {
  // Strip ```json``` / ``` fences.
  final fencedRegex = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
  final fenceMatch = fencedRegex.firstMatch(raw);
  final candidate = fenceMatch?.group(1) ?? raw;

  // Find the first balanced `{...}` block.
  final start = candidate.indexOf('{');
  if (start < 0) {
    throw const FormatException('No JSON object found in LLM reply.');
  }
  var depth = 0;
  var inString = false;
  var escape = false;
  for (var i = start; i < candidate.length; i++) {
    final c = candidate[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (inString) {
      if (c == r'\') {
        escape = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) {
        return candidate.substring(start, i + 1);
      }
    }
  }
  throw const FormatException('JSON object in LLM reply was unbalanced.');
}

/// Round-trip helper used by the refinement path. We use [SequenceFileService]'s
/// public `parseFromMap` on the way *in*; on the way *out* we reproduce the
/// same shape inline so we don't have to expose private internals.
Map<String, dynamic> _serialiseSequence(Sequence sequence) {
  // Shape mirrors the export used by SequenceFileService. We only need
  // the fields necessary for the LLM to recognise the prior sequence —
  // not a 1:1 round-trip with the on-disk schema. We include enough
  // metadata that the model can mutate without losing semantics.
  return <String, dynamic>{
    'schemaVersion': 1,
    'name': sequence.name,
    'description': sequence.description,
    'rootNodeId': sequence.rootNodeId,
    'nodes': sequence.nodes.map((id, node) => MapEntry(id, _nodeOutline(node))),
  };
}

/// A light outline of each node — enough for the LLM to identify and
/// mutate, but free of executor-internal fields that aren't part of the
/// schema the LLM is expected to emit.
Map<String, dynamic> _nodeOutline(SequenceNode node) {
  final base = <String, dynamic>{
    'id': node.id,
    'nodeType': node.nodeType,
    'name': node.name,
    'parentId': node.parentId,
    'childIds': node.childIds,
    'isEnabled': node.isEnabled,
  };
  // Type-specific summary — keep small, focused on the fields the user
  // would refer to in a "use 300s subs instead of 180s" amendment.
  final extras = switch (node) {
    ExposureNode() => <String, dynamic>{
      'durationSecs': node.durationSecs,
      'count': node.count,
      'filter': node.filter,
      'frameType': node.frameType.name,
      'gain': node.gain,
      'offset': node.offset,
    },
    SmartExposureNode() => <String, dynamic>{
      'plans': node.plans
          .map(
            (p) => {
              'filterName': p.filterName,
              'count': p.count,
              'durationSecs': p.durationSecs,
              'ditherEvery': p.ditherEvery,
            },
          )
          .toList(growable: false),
      'rotateFilters': node.rotateFilters,
      'integrationBudgetSecs': node.integrationBudgetSecs,
    },
    TargetHeaderNode() => <String, dynamic>{
      'targetName': node.targetName,
      'raHours': node.raHours,
      'decDegrees': node.decDegrees,
      'minAltitude': node.minAltitude,
    },
    AutofocusNode() => <String, dynamic>{
      'useSettingsDefaults': node.useSettingsDefaults,
    },
    CoolCameraNode() => <String, dynamic>{'targetTemp': node.targetTemp},
    _ => const <String, dynamic>{},
  };
  base.addAll(extras);
  return base;
}

/// Tiny utility used by the system prompt builder to compress filter
/// lists for the prompt header (5 filters max before we summarise).
String compressFilters(List<String> filters) {
  if (filters.length <= 5) return filters.join(', ');
  final head = filters.take(5).join(', ');
  return '$head, … (+${filters.length - 5} more)';
}

/// Re-exported for the dialog UI to format usage in the history line.
String formatUsage(LlmUsage usage) {
  return '${usage.promptTokens} prompt + ${usage.completionTokens} '
      'completion = ${usage.totalTokens} tokens';
}

/// Helper used by the system-prompt builder and the dialog: rounds a
/// duration to a friendly "1.5h" / "30m" string. Kept in this file so
/// the dialog can import it from the same module rather than rolling
/// its own.
String formatHours(double hours) {
  if (hours >= 1.0) {
    return '${hours.toStringAsFixed(1)}h';
  }
  return '${(hours * 60).round()}m';
}
