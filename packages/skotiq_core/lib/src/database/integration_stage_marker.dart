import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Durable "an integration is in flight" marker for the post-session pass.
///
/// WHY A FILE, next to the database, rather than a row: the pass this covers
/// runs BEFORE any `darkroom_jobs` row exists. `AutoIntegrationService`
/// integrates or folds every filter bucket first and only then enqueues the
/// Darkroom job, so a kill during the integrate — the longest, most
/// interruptible stretch of the night — left nothing at all behind: no job row
/// to re-queue, no session note, no log the operator sees. The night simply
/// went quiet, and the half-written master on disk looked like a finished one.
///
/// The file is the same mechanism `integrity_check.dart` already uses for
/// `.recovered-on-*.txt` and `.restore-pending.txt`: written with `flush: true`
/// so it survives a `kill -9` or a power cut, and read on the next open before
/// anything can overwrite it. It deliberately does NOT use `darkroom_jobs` —
/// that table's `kind` column is constrained to `dawn`/`manual` and its
/// open-time recovery RE-QUEUES what it finds, which is the wrong answer for a
/// half-integrated stack whose output files are already suspect.
///
/// Its one prefix is distinct from every marker `integrity_check.dart` globs,
/// so a restore or a corruption recovery never consumes it and it never
/// consumes theirs.
const String kIntegrationMarkerName = '.integration-in-flight.json';

/// `narrator_events.event_type` the open-time report writes when it finds a
/// marker a dead process left behind.
///
/// Shared so the writer (the `beforeOpen` reporter) and the readers (the
/// morning feed, and Session Review's own banner) cannot drift onto two
/// spellings of one event — a session whose interruption is recorded but
/// matches nothing on screen is the silence this whole mechanism exists to
/// end.
const String kInterruptedPassEventType = 'quality.integration_interrupted';

/// How far the post-session pass had got when the marker was last written.
///
/// The marker's window covers the integrate AND the Darkroom pass that follows
/// it, and for a long time its mere presence was the whole story — so a kill
/// landing anywhere in that window was reported as an interrupted integrate.
/// The seam that made that a lie is the one the pass cannot compose into a
/// single transaction: the masters are finalized by
/// `PostSessionIntegrationService`, bucket by bucket, and the `darkroom_jobs`
/// row is inserted afterwards by the autopilot. A crash in between left a night
/// whose masters were whole and registered and whose drafts, night report,
/// delivery and morning message were never queued — and the report told the
/// operator to run the integration again.
///
/// This is the durable answer to "which of those had happened". It is advanced
/// at the instant each becomes true, so the next open reads a fact rather than
/// inferring one.
enum PostSessionPassStage {
  /// Masters are being written. A kill here can leave one half-written, and
  /// re-running the integration is what the night needs.
  integrating,

  /// Every master this pass set out to write is written and registered, and the
  /// Darkroom pass that owes the drafts, the night report, the delivery and the
  /// morning message has not been queued yet. A kill here needs the PASS, never
  /// the integration.
  darkroomPassOwed,

  /// Every master is written and registered, and automatic drafting is switched
  /// off for this profile, so nothing further was owed. A kill here cost the
  /// night nothing.
  mastersOnly;

  /// The string stored in the marker payload.
  String get wire => name;

  /// Parse a stored stage.
  ///
  /// Anything this build does not recognise — including the absent field of a
  /// marker written before the stage existed — reads as [integrating]. A marker
  /// that does not say how far the pass got has not earned the claim that the
  /// masters are finished, and stating one anyway is how an operator is told
  /// their half-written stack arrived intact.
  static PostSessionPassStage fromWire(Object? value) {
    for (final stage in PostSessionPassStage.values) {
      if (stage.wire == value) return stage;
    }
    return PostSessionPassStage.integrating;
  }
}

/// What a previous process was integrating when it died.
class InterruptedIntegration {
  /// The imaging session whose subs were being integrated.
  final int sessionId;

