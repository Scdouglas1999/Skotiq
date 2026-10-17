/// The morning report: what one dawn job integrated, what it drafted, what
/// calibration actually ran, and where the artifacts went.
///
/// Every number here is read from a record that survives a restart — the
/// `integrated_masters` row, the `darkroom_jobs` row, the `delivery_journal` —
/// so a job re-queued after a crash reports the same facts the first attempt
/// would have. Nothing is carried in memory from the integration that produced
/// it.
///
/// The report states omissions as loudly as results: a filter whose master has
/// no file yet, a calibration slot with no master, a draft step the data would
/// not support. A morning report that mentions only what worked is the
/// cry-wolf defect in reverse.
library;

import 'dart:convert';
import 'dart:io';

import '../darkroom_delivery/delivery_artifact.dart';
import '../darkroom_delivery/delivery_service.dart';
import 'dawn_draft_builder.dart';
import 'dawn_master_resolver.dart';

/// One calibration slot's outcome, as the native applied-masters report
/// recorded it at integration time.
class DawnCalibrationSlot {
  /// `dark`, `flat`, or `bias`.
  final String kind;

  /// The master's path, or null when none was applied.
  final String? path;

  /// Whether this correction actually ran over the lights.
  final bool applied;

  /// `exact`, `acceptable`, `unverified`, `fallback`, `missing`, or
  /// `notRequired`.
  final String quality;

  /// Whether age or sensor temperature exceeded this slot's threshold.
  final bool stale;

  /// Dimensions that differ past tolerance, each named.
  final List<String> mismatches;

  /// Dimensions left unjudged because one side's header lacked the keyword.
  final List<String> unverified;

  const DawnCalibrationSlot({
    required this.kind,
    required this.path,
    required this.applied,
    required this.quality,
    required this.stale,
    required this.mismatches,
    required this.unverified,
  });

  /// True when this slot is something the morning report must mention.
  ///
  /// It mirrors the native `CalibrationReport::has_warnings` rule exactly:
  /// a fallback, a missing correction, a match nothing could be verified
  /// against, or a stale master. `notRequired` is not a warning — a matched
  /// dark already carries the bias pedestal, and subtracting a bias as well
  /// would remove it twice.
  bool get isWarning =>
      stale ||
      quality == 'fallback' ||
      quality == 'missing' ||
      quality == 'unverified' ||
      unverified.isNotEmpty;

  /// The report's sentence for this slot, or null when there is nothing to say.
  String? get sentence {
    if (!isWarning) return null;
    if (quality == 'missing') {
      return 'No master $kind was applied, so that correction did not run.';
    }
    final parts = <String>[];
    if (quality == 'fallback') {
      parts.add(
        'the master $kind differs from the lights past tolerance '
        '(${mismatches.join(', ')})',
      );
    }
    if (quality == 'unverified') {
      parts.add(
        'the master $kind could not be compared to the lights on any '
        'dimension, so nothing confirms it matches',
      );
    } else if (unverified.isNotEmpty) {
      parts.add(
        'the master $kind was not comparable on ${unverified.join(', ')}',
      );
    }
    if (stale) {
      parts.add('the master $kind is outside its age or temperature window');
    }
    if (parts.isEmpty) return null;
    return '${_capitalize(parts.first)}${parts.length > 1 ? '; ${parts.skip(1).join('; ')}' : ''}.';
  }

  /// The slot as report JSON.
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'path': path,
    'applied': applied,
    'quality': quality,
    'stale': stale,
    'mismatches': mismatches,
    'unverified': unverified,
    'warning': isWarning,
  };

  static String _capitalize(String value) =>
      value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';
}

/// What one master's integration recorded about itself.
///
/// Parsed from `integrated_masters.stats_json`, which the post-session
/// integration writes at persist time. A field the row does not carry is
/// reported absent rather than filled with a plausible number.
class DawnMasterStats {
  /// Frames that survived rejection and contributed pixels, or null when the
  /// row records none.
  final int? framesIntegrated;

  /// Frames rejected during integration, or null when the row records none.
  final int? framesRejected;

  /// Total integration time in seconds, or null when the row records none.
  final double? totalIntegrationSec;

  /// The applied-masters report, one entry per calibration slot. Empty when
  /// the master predates the report (integrated before this build).
  final List<DawnCalibrationSlot> calibration;

