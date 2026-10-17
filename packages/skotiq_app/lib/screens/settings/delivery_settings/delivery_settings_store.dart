part of '../delivery_settings.dart';

/// Keyring field holding one SFTP destination's private key.
///
/// Keyed by the destination row id, so two SFTP destinations never share one
/// entry and deleting a row deletes exactly one keyring value. `SftpTransport`
/// reads `delivery_targets.secret_ref` verbatim, so this string is the whole
/// contract between this editor and the transport.
String deliverySecretRef(int destinationId) =>
    'delivery.target.$destinationId.private_key';

/// What the keyring says about one destination's stored key material.
enum StoredSecretState {
  /// The keyring holds no value for this destination.
  absent,

  /// The keyring holds a value. Its bytes are never read into the UI.
  present,

  /// The keyring refused the question — a locked or absent secret service.
  /// Distinct from [absent]: "we could not ask" is not "there is none".
  unreadable,
}

/// The v58 `content_json` classes in the order the UI offers them, with the
/// wording an operator reads.
const Map<ArtifactContent, String> kArtifactContentLabels =
    <ArtifactContent, String>{
  ArtifactContent.linearMasters: 'Linear masters',
  ArtifactContent.draftRender: 'Draft render',
  ArtifactContent.stageExports: 'Stage exports',
  ArtifactContent.nightReport: 'Night report',
};

/// What this page's own check says about a watched folder's directory.
///
/// The editor's write probe answers only while the editor is open, and an
/// operator who ignored its refusal and saved anyway got a row that said
/// nothing about the folder at all. This is the same question asked cheaply
/// enough to ask on every read of the page.
enum WatchedFolderState {
  /// Nothing was asked: the destination is not a watched folder, or it names
  /// no path — which the status line reports as the configuration gap it is.
  notProbed,

  /// A directory answers at that path.
  present,

  /// Nothing is at that path. Delivery never creates one, so nothing can be
  /// written there until the operator mounts or makes it.
  absent,

  /// The check itself was refused — a permission, or a mount that would not
  /// answer. Distinct from [absent]: "we could not ask" is not "there is none".
  unreadable,
}

/// One destination as this settings page needs it: the row, its whole delivery
/// journal, what the keyring says about its key, and — for a watched folder —
/// whether its directory is there.
///
/// The journal arrives whole rather than pre-filtered, and the facts the page
/// states are derived here. Handing this class one already-narrowed list is
/// exactly how the page came to read a green "Delivered" over four files that
/// never arrived: the narrowing was correct for the sentence it was written
/// for and wrong for every other sentence built from it.
class DeliveryDestinationView {
  /// The `delivery_targets` row.
  final ArtifactDestination destination;

  /// EVERY `delivery_journal` row for this destination, across every job, in
  /// `listForTarget`'s newest-updated-first order. Empty when nothing has ever
  /// been attempted here.
  final List<DeliveryJournalEntry> journal;

  /// What the keyring says about [ArtifactDestination.secretRef].
  final StoredSecretState secret;

  /// Why the keyring could not answer, when [secret] is
  /// [StoredSecretState.unreadable].
  final String? secretError;

  /// What this page's directory check says about a watched folder's path.
  final WatchedFolderState folder;

  /// Why the directory check could not answer, when [folder] is
  /// [WatchedFolderState.unreadable].
  final String? folderError;

  const DeliveryDestinationView({
    required this.destination,
    required this.journal,
    required this.secret,
    this.secretError,
    this.folder = WatchedFolderState.notProbed,
    this.folderError,
  });

  /// The journal rows belonging to the NEWEST JOB that delivered to this
  /// destination.
  ///
  /// The newest job, not the newest-touched row. Those are different rows the
  /// moment the overnight sweep re-attempts an older night: the sweep writes
  /// `updated_at` on a row from two nights ago, which lifts that row to the
  /// top of `listForTarget` and made this page report THAT job.
  ///
  /// A job is dated by the newest row it created, because that is when its
  /// delivery started; the higher `darkroom_jobs.id` breaks a tie, since the
  /// column is an autoincrement and the later job always holds the larger one.
  List<DeliveryJournalEntry> get lastRun {
    if (journal.isEmpty) return const <DeliveryJournalEntry>[];
    var newestJobId = journal.first.jobId;
    var newestStartedAt = journal.first.createdAt;
    for (final entry in journal.skip(1)) {
      final startedAt = entry.createdAt;
      final isNewer = startedAt.isAfter(newestStartedAt) ||
          (!startedAt.isBefore(newestStartedAt) && entry.jobId > newestJobId);
      if (isNewer) {
        newestJobId = entry.jobId;
        newestStartedAt = entry.createdAt;
      }
    }
    return journal
        .where((entry) => entry.jobId == newestJobId)
        .toList(growable: false);
  }