  /// The target as it was named when the pass started, or null when the
  /// session's frames carried no target.
  final String? targetName;

  /// When the integration started, in UTC.
  final DateTime startedAtUtc;

  /// The master files the pass was going to write.
  ///
  /// Named in the report because these are the files that are now in question:
  /// a process killed mid-write leaves a FITS that is present, non-empty, and
  /// truncated, and an operator told only "the integration was interrupted"
  /// would reasonably open one and trust it. Which of them is actually
  /// half-written is measured — see [presentMasterFiles] — never assumed from
  /// the fact that the pass was interrupted.
  final List<String> intendedMasterPaths;

  /// How far the pass had got when this marker was last written.
  final PostSessionPassStage stage;

  const InterruptedIntegration({
    required this.sessionId,
    required this.targetName,
    required this.startedAtUtc,
    required this.intendedMasterPaths,
    this.stage = PostSessionPassStage.integrating,
  });

  /// The same pass, recorded at [stage].
  ///
  /// Everything else is carried over unchanged: the session, the target and the
  /// intended paths are facts about the pass, not about how far it got, and the
  /// start instant is what the report and the event's dedupe key are keyed on —
  /// re-stamping it would make one interruption look like two.
  InterruptedIntegration at(PostSessionPassStage stage) =>
      InterruptedIntegration(
        sessionId: sessionId,
        targetName: targetName,
        startedAtUtc: startedAtUtc,
        intendedMasterPaths: intendedMasterPaths,
        stage: stage,
      );

  /// What each intended master file actually turned out to be, for the ones
  /// that are on disk right now.
  ///
  /// Paths that were never created are left out, so the report can say "delete
  /// these two" without listing files that do not exist. The ones that ARE
  /// there are opened and measured rather than assumed: the process died
  /// somewhere in a run that writes each master start to finish, so some of
  /// its intended files are half-written and some are whole. Telling an
  /// operator that a whole master is "truncated — delete it" is telling them
  /// to delete a night's finished data.
  Future<List<IntendedMasterFile>> presentMasterFiles() async {
    final present = <IntendedMasterFile>[];
    for (final path in intendedMasterPaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      present.add(await IntendedMasterFile.measure(file));
    }
    return present;
  }

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'targetName': targetName,
    'startedAtUtc': startedAtUtc.toUtc().toIso8601String(),
    'intendedMasterPaths': intendedMasterPaths,
    'stage': stage.wire,
  };

  /// Parse a marker payload, or null when the file is not one this app wrote.
  ///
  /// A marker we cannot read is reported as "no marker" rather than as a
  /// malformed interruption: the only action it drives is a warning, and
  /// inventing a session id to warn about would be worse than the silence this
  /// whole mechanism exists to end. The unreadable file is left on disk for
  /// support instead of being silently deleted.
  static InterruptedIntegration? fromJson(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final sessionId = decoded['sessionId'];
    final startedAt = DateTime.tryParse('${decoded['startedAtUtc']}');
    if (sessionId is! int || startedAt == null) return null;
    final paths = decoded['intendedMasterPaths'];
    return InterruptedIntegration(
      sessionId: sessionId,
      targetName: decoded['targetName'] as String?,
      startedAtUtc: startedAt.toUtc(),
      intendedMasterPaths: paths is List
          ? paths.whereType<String>().toList(growable: false)
          : const [],
      stage: PostSessionPassStage.fromWire(decoded['stage']),
    );
  }
}

/// One intended master file as it is on disk, measured rather than assumed.
class IntendedMasterFile {
  /// Where the file is.
  final String path;

  /// True when the file holds a whole FITS: its length is a whole number of
  /// 2880-byte blocks and it carries at least the bytes its own primary header
  /// declares.
  final bool complete;

  /// What the measurement found, in the words the report prints. Names the
  /// shortfall for an incomplete file and the size for a whole one.
  final String detail;