  /// Warnings the Dart calibration matcher raised while choosing the masters.
  final List<String> matcherWarnings;

  /// Whether per-light transient repair ran, or null when unrecorded.
  final bool? cosmeticCorrection;

  /// True when the anchor light's header could not be read, so every dimension
  /// is unverified rather than matched.
  final bool anchorUnreadable;

  const DawnMasterStats({
    required this.framesIntegrated,
    required this.framesRejected,
    required this.totalIntegrationSec,
    required this.calibration,
    required this.matcherWarnings,
    required this.cosmeticCorrection,
    required this.anchorUnreadable,
  });

  /// The empty statement: a master whose row records nothing.
  static const DawnMasterStats unrecorded = DawnMasterStats(
    framesIntegrated: null,
    framesRejected: null,
    totalIntegrationSec: null,
    calibration: <DawnCalibrationSlot>[],
    matcherWarnings: <String>[],
    cosmeticCorrection: null,
    anchorUnreadable: false,
  );

  /// The single flag the morning report branches on — the same thing the
  /// master FITS carries as its `CALWARN` card.
  bool get calibrationWarned =>
      anchorUnreadable ||
      matcherWarnings.isNotEmpty ||
      calibration.any((slot) => slot.isWarning);

  /// One sentence per calibration problem, in slot order.
  List<String> get calibrationSentences => <String>[
    if (anchorUnreadable)
      "The anchor light's header could not be read, so no calibration master "
          'could be compared against it.',
    for (final slot in calibration)
      if (slot.sentence != null) slot.sentence!,
    ...matcherWarnings,
  ];

  /// Parse `integrated_masters.stats_json`.
  ///
  /// A payload that is not a JSON object is reported [unrecorded]: the column
  /// is written by this app, so an unreadable value describes a master this
  /// build cannot account for, and inventing frame counts for it would put
  /// numbers in the morning report that nothing measured.
  static DawnMasterStats parse(String statsJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(statsJson);
    } on FormatException {
      return unrecorded;
    }
    if (decoded is! Map<String, dynamic>) return unrecorded;

    final calibration = decoded['calibration'];
    final slots = <DawnCalibrationSlot>[];
    var anchorUnreadable = false;
    bool? cosmetic;
    if (calibration is Map<String, dynamic>) {
      final anchor = calibration['anchorUnreadable'];
      anchorUnreadable = anchor is bool && anchor;
      final cosmeticRaw = calibration['cosmeticCorrection'];
      if (cosmeticRaw is bool) cosmetic = cosmeticRaw;
      final masters = calibration['masters'];
      if (masters is List) {
        for (final entry in masters) {
          if (entry is! Map<String, dynamic>) continue;
          final kind = entry['kind'];
          if (kind is! String) continue;
          slots.add(
            DawnCalibrationSlot(
              kind: kind,
              path: entry['path'] is String ? entry['path'] as String : null,
              applied: entry['applied'] == true,
              quality: entry['quality'] is String
                  ? entry['quality'] as String
                  : 'unverified',
              stale: entry['stale'] == true,
              mismatches: _mismatchNames(entry['mismatches']),
              unverified: _stringList(entry['unverified']),
            ),
          );
        }
      }
    }

    return DawnMasterStats(
      framesIntegrated: _asInt(decoded['framesIntegrated']),
      framesRejected: _asInt(decoded['framesRejected']),
      totalIntegrationSec: _asDouble(decoded['totalIntegrationSec']),
      calibration: List.unmodifiable(slots),
      matcherWarnings: _stringList(decoded['calibrationWarnings']),
      cosmeticCorrection: cosmetic,
      anchorUnreadable: anchorUnreadable,
    );
  }

  static int? _asInt(Object? value) => value is num ? value.toInt() : null;

  static double? _asDouble(Object? value) =>
      value is num ? value.toDouble() : null;

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return List.unmodifiable(<String>[
      for (final entry in value)
        if (entry is String) entry,
    ]);
  }

  static List<String> _mismatchNames(Object? value) {
    if (value is! List) return const [];
    final out = <String>[];
    for (final entry in value) {
      if (entry is! Map<String, dynamic>) continue;
      if (entry['withinTolerance'] == true) continue;
      final dimension = entry['dimension'];
      final light = entry['light'];
      final master = entry['master'];
      if (dimension is! String) continue;
      out.add(
        light is String && master is String
            ? '$dimension: lights $light, master $master'
            : dimension,
      );
    }
    return List.unmodifiable(out);
  }
}

