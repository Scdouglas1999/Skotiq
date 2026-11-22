// The Darkroom engine's and the master builder's JSON replies, read in one
// place. Their keys are the native side's (processing/src/darkroom/
// entrypoints.rs, export.rs, post_session/multi_night.rs); the samples in
// test_fixtures/ffi_replies/ are written from those replies by Rust tests and
// read by test/services/darkroom_replies_fixture_test.dart.

/// One note a `registry` draft records about an operation it decided on.
///
/// The words are as the engine wrote them; a caller that shows a note picks
/// its own words for a missing outcome or reason.
typedef DarkroomDraftNoteReply = ({
  String opId,
  String? outcome,
  String? reason,
});

/// The first-draft recipe a `registry` reply carries for a master.
class DarkroomRegistryDraft {
  const DarkroomRegistryDraft({
    required this.recipe,
    required this.steps,
    required this.notes,
  });

  /// The reply's `draft`, or null when it carries none (a registry asked
  /// without a master).
  static DarkroomRegistryDraft? of(Map<String, dynamic> reply) {
    final draft = reply['draft'];
    if (draft is! Map<String, dynamic>) return null;
    final recipe = draft['recipe'];
    final steps = recipe is Map<String, dynamic> ? recipe['steps'] : null;
    return DarkroomRegistryDraft(
      recipe: recipe is Map<String, dynamic> ? recipe : null,
      steps: steps is List ? steps : null,
      notes: _notes(draft['notes']),
    );
  }

  /// The drafted recipe, or null when the draft names none.
  final Map<String, dynamic>? recipe;

  /// The recipe's steps as the engine wrote them, or null when the recipe
  /// carries no step list.
  final List<Object?>? steps;

  /// The notes in the order the engine wrote them; entries without an
  /// operation id are left out.
  final List<DarkroomDraftNoteReply> notes;

  /// The parameters of the draft's first step running [opId], or null when
  /// it has no such step.
  Map<String, dynamic>? paramsOf(String opId) {
    for (final step in steps ?? const <Object?>[]) {
      if (step is Map && step['opId'] == opId) {
        final params = step['params'];
        return params is Map<String, dynamic> ? params : null;
      }
    }
    return null;
  }

  static List<DarkroomDraftNoteReply> _notes(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map<String, dynamic> && entry['opId'] is String)
          (
            opId: entry['opId'] as String,
            outcome: entry['outcome'] is String
                ? entry['outcome'] as String
                : null,
            reason: entry['reason'] is String
                ? entry['reason'] as String
                : null,
          ),
    ];
  }
}

/// One file a `renderExport` wrote.
class DarkroomExportOutput {
  const DarkroomExportOutput({
    this.format,
    this.path,
    this.bytes,
    this.width,
    this.height,
    this.clampedSamples,
    this.quality,
  });

  factory DarkroomExportOutput.fromJson(Map<String, dynamic> json) =>
      DarkroomExportOutput(
        format: json['format'] is String ? json['format'] as String : null,
        path: json['path'] is String ? json['path'] as String : null,
        bytes: json['bytes'] is int ? json['bytes'] as int : null,
        width: json['width'] is int ? json['width'] as int : null,
        height: json['height'] is int ? json['height'] as int : null,
        clampedSamples: json['clampedSamples'] is int
            ? json['clampedSamples'] as int
            : null,
        quality: json['quality'] is int ? json['quality'] as int : null,
      );

  final String? format;
  final String? path;
  final int? bytes;
  final int? width;
  final int? height;
  final int? clampedSamples;

  /// JPEG quality; null for the other formats.
  final int? quality;
}

/// What a `renderExport` reply says it wrote.
class DarkroomExportReply {
  const DarkroomExportReply({
    required this.outputs,
    this.sidecarPath,
    this.sidecarSkippedReason,
    this.sourceDomain,
    required this.screenTransferApplied,
    this.recipeFingerprint,
  });

  factory DarkroomExportReply.fromJson(Map<String, dynamic> json) {
    final outputs = json['outputs'];
    String? text(String key) =>
        json[key] is String ? json[key] as String : null;
    return DarkroomExportReply(
      outputs: [
        if (outputs is List)
          for (final entry in outputs)
            if (entry is Map<String, dynamic>)
              DarkroomExportOutput.fromJson(entry),
      ],
      sidecarPath: text('sidecarPath'),
      sidecarSkippedReason: text('sidecarSkippedReason'),
      sourceDomain: text('sourceDomain'),
      screenTransferApplied: json['screenTransfer'] != null,
      recipeFingerprint: text('recipeFingerprint'),
    );
  }

  final List<DarkroomExportOutput> outputs;

  /// Where the recipe sidecar was written, when it was.
  final String? sidecarPath;

  /// Why no sidecar was written, when none was.
  final String? sidecarSkippedReason;

  /// `linear` or `stretched`: the pixels the export started from.
  final String? sourceDomain;

  /// Whether the engine's auto stretch was applied to the 8/16-bit files.
  final bool screenTransferApplied;
  final String? recipeFingerprint;
}

/// One filter of a master build: the builder's reply for it (or the brief the
/// build job keeps of it), or the failure the build recorded instead.
class DarkroomFilterBuild {
  const DarkroomFilterBuild({
    required this.filter,
    this.error,
    this.frameCount,
    this.totalIntegrationSec,
    this.skippedCount,
  });

  factory DarkroomFilterBuild.fromJson(Map<dynamic, dynamic> json) {
    final skipped = json['skipped'];
    final frames = json['frameCount'];
    final seconds = json['totalIntegrationSec'];
    return DarkroomFilterBuild(
      filter: '${json['filter']}',
      error: json['error'],
      frameCount: frames is num ? frames.toInt() : null,
      totalIntegrationSec: seconds is num ? seconds.toDouble() : null,
      skippedCount: skipped is List ? skipped.length : null,
    );
  }

  final String filter;

  /// Why the filter was not built; null for a built one.
  final Object? error;
  final int? frameCount;
  final double? totalIntegrationSec;

  /// The subs the build left out, or null when the record does not say (the
  /// brief a saved job keeps has no list).
  final int? skippedCount;
}