  /// Every file at this destination whose attempts are spent, across EVERY
  /// job — the backlog nothing on the rig will look at again.
  ///
  /// The sweep reads only `retrying` rows, so a `failed` row is the end of the
  /// line until somebody re-queues it. Scoping this to the newest job is what
  /// let a destination holding a previous night's terminally-failed files read
  /// a green "Delivered" for tonight's.
  List<DeliveryJournalEntry> get unresolvedFailures => journal
      .where((entry) => entry.state == DeliveryAttemptState.failed)
      .toList(growable: false);

  /// Every file at this destination still owed an attempt, across EVERY job.
  ///
  /// This is the same set the retry sweep works from, which is what makes the
  /// count the page prints and the count the sweep logs the same number.
  List<DeliveryJournalEntry> get owed => journal
      .where((entry) => entry.state == DeliveryAttemptState.retrying)
      .toList(growable: false);

  /// The sentence this destination's status line states.
  DeliveryStatusLine get status => DeliveryStatusLine.of(this);
}

/// What the page reads: every destination it can render, and every row it
/// cannot.
///
/// Two lists rather than one throw. A single `delivery_targets` row this build
/// cannot decode used to abort the whole read, so the page rendered its error
/// state — no destination list, no Add buttons, no way to reach the row that
/// caused it — while the destinations either side of it were perfectly
/// readable. The unreadable row belongs on the page as itself.
class DeliveryDestinations {
  /// The destinations, in configuration order.
  final List<DeliveryDestinationView> views;

  /// The rows that would not decode, each naming itself and why.
  final List<UndecodableDeliveryTarget> unreadable;

  const DeliveryDestinations({required this.views, required this.unreadable});
}

/// The write probe's verdict on a watched folder.
class WatchedFolderProbe {
  /// True only when a file was actually created and removed under the path.
  final bool writable;

  /// One sentence naming what was tried and what answered.
  final String message;

  const WatchedFolderProbe({required this.writable, required this.message});
}

/// The reads and writes this settings page performs.
///
/// An interface rather than the DAOs directly so a widget test can drive the
/// page against an in-memory double, and so the keyring — which throws on a
/// host with no secret service — has exactly one place where its failure is
/// turned into a reportable state instead of an exception mid-build.
abstract class DeliverySettingsStore {
  /// Every configured destination in configuration order, each with its last
  /// run and keyring state resolved, alongside the rows that would not decode.
  Future<DeliveryDestinations> listDestinations();

  /// Insert a destination and return its new row id.
  Future<int> createDestination({
    required String name,
    required ArtifactDestinationKind kind,
    required String configJson,
    required Set<ArtifactContent> content,
    required bool enabled,
  });

  /// Update the named fields of one destination and leave the rest alone.
  Future<void> updateDestination(
    int id, {
    String? name,
    String? configJson,
    Set<ArtifactContent>? content,
    bool? enabled,
  });

  /// Delete a destination, including its keyring entry.
  Future<void> deleteDestination(int id);

  /// Put every spent row on [destinationId] back in the retry queue, across
  /// every job, and answer how many were re-queued.
  ///
  /// A `failed` row is the end of the line: the sweep reads only `retrying`
  /// rows, so nothing on the rig ever looks at that file again. The operator
  /// who mounts the share, frees the space or moves the conflicting file has
  /// no way to say so — which is what this is. Attempts are reset to zero, so
  /// the file gets the whole budget again rather than one attempt at the
  /// maximum backoff.
  ///
  /// Every job, not only the newest. This is the action offered beside a
  /// status line that counts the destination's whole terminal backlog, and a
  /// button that re-queued a subset of what the sentence beside it names would
  /// report re-queueing files it left behind. An older night's failure is
  /// still a file that never arrived; nothing else is ever going to fetch it.
  Future<int> requeueTerminalRows(int destinationId);

  /// Write [value] into the keyring and point the row's `secret_ref` at it.
  Future<void> storeSecret(int destinationId, String value);