  const IntendedMasterFile({
    required this.path,
    required this.complete,
    required this.detail,
  });

  /// FITS block size in bytes, per the standard. Everything in a FITS file —
  /// header and data alike — is padded to a multiple of this.
  static const int _blockSize = 2880;

  /// Cards per block, and card size, per the standard.
  static const int _cardSize = 80;

  /// Stop looking for `END` after this many header blocks. 36 blocks is ~1296
  /// cards, far beyond any header this project writes or reads; a file that
  /// has not ended its header by then is not one whose data extent can be
  /// computed, which is itself the answer.
  static const int _maxHeaderBlocks = 36;

  /// Open [file] and decide whether it is a whole FITS.
  ///
  /// The whole point is that this runs BEFORE the operator is told anything:
  /// "present and non-empty" is exactly what a file truncated by a kill looks
  /// like AND what a finished master looks like, so the two are separated by
  /// the only thing that tells them apart — the primary header's own
  /// declaration of how many bytes should follow it.
  static Future<IntendedMasterFile> measure(File file) async {
    final int length;
    try {
      length = await file.length();
    } on FileSystemException catch (error) {
      return IntendedMasterFile(
        path: file.path,
        complete: false,
        detail:
            'its size could not be read '
            '(${error.osError?.message ?? error.message})',
      );
    }
    if (length == 0) {
      return IntendedMasterFile(
        path: file.path,
        complete: false,
        detail: 'it is empty',
      );
    }
    if (length % _blockSize != 0) {
      return IntendedMasterFile(
        path: file.path,
        complete: false,
        detail:
            'it is $length bytes, which is not a whole number of '
            '$_blockSize-byte FITS blocks',
      );
    }

    final RandomAccessFile handle;
    try {
      handle = await file.open();
    } on FileSystemException catch (error) {
      return IntendedMasterFile(
        path: file.path,
        complete: false,
        detail:
            'it could not be opened '
            '(${error.osError?.message ?? error.message})',
      );
    }
    try {
      final header = await _readPrimaryHeader(handle);
      final refusal = header.refusal;
      if (refusal != null) {
        return IntendedMasterFile(
          path: file.path,
          complete: false,
          detail: refusal,
        );
      }
      final needed = header.headerBytes + header.dataBytes;
      if (length < needed) {
        return IntendedMasterFile(
          path: file.path,
          complete: false,
          detail:
              'it is $length bytes but its own header declares '
              '${header.dataBytes} bytes of data after a '
              '${header.headerBytes}-byte header, so it stops '
              '${needed - length} bytes short',
        );
      }
      return IntendedMasterFile(
        path: file.path,
        complete: true,
        detail:
            'it is $length bytes and carries all '
            '${header.dataBytes} bytes its header declares',
      );
    } finally {
      await handle.close();
    }
  }