/// What a master's file was at one instant — its size, its modification time,
/// and the SHA-256 of the bytes themselves.
///
/// Taken when the pass opens the master to read its pixels, and taken again
/// when delivery stages that same path. The two are compared because they are
/// separated by everything the draft stage does: a file that is a different
/// size, carries a different modification time, or hashes differently at the
/// second reading is not the file this pass measured, whatever its name still
/// says.
///
/// **Why the digest and not size + mtime alone.** Size and mtime are metadata
/// a writer chooses. `rsync --times`, `cp -p` and `restic restore` all put a
/// file back under its old modification time, and a filesystem with two-second
/// mtime granularity (SMB, exFAT) cannot distinguish two writes inside one
/// tick. A master overwritten by a same-sized file with a restored mtime
/// therefore matched on both fields and rode out to every destination under the
/// name of the master this pass had actually drafted. The digest is the only
/// field that answers "are these the same bytes", so it is the one the
/// comparison turns on; size and mtime stay because they are what the refusal
/// sentence quotes back to the operator.
///
/// **Cost.** One extra streamed read + SHA-256 per master over the whole pass.
/// The draft stage's reading is new; the staging reading is handed to delivery,
/// which used to hash the same bytes itself. Measured with this SHA-256
/// compiled AOT on the machine this was written on: 0.16 GB/s — 48 ms for an
/// 8.3 MB master, 770 ms for a 132.7 MB one, about 25 s for a 4 GB one, against
/// a pass that spends minutes rendering each of them. Staging short-circuits
/// too: a size or mtime difference is stated without hashing, because it has
/// already proved the file changed.
class DawnSourceStat {
  /// Size in bytes.
  final int bytes;

  /// Last modification time as the filesystem reports it.
  final DateTime modified;

  /// Lowercase hex SHA-256 of the file's bytes at this instant.
  final String digest;

  const DawnSourceStat({
    required this.bytes,
    required this.modified,
    required this.digest,
  });

  /// Stat and hash [path], or null when there is no file there at all.
  ///
  /// A null is not "unchanged": callers state which reading is missing rather
  /// than treating an unmeasurable file as a match. A file that exists but
  /// whose bytes cannot be read raises the [DeliveryFailure] `sha256OfFile`
  /// composes, so the caller names the reason instead of reporting the file as
  /// absent.
  static Future<DawnSourceStat?> of(String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return DawnSourceStat(
      bytes: stat.size,
      modified: stat.modified,
      digest: await sha256OfFile(File(path)),
    );
  }

  /// True when [other] is the same file contents this reading saw.
  bool matches(DawnSourceStat other) => digest == other.digest;

  /// True when [other] carries the same size and modification time — the
  /// metadata pair a refusal quotes, which says nothing about the bytes.
  bool metadataMatches(DawnSourceStat other) =>
      bytes == other.bytes && modified.isAtSameMomentAs(other.modified);

  /// The reading as report JSON.
  Map<String, dynamic> toJson() => {
    'bytes': bytes,
    'modified': modified.toUtc().toIso8601String(),
    'sha256': digest,
  };
}

/// One master's line in the morning report.
class DawnMasterReport {
  /// The master itself.
  final DawnMaster master;

  /// The target's name, or null when the master carries no target row.
  final String? targetName;

  /// What the integration recorded.
  final DawnMasterStats stats;

  /// The first draft, or null when one could not be composed.
  final DawnDraft? draft;

  /// The `recipes.id` the draft was persisted as, or null when it was not.
  final int? recipeId;

  /// Path of the rendered draft image, or null when no render was produced.
  final String? draftRenderPath;

  /// Why this master has no draft, or null when it has one.
  final String? failure;

  /// What the master's file was when this pass opened it to read its pixels,
  /// or null when it could not be stat-ed then.
  ///
  /// Delivery re-reads the same file later and compares; see
  /// [withheldFromDelivery].
  final DawnSourceStat? sourceAtRead;

  /// Why delivery staging refused this master's file, or null when it was
  /// staged (or never a candidate).
  ///
  /// Written by the delivery stage, not the draft stage: the draft stage's
  /// verdict is [failure].
  final String? withheldFromDelivery;