  /// Remove the keyring entry and clear the row's `secret_ref`.
  Future<void> clearSecret(int destinationId);

  /// Prove — by writing and removing a file — that [path] can be delivered to.
  Future<WatchedFolderProbe> probeWatchedFolder(String path);
}

/// Whether a directory answers at [path].
///
/// The seam the page's folder check runs through, so a widget test states what
/// the filesystem answers rather than depending on what happens to be mounted
/// on the machine running it — the same shape [PairedDesktopReader] already
/// uses for the pairing database.
typedef WatchedFolderExists = Future<bool> Function(String path);

/// Production [DeliverySettingsStore]: the v58 DAOs, the keyring, and the
/// directory check behind a watched folder's status.
class DaoDeliverySettingsStore implements DeliverySettingsStore {
  final DeliveryTargetsDao _targets;
  final DeliveryJournalDao _journal;
  final SecretsStore _secrets;
  final WatchedFolderExists _folderExists;

  DaoDeliverySettingsStore({
    required DeliveryTargetsDao targets,
    required DeliveryJournalDao journal,
    required SecretsStore secrets,
    required WatchedFolderExists folderExists,
  })  : _targets = targets,
        _journal = journal,
        _secrets = secrets,
        _folderExists = folderExists;

  @override
  Future<DeliveryDestinations> listDestinations() async {
    final read = await _targets.readAll();
    final views = <DeliveryDestinationView>[];
    for (final destination in read.destinations) {
      final id = destination.id;
      final entries = id == null
          ? const <DeliveryJournalEntry>[]
          : await _journal.listForTarget(id);
      final secret = await _secretStateOf(destination);
      final folder = await _folderStateOf(destination);
      views.add(
        DeliveryDestinationView(
          destination: destination,
          journal: entries,
          secret: secret.state,
          secretError: secret.error,
          folder: folder.state,
          folderError: folder.error,
        ),
      );
    }
    return DeliveryDestinations(views: views, unreadable: read.undecodable);
  }

  /// Whether a watched folder's directory is there, and — when the question
  /// itself was refused — what refused it.
  ///
  /// Existence only. The editor's probe writes and removes a file because it
  /// is answering "may I deliver here?" on demand; this one runs for every
  /// destination on every read of the page, and a page that littered somebody's
  /// NAS with probe files each time it opened would be worse than the silence
  /// it replaces. A directory that exists but refuses writes is still caught by
  /// the journal's own verdict, which this note rides behind.
  Future<({WatchedFolderState state, String? error})> _folderStateOf(
    ArtifactDestination destination,
  ) async {
    if (destination.kind != ArtifactDestinationKind.watchedFolder) {
      return (state: WatchedFolderState.notProbed, error: null);
    }
    final path = configString(
      decodeDestinationConfig(destination.configJson),
      'path',
    ).trim();
    if (path.isEmpty) {
      return (state: WatchedFolderState.notProbed, error: null);
    }
    try {
      final present = await _folderExists(path);
      return (
        state: present ? WatchedFolderState.present : WatchedFolderState.absent,
        error: null,
      );
    } on FileSystemException catch (error) {
      final osError = error.osError;
      return (
        state: WatchedFolderState.unreadable,
        error: osError == null ? error.message : osError.message,
      );
    }
  }

  /// What the keyring says about one destination's key, and — when it refused
  /// to answer — the keyring's own words for why.
  Future<({StoredSecretState state, String? error})> _secretStateOf(
    ArtifactDestination destination,
  ) async {
    final ref = destination.secretRef;
    if (ref == null || ref.trim().isEmpty) {
      return (state: StoredSecretState.absent, error: null);
    }
    try {
      final held = await _secrets.has(ref);
      return (
        state: held ? StoredSecretState.present : StoredSecretState.absent,
        error: null,
      );
    } catch (error) {
      return (
        state: StoredSecretState.unreadable,
        error: userFacingError(error),
      );
    }
  }

  @override
  Future<int> createDestination({
    required String name,
    required ArtifactDestinationKind kind,
    required String configJson,
    required Set<ArtifactContent> content,
    required bool enabled,
  }) {
    return _targets.create(
      name: name,
      kind: kind,
      configJson: configJson,
      content: content,
      enabled: enabled,
    );
  }