  /// Read the primary header's extent and declared data size.
  static Future<({int headerBytes, int dataBytes, String? refusal})>
  _readPrimaryHeader(RandomAccessFile handle) async {
    var bitpix = 0;
    var naxis = -1;
    final axes = <int, int>{};
    for (var block = 0; block < _maxHeaderBlocks; block++) {
      final bytes = await handle.read(_blockSize);
      if (bytes.length < _blockSize) {
        final read = block * _blockSize + bytes.length;
        return (
          headerBytes: 0,
          dataBytes: 0,
          refusal: 'its header stops after $read bytes, before the END card',
        );
      }
      for (var offset = 0; offset < _blockSize; offset += _cardSize) {
        final card = String.fromCharCodes(bytes, offset, offset + _cardSize);
        final keyword = card.substring(0, 8).trim();
        if (block == 0 && offset == 0 && keyword != 'SIMPLE') {
          return (
            headerBytes: 0,
            dataBytes: 0,
            refusal:
                'its first card is "$keyword", not SIMPLE, so it is not '
                'a FITS file',
          );
        }
        if (keyword == 'END') {
          final headerBytes = (block + 1) * _blockSize;
          if (naxis < 0 || bitpix == 0) {
            return (
              headerBytes: headerBytes,
              dataBytes: 0,
              refusal:
                  'its header names no BITPIX/NAXIS, so how much data '
                  'should follow it cannot be read',
            );
          }
          var pixels = naxis == 0 ? 0 : 1;
          for (var axis = 1; axis <= naxis; axis++) {
            final extent = axes[axis];
            if (extent == null) {
              return (
                headerBytes: headerBytes,
                dataBytes: 0,
                refusal:
                    'its header declares NAXIS = $naxis but carries no '
                    'NAXIS$axis, so how much data should follow it cannot be '
                    'read',
              );
            }
            pixels *= extent;
          }
          final rawData = pixels * (bitpix.abs() ~/ 8);
          final padded = rawData == 0
              ? 0
              : ((rawData + _blockSize - 1) ~/ _blockSize) * _blockSize;
          return (headerBytes: headerBytes, dataBytes: padded, refusal: null);
        }
        if (card.length < 10 || card[8] != '=') continue;
        final value = int.tryParse(card.substring(10).split('/').first.trim());
        if (value == null) continue;
        if (keyword == 'BITPIX') bitpix = value;
        if (keyword == 'NAXIS') naxis = value;
        if (keyword.startsWith('NAXIS') && keyword.length > 5) {
          final axis = int.tryParse(keyword.substring(5));
          if (axis != null) axes[axis] = value;
        }
      }
    }
    return (
      headerBytes: 0,
      dataBytes: 0,
      refusal:
          'its header has no END card in the first '
          '${_maxHeaderBlocks * _blockSize} bytes',
    );
  }
}

/// Where the marker lives for a database directory.
File integrationMarkerFile(Directory databaseDirectory) =>
    File(p.join(databaseDirectory.path, kIntegrationMarkerName));

/// Record that an integration is starting.
///
/// Written and flushed before the first sub is read, because the window this
/// covers opens at that moment. Overwrites any existing marker: only one
/// post-session integration runs at a time (the coordinator serializes them),
/// and a marker left by a process that died is consumed at open, before this
/// process could reach here.
Future<void> markIntegrationStarted(
  Directory databaseDirectory,
  InterruptedIntegration integration,
) async {
  await integrationMarkerFile(
    databaseDirectory,
  ).writeAsString(jsonEncode(integration.toJson()), flush: true);
}

/// Record that the pass has reached [stage].
///
/// The same file, re-written whole and flushed, because a stage is only worth
/// anything if it survives the kill it describes. It costs one small flushed
/// write at the seam between the integrate and the Darkroom pass — the one
/// place in the pass where two commits cannot be made one.
Future<void> markPassReached(
  Directory databaseDirectory,
  InterruptedIntegration integration,
  PostSessionPassStage stage,
) => markIntegrationStarted(databaseDirectory, integration.at(stage));

/// Clear the marker because the integration finished — successfully or with a
/// reported failure.
///
/// A failure that the app itself caught and reported is NOT an interruption:
/// the operator already has the error, and leaving the marker would announce
/// it a second time at the next launch as a crash that never happened.
Future<void> clearIntegrationMarker(Directory databaseDirectory) async {
  final file = integrationMarkerFile(databaseDirectory);
  if (await file.exists()) {
    await file.delete();
  }
}

/// Read the marker a dead process left, or null when the last integration
/// finished.
///
/// Does not delete it — the caller deletes it only once the interruption has
/// been recorded somewhere durable, so a crash between the read and the write
/// of the report cannot lose the warning.
Future<InterruptedIntegration?> readIntegrationMarker(
  Directory databaseDirectory,
) async {
  final file = integrationMarkerFile(databaseDirectory);
  if (!await file.exists()) return null;
  return InterruptedIntegration.fromJson(await file.readAsString());
}