  const DawnMasterReport({
    required this.master,
    required this.targetName,
    required this.stats,
    required this.draft,
    required this.recipeId,
    required this.draftRenderPath,
    required this.failure,
    this.sourceAtRead,
    this.withheldFromDelivery,
  });

  /// This line with the delivery stage's refusal recorded on it.
  DawnMasterReport withheldAtStaging(String reason) => DawnMasterReport(
    master: master,
    targetName: targetName,
    stats: stats,
    draft: draft,
    recipeId: recipeId,
    draftRenderPath: draftRenderPath,
    failure: failure,
    sourceAtRead: sourceAtRead,
    withheldFromDelivery: reason,
  );

  /// True when a draft image exists for this master.
  bool get hasDraft => draftRenderPath != null;

  /// True when the pipeline actually read this master's pixels.
  ///
  /// [draft] is the composition the registry answered with, and the registry
  /// only answers after it has opened the FITS and measured it. A null draft
  /// therefore means the read itself failed — a truncated file, a path that
  /// vanished — while a non-null draft with a [failure] means the pixels were
  /// read and a later stage (the export, the step measurement) stopped.
  ///
  /// This is the TIME OF CHECK. It says what was true when the draft was
  /// composed, which is minutes before delivery copies anything, so it is only
  /// half the gate — [deliverable] is the other half.
  bool get pixelsWereRead => draft != null;

  /// True when this master's file goes to a destination.
  ///
  /// Both halves must hold: the pass read these pixels, AND the file delivery
  /// staged is still the file the pass read. A master that satisfies only the
  /// first was measured and then changed underneath the job, and copying it out
  /// would put bytes the pipeline never measured in the operator's hands under
  /// the name of the night's result.
  bool get deliverable => pixelsWereRead && withheldFromDelivery == null;

  /// Why this master reached no destination, or null when it did.
  String? get notDeliveredBecause {
    if (withheldFromDelivery != null) return withheldFromDelivery;
    if (pixelsWereRead) return null;
    return failure ?? 'its pixels could not be read';
  }

  /// The master as report JSON.
  Map<String, dynamic> toJson() => {
    'masterId': master.masterId,
    'name': master.name,
    'targetName': targetName,
    'filter': master.filter,
    'channels': master.channels,
    'masterFitsPath': master.masterFitsPath,
    'framesFolded': master.frameCount,
    'framesIntegrated': stats.framesIntegrated,
    'framesRejected': stats.framesRejected,
    'integrationSeconds': master.totalIntegrationSeconds,
    'calibrationWarned': stats.calibrationWarned,
    'calibration': [for (final slot in stats.calibration) slot.toJson()],
    'calibrationSentences': stats.calibrationSentences,
    'recipeId': recipeId,
    'draftRenderPath': draftRenderPath,
    'draftSteps': draft == null ? const <Map<String, dynamic>>[] : draft!.steps,
    'draftNotes': draft == null
        ? const <Map<String, dynamic>>[]
        : [for (final note in draft!.notes) note.toJson()],
    'failure': failure,
    'sourceAtRead': sourceAtRead?.toJson(),
    'withheldFromDelivery': withheldFromDelivery,
  };
}

/// What a copy of the night report was written too early to know.
///
/// The report is itself one of the delivered artifacts, so the copy delivery
/// hands to a destination has to exist on disk BEFORE delivery runs — and it
/// therefore can never contain delivery's own outcome, nor the morning
/// notification that follows delivery. The rig rewrites its local copy once
/// both are decided; the copy already in the operator's hands is never
/// rewritten, because delivery names each artifact once and never overwrites a
/// name it has already handed over.
///
/// So that copy states the gap rather than leaving it to be read out of two
/// nulls: [blocks] names the report keys it has no outcome for, and [note] is
/// the sentence the operator reads.
class DawnReportPending {
  /// The report's own top-level keys this copy has no outcome for.
  final List<String> blocks;

  /// Why this copy has none of them, and where the filled-in ones are.
  final String note;

  const DawnReportPending({required this.blocks, required this.note});

  /// The copy delivery itself ships.
  static const DawnReportPending beforeDelivery = DawnReportPending(
    blocks: <String>['delivery', 'notification'],
    note:
        'This copy left the rig while delivery was in progress, so it carries '
        'no delivery or notification outcome; the copy on the rig carries '
        'both. Everything else here is final — these are the masters the pass '
        'integrated and the drafts it rendered, and finishedAt is when that '
        'drafting finished.',
  );