  @override
  Future<void> updateDestination(
    int id, {
    String? name,
    String? configJson,
    Set<ArtifactContent>? content,
    bool? enabled,
  }) async {
    await _targets.update(
      id,
      name: name,
      configJson: configJson,
      content: content,
      enabled: enabled,
    );
  }

  @override
  Future<void> deleteDestination(int id) async {
    // The keyring entry goes first. If it cannot be removed the row survives,
    // so the operator still has the destination the orphaned key belongs to
    // rather than a key in the keyring nothing names.
    //
    // The column is read on its own rather than through the decoded
    // destination, because deleting is the one action a row that will not
    // decode still needs — and reading it as a destination is exactly what
    // fails on such a row.
    final ref = await _targets.secretRefOf(id);
    if (ref != null && ref.trim().isNotEmpty) {
      await _secrets.delete(ref);
    }
    await _targets.deleteTarget(id);
  }

  @override
  Future<int> requeueTerminalRows(int destinationId) async {
    final rows = await _journal.listForTarget(destinationId);
    var requeued = 0;
    for (final row in rows) {
      if (row.state != DeliveryAttemptState.failed) continue;
      await _journal.requeueForRetry(
        targetId: row.targetId,
        jobId: row.jobId,
        filePath: row.filePath,
      );
      requeued++;
    }
    return requeued;
  }

  @override
  Future<void> storeSecret(int destinationId, String value) async {
    final ref = deliverySecretRef(destinationId);
    // Keyring first: a row whose `secret_ref` points at nothing fails the
    // delivery with `credentialMissing`, which is a worse lie than a row that
    // does not claim to hold a key yet.
    await _secrets.write(ref, value);
    await _targets.update(destinationId, secretRef: ref);
  }

  @override
  Future<void> clearSecret(int destinationId) async {
    // The row's own `secret_ref` is deleted, not the name this page would
    // have chosen: a row written by anything else names its keyring entry its
    // own way, and deleting a guessed key would leave that entry behind while
    // reporting the key removed.
    final destination = await _targets.getById(destinationId);
    final ref = destination?.secretRef;
    if (ref != null && ref.trim().isNotEmpty) {
      await _secrets.delete(ref);
    }
    await _targets.clearSecretRef(destinationId);
  }

  @override
  Future<WatchedFolderProbe> probeWatchedFolder(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return const WatchedFolderProbe(
        writable: false,
        message: 'This destination names no path, so there is nothing to probe',
      );
    }
    final directory = Directory(trimmed);
    if (!await directory.exists()) {
      return WatchedFolderProbe(
        writable: false,
        message:
            'There is no directory at $trimmed. Delivery never creates one: '
            'an unmounted network share looks exactly like this, and creating '
            'it would fill the local drive with masters instead.',
      );
    }
    final probeFile = File(
      p.join(
        trimmed,
        '.skotiq-write-probe-'
        '${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await probeFile.writeAsString('skotiq delivery write probe\n');
      await probeFile.delete();
      return WatchedFolderProbe(
        writable: true,
        message: 'Wrote and removed a probe file in $trimmed',
      );
    } on FileSystemException catch (error) {
      final osMessage = error.osError;
      final detail = osMessage == null ? error.message : osMessage.message;
      return WatchedFolderProbe(
        writable: false,
        message: 'Could not write into $trimmed: $detail',
      );
    }
  }
}

/// Decode a destination's `config_json` into a map the editor can mutate.
///
/// Unknown keys are preserved by every edit path, which is what keeps
/// `hostKeyFingerprint` and `hostKey` (the two halves of the SSH
/// trust-on-first-use pin) and `minFreeBytes` alive through a name change made
/// in this page.
///
/// Returns an empty map when the column does not hold a JSON object: such a
/// row cannot describe a transport, and the status line reports it as
/// incomplete rather than inventing the missing fields.
Map<String, Object?> decodeDestinationConfig(String configJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(configJson);
  } on FormatException {
    return <String, Object?>{};
  }
  if (decoded is Map) return Map<String, Object?>.from(decoded);
  return <String, Object?>{};
}

/// The string at [key], or an empty string when the config does not carry one.
String configString(Map<String, Object?> config, String key) {
  final value = config[key];
  return value is String ? value : '';
}

/// The integer at [key], or null when the config does not carry one. JSON
/// numbers arrive as `int` from the SQLite text column; a decimal port is not
/// a port, so a `double` is rejected rather than truncated.
int? configInt(Map<String, Object?> config, String key) {
  final value = config[key];
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}

/// Asks the filesystem whether a watched folder's directory is there.
///
/// A `Provider` so a widget test overrides it rather than reaching for whatever
/// is mounted on the machine running the suite. Production is one `stat`.
final watchedFolderExistsProvider = Provider<WatchedFolderExists>(
  (ref) => (path) => Directory(path).exists(),
);

/// The store this page reads and writes through.
final deliverySettingsStoreProvider = Provider<DeliverySettingsStore>((ref) {
  return DaoDeliverySettingsStore(
    targets: ref.watch(deliveryTargetsDaoProvider),
    journal: ref.watch(deliveryJournalDaoProvider),
    secrets: ref.watch(secretsStoreProvider),
    folderExists: ref.watch(watchedFolderExistsProvider),
  );
});

/// Ticks once per completed retry-sweep pass, so a surface reading the journal
/// can find out that the journal moved.
///
/// Deliberately NOT `autoDispose`. The page below invalidates itself on each
/// tick, and an auto-disposing stream would drop to zero listeners in the gap
/// between that invalidation and the rebuild that re-listens — which on a
/// broadcast stream means the pass that arrives in that gap is heard by nobody.
/// One subscription for the life of the container is the cheaper mistake.
final deliverySweepPassesProvider = StreamProvider<DeliveryRunReport>((ref) {
  return ref.watch(deliveryRetrySweeperProvider).passes;
});

/// Every configured destination with its last run and keyring state, plus the
/// rows that would not decode.
///
/// Invalidated by every mutation on this page, which is what re-reads the
/// journal — the status line is a report, never a prediction.
///
/// And re-read whenever the retry sweep completes a pass. The sweep writes this
/// same journal on its own timer, in this same process, with nothing to say so:
/// a destination that healed at 04:00:45 was delivered to at 04:01:04, and the
/// page left open in front of the operator still read "destinationUnreachable
/// … will retry (1 file owed)" at 04:01:58 — and still read it after leaving
/// the section and coming back, because the settings shell keeps the section
/// mounted so `autoDispose` never fires either. Listening to the pass tick is
/// what keeps "a report, never a prediction" true of a report nobody re-asked
/// for.
///
/// The tick invalidates rather than being watched, so a sweep re-reads the page
/// exactly the way a mutation on it does: `AsyncValue.when` skips its loading
/// branch for a refresh but not for a reload, so `ref.watch` here would blank
/// the whole section back to "Reading delivery destinations..." every time the
/// overnight timer ran a pass.
final deliveryDestinationsProvider =
    FutureProvider.autoDispose<DeliveryDestinations>((ref) {
  ref.listen<AsyncValue<DeliveryRunReport>>(
    deliverySweepPassesProvider,
    (_, __) => ref.invalidateSelf(),
  );
  return ref.watch(deliverySettingsStoreProvider).listDestinations();
});

/// Runs one delivery retry pass and answers what it did, or null when a pass
/// was already in flight and this one was folded into it.
typedef DeliverySweepRequest = Future<DeliveryRunReport?> Function();

/// Runs the retry sweep the operator's "Retry now" asks for.
///
/// A seam over [deliveryRetrySweeperProvider] so a widget test can drive the
/// action without the real transports reaching for a filesystem or an SSH
/// host. Production reads the same sweeper the overnight timer arms, which is
/// what keeps one pass at a time over one journal.
final deliverySweepRequestProvider = Provider<DeliverySweepRequest>(
  (ref) => ref.watch(deliveryRetrySweeperProvider).sweepOnce,
);

/// Reads the devices currently paired with this install.
typedef PairedDesktopReader = Future<List<PairedDevice>> Function();

Future<List<PairedDevice>> _readPairedDevices() async {
  final database = PairingDatabase();
  try {
    return await database.getActivePairedDevices();
  } finally {
    await database.close();
  }
}

/// Seam over the pairing database so a peer row's pairing state can be driven
/// in a test without opening the on-disk pairing store.
final pairedDesktopReaderProvider = Provider<PairedDesktopReader>(
  (ref) => _readPairedDevices,
);

/// The paired devices a peer destination could be answered by.
///
/// Watched only by the peer rows, so an install with no peer destination never
/// opens the pairing database from this page.
final deliveryPairedDesktopsProvider =
    FutureProvider.autoDispose<List<PairedDevice>>((ref) {
  return ref.watch(pairedDesktopReaderProvider)();
});