  /// The pending block as report JSON.
  Map<String, dynamic> toJson() => {'blocks': blocks, 'note': note};
}

/// Whether the morning notification was sent, and why.
class DawnNotificationDecision {
  /// True when the notification reached at least one transport.
  final bool sent;

  /// Why it was or was not sent, naming the flag that decided.
  final String reason;

  const DawnNotificationDecision({required this.sent, required this.reason});

  /// The decision as report JSON.
  Map<String, dynamic> toJson() => {'sent': sent, 'reason': reason};
}

/// The whole job's morning report.
class DawnJobReport {
  /// The `darkroom_jobs.id` this report belongs to.
  final int jobId;

  /// `dawn` or `manual`.
  final String kind;

  /// The session processed.
  final int sessionId;

  /// When the job started, UTC.
  final DateTime startedAt;

  /// When the job finished, UTC — or, on a copy carrying [pending], when the
  /// drafting this copy reports finished.
  final DateTime finishedAt;

  /// The job's final state, as the row records it — or [deliveringState] on a
  /// copy written while delivery was still running.
  final String state;

  /// One entry per master with a linear FITS.
  final List<DawnMasterReport> masters;

  /// Masters the night touched that have no file to draft over.
  final List<DawnMasterWithoutFile> withoutFile;

  /// What delivery did, or null when delivery did not run.
  final DeliveryRunReport? delivery;

  /// One sentence per delivery problem, each naming its mechanism.
  final List<String> deliveryProblems;

  /// The notification decision, or null for a job that does not notify.
  final DawnNotificationDecision? notification;

  /// Why the job stopped short, or null when it ran to the end.
  final String? failure;

  /// What this copy of the report was written too early to know, or null when
  /// it knows everything the job produced.
  final DawnReportPending? pending;

  const DawnJobReport({
    required this.jobId,
    required this.kind,
    required this.sessionId,
    required this.startedAt,
    required this.finishedAt,
    required this.state,
    required this.masters,
    required this.withoutFile,
    required this.delivery,
    required this.deliveryProblems,
    required this.notification,
    required this.failure,
    this.pending,
  });

  /// The [state] a copy written while delivery was still running carries.
  ///
  /// No `darkroom_jobs` row ever holds this string — the ROW is `running` at
  /// that instant, and the report is not the row. It exists so the delivered
  /// artifact does not have to borrow the row's word for a moment the row's
  /// vocabulary cannot describe: `running` printed beside a `finishedAt` and
  /// two null outcome blocks reads as a job that stopped without finishing,
  /// which is the one thing that had not happened. `delivering`, beside
  /// [pending], reads as what it is — the drafting is over, the copying is
  /// not.
  static const String deliveringState = 'delivering';

  /// Frames that contributed pixels across every master, counting only the
  /// masters whose row records the number.
  int get framesUsed => masters.fold<int>(
    0,
    (sum, m) => sum + (m.stats.framesIntegrated ?? m.master.frameCount),
  );

  /// Frames rejected across every master whose row records the number.
  int get framesRejected => masters.fold<int>(0, (sum, m) {
    final rejected = m.stats.framesRejected;
    return rejected == null ? sum : sum + rejected;
  });

  /// Total integration seconds across every master, drafted or not.
  ///
  /// This is what the NIGHT integrated, which is not what the drafts cover —
  /// see [draftedIntegrationSeconds]. Both are in the JSON, because a master
  /// that failed to draft was still integrated and its seconds are still real.
  double get integrationSeconds => masters.fold<double>(
    0.0,
    (sum, m) => sum + m.master.totalIntegrationSeconds,
  );

  /// Integration seconds behind the drafts this job actually rendered.
  ///
  /// The headline pairs this with [draftsRendered] so its two numbers are
  /// about the same masters. A total folded over every master and printed
  /// beside a draft count that excludes one of them made the same night read
  /// 24 s or 18 s depending only on HOW the fourth master failed: an
  /// unreadable master stays in [masters] and carries its seconds into the
  /// total, while a master with no path is diverted to [withoutFile] and
  /// carries nothing.
  double get draftedIntegrationSeconds => masters
      .where((m) => m.hasDraft)
      .fold<double>(0.0, (sum, m) => sum + m.master.totalIntegrationSeconds);

  /// Drafts rendered by this job.
  int get draftsRendered => masters.where((m) => m.hasDraft).length;

  /// Masters this night has that carry no draft, however they failed: read and
  /// not drafted, or never read because the row names no file.
  int get _undraftedMasterCount =>
      masters.where((m) => !m.hasDraft).length + withoutFile.length;

  /// True when any master's calibration is something the operator must know
  /// about — the same thing the master FITS records as `CALWARN`.
  bool get calibrationWarned => masters.any((m) => m.stats.calibrationWarned);

  /// Every calibration sentence across every master, prefixed by the master it
  /// belongs to.
  List<String> get calibrationSentences => <String>[
    for (final master in masters)
      for (final sentence in master.stats.calibrationSentences)
        '${master.master.name}: $sentence',
  ];

  /// The target this night was about, when every master shares one.
  String? get primaryTargetName {
    final names = masters
        .map((m) => m.targetName)
        .whereType<String>()
        .where((name) => name.trim().isNotEmpty)
        .toSet();
    return names.length == 1 ? names.single : null;
  }

  /// The same report recorded under another [state], carrying [failure].
  ///
  /// The pipeline uses it to rewrite the report as the ending the job row
  /// actually took, so the artifact on disk can never announce a state the row
  /// never reached. [pending] rides along unchanged: what a copy knows is a
  /// fact about the copy, not about the ending.
  DawnJobReport withEnding({required String state, String? failure}) =>
      DawnJobReport(
        jobId: jobId,
        kind: kind,
        sessionId: sessionId,
        startedAt: startedAt,
        finishedAt: finishedAt,
        state: state,
        masters: masters,
        withoutFile: withoutFile,
        delivery: delivery,
        deliveryProblems: deliveryProblems,
        notification: notification,
        failure: failure ?? this.failure,
        pending: pending,
      );

  /// The notification's title line.
  ///
  /// A night that rendered nothing says so. "Your 0 drafts are ready" reads as
  /// a successful delivery of nothing, which is the cry-wolf shape in reverse:
  /// the operator has to open the report to learn that the headline was about
  /// an empty hand.
  ///
  /// The integration total is [draftedIntegrationSeconds] — exactly the drafts
  /// the same sentence counts — and a master that produced none is named right
  /// there rather than folded into the total in silence. The night's own total
  /// stays in [integrationSeconds] and in the body, and the two reconcile:
  /// drafted seconds plus the clause's seconds are the night's.
  String get headline {
    final target = primaryTargetName;
    if (draftsRendered == 0) {
      return '${target ?? 'Your night'} — no draft was rendered; '
          '${formatDawnIntegration(integrationSeconds)} integrated';
    }
    final time = formatDawnIntegration(draftedIntegrationSeconds);
    final lead = target == null
        ? (draftsRendered == 1
              ? 'Your draft is ready — $time integrated'
              : 'Your $draftsRendered drafts are ready — $time integrated')
        : '$target — $time integrated';
    return '$lead$_undraftedClause';
  }

  /// What the headline's total leaves out, or an empty string when it leaves
  /// nothing out.
  ///
  /// The seconds it names are the ones this report can account for: a master
  /// in [withoutFile] has no row of integration to quote, so it is counted as
  /// a master and no time is invented for it.
  String get _undraftedClause {
    final undrafted = _undraftedMasterCount;
    if (undrafted == 0) return '';
    final seconds = masters
        .where((m) => !m.hasDraft)
        .fold<double>(0.0, (sum, m) => sum + m.master.totalIntegrationSeconds);
    final subject = undrafted == 1 ? '1 master has' : '$undrafted masters have';
    if (seconds <= 0) return '; $subject no draft';
    return '; $subject no draft '
        '(${formatDawnIntegration(seconds)} more integrated)';
  }

  /// The notification's body: what was integrated, what was rejected, what the
  /// calibration did, whether a draft exists, and where it went.
  String get body {
    final lines = <String>[];
    lines.add(
      '$framesUsed frame${framesUsed == 1 ? '' : 's'} used, '
      '$framesRejected rejected.',
    );
    if (draftsRendered > 0) {
      lines.add(
        '$draftsRendered draft${draftsRendered == 1 ? '' : 's'} ready to open '
        'in the Darkroom.',
      );
    } else {
      lines.add('No draft was rendered; the report says why.');
    }
    for (final master in masters) {
      if (master.failure != null) {
        lines.add('${master.master.name}: ${master.failure}');
      }
    }
    for (final missing in withoutFile) {
      lines.add('${missing.name}: ${missing.reason}');
    }
    if (calibrationWarned) {
      lines.addAll(calibrationSentences);
    }
    final deliveryReport = delivery;
    if (deliveryReport != null) {
      lines.add('Delivery — ${deliveryReport.summary}.');
    }
    // Outside the `delivery != null` arm: the problems that matter most are the
    // ones raised when nothing could be handed to a destination at all, and
    // those are exactly the runs where there is no destination report to nest
    // them under.
    lines.addAll(deliveryProblems);
    final stopped = failure;
    if (stopped != null) lines.add(stopped);
    // Last, and in the same prose as the rest: a reader who never opens the
    // JSON keys still learns that this copy's delivery line is missing because
    // it was written first, not because delivery did nothing.
    final unknown = pending;
    if (unknown != null) lines.add(unknown.note);
    return lines.join('\n');
  }

  /// The report as the JSON artifact delivery ships as the night report.
  Map<String, dynamic> toJson() => {
    'jobId': jobId,
    'kind': kind,
    'sessionId': sessionId,
    'state': state,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    'framesUsed': framesUsed,
    'framesRejected': framesRejected,
    'integrationSeconds': integrationSeconds,
    // The night's total and the drafts' total are different facts, and the
    // headline quotes the second one. Both are here so a reader never has to
    // re-derive one from the master list to check the sentence.
    'draftedIntegrationSeconds': draftedIntegrationSeconds,
    'draftsRendered': draftsRendered,
    'calibrationWarned': calibrationWarned,
    'headline': headline,
    'body': body,
    'masters': [for (final master in masters) master.toJson()],
    'mastersWithoutFile': [
      for (final missing in withoutFile)
        {
          'masterId': missing.masterId,
          'name': missing.name,
          'reason': missing.reason,
        },
    ],
    'delivery': delivery == null
        ? null
        : {
            'summary': delivery!.summary,
            'delivered': delivery!.delivered,
            // Apart from `delivered`, which is what this pass sent. These are
            // files an earlier pass had already delivered, so a re-queued job
            // does not read as a night that lost them.
            'alreadyDelivered': delivery!.alreadyDelivered,
            'awaitingPull': delivery!.awaitingPull,
            'retrying': delivery!.retrying,
            // Apart from `retrying`, which is files an attempt was spent on.
            // These are files a stop reached first; both are owed, and only
            // this one says the pass was cut short.
            'stoppedPending': delivery!.stoppedPending,
            'failed': delivery!.failed,
            'problems': deliveryProblems,
          },
    // Also at the top level, because a run that delivered nothing has no
    // `delivery` object to carry its problems and those are the runs whose
    // problems the operator most needs.
    'deliveryProblems': deliveryProblems,
    'notification': notification?.toJson(),
    'failure': failure,
    // Every key above keeps the type it has always had, so a consumer that
    // reads `state`, `delivery` or `notification` still parses this copy. This
    // one says which of them are absent because the copy predates them —
    // absent from the copy, not absent from the night.
    'pending': pending?.toJson(),
  };
}

/// Format integration seconds as `3h 12m`, `42m`, `24 s`, or `0m`.
///
/// Named for the dawn report rather than generically: the app already exports a
/// `formatIntegration` of its own, and two same-named helpers imported into one
/// library is an ambiguity the compiler reports at every call site.
///
/// A night under a minute states its SECONDS. Rounding everything to whole
/// minutes printed `0m` for the 24 s the same report recorded as
/// `integrationSeconds: 24.0` — the identical string the first branch reserves
/// for a night that integrated nothing, so the operator's one dawn line could
/// not tell a short night from an empty one.
///
/// The sub-minute branch rounds UP so a fraction of a second never collapses
/// back onto the `0` the zero branch owns; it overstates by less than a second
/// and never by a unit the headline shows.
String formatDawnIntegration(double seconds) {
  if (seconds <= 0) return '0m';
  final wholeSeconds = seconds.ceil();
  if (wholeSeconds < 60) return '$wholeSeconds s';
  final totalMinutes = (seconds / 60).round();
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours <= 0) return '${minutes}m';
  return '${hours}h ${minutes}m';
}
