import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend/host_data/remote_host_records.dart';
import '../database/daos/images_dao.dart';
import '../database/database.dart' as db;
import 'database_provider.dart';
import 'host_role.dart';

/// The imaging host's captured-image rows, as the lists the screens watch.
///
/// The host's own process asks its database for each list. A linked client
/// keeps one polled copy of the host's table and cuts every list from it, so
/// the members take the [Ref] of the provider that shows the list.
abstract interface class CapturedImageRows {
  /// Every row, newest capture first.
  Stream<List<db.DbCapturedImage>> watchAll();

  /// The rows of one session, oldest first.
  Stream<List<db.DbCapturedImage>> watchSession(int sessionId);

  /// The newest rows captured outside any session, newest first.
  Stream<List<db.DbCapturedImage>> watchStandalone();

  AsyncValue<bool> hasAny(Ref ref);

  /// The rows of one session, oldest first.
  AsyncValue<List<db.DbCapturedImage>> forSession(Ref ref, int sessionId);

  /// The rows captured from [start] up to [end], oldest first.
  AsyncValue<List<db.DbCapturedImage>> capturedBetween(
    Ref ref,
    DateTime start,
    DateTime end,
  );

  /// The host announced frames with these row ids. A linked client fetches
  /// the ones it lacks now rather than with its next poll.
  Future<void> addRows(Iterable<int> ids);

  /// The host saved a frame at [filePath]. A linked client with no row for it
  /// re-reads the session, which is how a rejected frame's row arrives.
  Future<void> refreshSessionOf(String filePath);
}

/// The captured-image rows of whichever machine is the imaging host.
final capturedImageRowsProvider = hostRoleProvider<CapturedImageRows>(
  here: (ref) => _DatabaseImageRows(ref.watch(imagesDaoProvider)),
  linked: (ref, host) {
    final records = host.imagingRecords;
    final rows = RemoteImageRows(
      poll: () => pollHostImageRows(records),
      fetchRow: records.getCapturedImageById,
      fetchSessionRows: records.getSessionImageRows,
    );
    ref.onDispose(rows.dispose);
    return rows;
  },
);

/// The rows of one session of the imaging host, oldest first.
final sessionImageRowsProvider = Provider.autoDispose
    .family<AsyncValue<List<db.DbCapturedImage>>, int>(
      (ref, sessionId) =>
          ref.watch(capturedImageRowsProvider).forSession(ref, sessionId),
    );

/// The rows the imaging host captured inside a window, oldest first.
final imageRowsCapturedBetweenProvider = Provider.autoDispose
    .family<
      AsyncValue<List<db.DbCapturedImage>>,
      ({DateTime start, DateTime end})
    >(
      (ref, window) => ref
          .watch(capturedImageRowsProvider)
          .capturedBetween(ref, window.start, window.end),
    );

/// The rows in this process's own database. The database announces every
/// change, so nothing the host says about its frames needs fetching.
final class _DatabaseImageRows implements CapturedImageRows {
  _DatabaseImageRows(this._dao);

  final ImagesDao _dao;

  @override
  Stream<List<db.DbCapturedImage>> watchAll() => _dao.watchAllImages();

  @override
  Stream<List<db.DbCapturedImage>> watchSession(int sessionId) =>
      _dao.watchImagesForSession(sessionId);

  @override
  Stream<List<db.DbCapturedImage>> watchStandalone() =>
      _dao.watchStandaloneImages();

  @override
  AsyncValue<bool> hasAny(Ref ref) => ref.watch(_hasAnyImageProvider);

  @override
  AsyncValue<List<db.DbCapturedImage>> forSession(Ref ref, int sessionId) =>
      ref.watch(_sessionRowsProvider(sessionId));

  @override
  AsyncValue<List<db.DbCapturedImage>> capturedBetween(
    Ref ref,
    DateTime start,
    DateTime end,
  ) => ref.watch(_rowsBetweenProvider((start: start, end: end)));

  @override
  Future<void> addRows(Iterable<int> ids) async {}

  @override
  Future<void> refreshSessionOf(String filePath) async {}
}

final _hasAnyImageProvider = StreamProvider<bool>(
  (ref) => ref.watch(imagesDaoProvider).watchHasAnyImage(),
);

final _sessionRowsProvider = StreamProvider.autoDispose
    .family<List<db.DbCapturedImage>, int>(
      (ref, sessionId) =>
          ref.watch(imagesDaoProvider).watchImagesForSession(sessionId),
    );

final _rowsBetweenProvider = StreamProvider.autoDispose
    .family<List<db.DbCapturedImage>, ({DateTime start, DateTime end})>(
      (ref, window) => ref
          .watch(imagesDaoProvider)
          .watchImagesCapturedBetween(window.start, window.end),
    );

/// The host's captured-image rows on a linked client.
///
/// The whole table is polled every 30 s, which put a new frame's row (its
/// frame number, verdict and HFR) on a client's frame strip and session list
/// a mean 15 s after the host's, in jumps of several frames. A frame the host
/// announces is fetched at once instead: [addRows] for the ids of the host's
/// session list, [refreshSessionOf] for a saved frame with no row here yet.
/// The poll still runs, so a row the host changes later (a verdict, a solve)
/// arrives within one cycle.
class RemoteImageRows implements CapturedImageRows {
  RemoteImageRows({
    required Stream<List<db.DbCapturedImage>> Function() poll,
    required Future<Map<String, dynamic>?> Function(int id) fetchRow,
    required Future<List<Map<String, dynamic>>> Function(int sessionId)
    fetchSessionRows,
  }) : _poll = poll,
       _fetchRow = fetchRow,
       _fetchSessionRows = fetchSessionRows;

  final Stream<List<db.DbCapturedImage>> Function() _poll;
  final Future<Map<String, dynamic>?> Function(int id) _fetchRow;
  final Future<List<Map<String, dynamic>>> Function(int sessionId)
  _fetchSessionRows;

  /// The newest full list from the poll.
  List<db.DbCapturedImage>? _polled;

  /// Rows fetched one at a time or by session since that list, by id.
  final Map<int, db.DbCapturedImage> _fetched = {};
  final Set<int> _inFlight = {};
  /// Each open list with the cut of the table it shows.
  final Map<StreamController<List<db.DbCapturedImage>>, _Cut> _listeners = {};
  StreamSubscription<List<db.DbCapturedImage>>? _pollSubscription;
  bool _sessionRefreshRunning = false;
  bool _sessionRefreshAgain = false;
  bool _disposed = false;

  /// The merged rows, newest capture first like `ImagesDao.watchAllImages`.
  List<db.DbCapturedImage>? get current {
    final polled = _polled;
    if (polled == null) return null;
    if (_fetched.isEmpty) return polled;
    final byId = {for (final row in polled) row.id: row, ..._fetched};
    return byId.values.toList()
      ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
  }

  @override
  Stream<List<db.DbCapturedImage>> watchAll() =>
      _watch((rows) => rows, rereadOnListen: true);

  @override
  Stream<List<db.DbCapturedImage>> watchSession(int sessionId) => _watch(
    (rows) =>
        rows.where((row) => row.sessionId == sessionId).toList()
          ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt)),
  );

  @override
  Stream<List<db.DbCapturedImage>> watchStandalone() => _watch(
    (rows) => rows
        .where((row) => row.sessionId == null)
        .take(_standaloneLimit)
        .toList(),
  );

  /// As many as `ImagesDao.watchStandaloneImages` returns on the host.
  static const _standaloneLimit = 100;

  /// One list cut from the polled table. The whole table ([rereadOnListen])
  /// waits for a new read when it is listened to: that is a rebuild of its
  /// provider, for instance after the host announced a change to its images.
  /// A cut starts from the rows already here and shares the running poll.
  Stream<List<db.DbCapturedImage>> _watch(
    List<db.DbCapturedImage> Function(List<db.DbCapturedImage> rows) cut, {
    bool rereadOnListen = false,
  }) {
    late final StreamController<List<db.DbCapturedImage>> controller;
    List<db.DbCapturedImage>? shown;
    List<db.DbCapturedImage> distinct(List<db.DbCapturedImage> rows) {
      final next = cut(rows);
      final last = shown;
      return shown = last != null && listEquals(last, next) ? last : next;
    }

    controller = StreamController<List<db.DbCapturedImage>>(
      onListen: () {
        _listeners[controller] = rereadOnListen
            ? cut
            : (rows) {
                final last = shown;
                final next = distinct(rows);
                return identical(last, next) ? null : next;
              };
        final rows = current;
        if (!rereadOnListen && rows != null) controller.add(distinct(rows));
        if (rereadOnListen || _pollSubscription == null) _startPoll();
      },
      onCancel: () {
        _listeners.remove(controller);
        if (_listeners.isEmpty) {
          unawaited(_pollSubscription?.cancel());
          _pollSubscription = null;
        }
      },
    );
    return controller.stream;
  }

  void _startPoll() {
    unawaited(_pollSubscription?.cancel());
    _pollSubscription = _poll().listen(
      _onPolled,
      onError: (Object error, StackTrace stackTrace) {
        if (_polled != null) return;
        for (final listener in _listeners.keys) {
          listener.addError(error, stackTrace);
        }
      },
    );
  }

  void _onPolled(List<db.DbCapturedImage> rows) {
    _polled = rows;
    // The poll is the truth for every row it carries; a row fetched after the
    // poll's request went out stays until the next one carries it too.
    final newest = rows.isEmpty
        ? 0
        : rows.map((row) => row.id).reduce((a, b) => a > b ? a : b);
    _fetched.removeWhere((id, _) => id <= newest);
    _emit();
  }

  void _emit() {
    if (_disposed) return;
    final rows = current;
    if (rows == null) return;
    for (final MapEntry(key: listener, value: cut) in _listeners.entries) {
      final list = cut(rows);
      if (list != null) listener.add(list);
    }
  }

  bool _known(int id) =>
      _fetched.containsKey(id) ||
      (_polled?.any((row) => row.id == id) ?? false);

  /// Fetch the rows of [ids] this client does not have yet.
  @override
  Future<void> addRows(Iterable<int> ids) async {
    if (_polled == null) return; // The first poll brings them all.
    final missing = [
      for (final id in ids)
        if (!_known(id) && !_inFlight.contains(id)) id,
    ];
    if (missing.isEmpty) return;
    _inFlight.addAll(missing);
    try {
      final rows = await Future.wait([
        for (final id in missing)
          _fetchRow(id).then<Map<String, dynamic>?>(
            (row) => row,
            onError: (Object _) => null,
          ),
      ]);
      if (_disposed) return;
      var added = false;
      for (final json in rows) {
        if (json == null) continue;
        final row = db.DbCapturedImage.fromJson(json);
        _fetched[row.id] = row;
        added = true;
      }
      if (added) _emit();
    } finally {
      _inFlight.removeAll(missing);
    }
  }

  /// Fetch the rows of the session the newest known frame belongs to when a
  /// frame saved at [filePath] has no row here yet. A rejected frame is not in
  /// the host's session list, so its id never reaches [addRows].
  @override
  Future<void> refreshSessionOf(String filePath) async {
    final rows = current;
    if (rows == null || rows.any((row) => row.filePath == filePath)) return;
    final sessionId = rows
        .map((row) => row.sessionId)
        .firstWhere((id) => id != null, orElse: () => null);
    if (sessionId == null) return;
    if (_sessionRefreshRunning) {
      _sessionRefreshAgain = true;
      return;
    }
    _sessionRefreshRunning = true;
    try {
      do {
        _sessionRefreshAgain = false;
        final List<Map<String, dynamic>> json;
        try {
          json = await _fetchSessionRows(sessionId);
        } on Object {
          return; // The poll brings the row instead.
        }
        if (_disposed) return;
        for (final row in json.map(db.DbCapturedImage.fromJson)) {
          _fetched[row.id] = row;
        }
        _emit();
      } while (_sessionRefreshAgain && !_disposed);
    } finally {
      _sessionRefreshRunning = false;
    }
  }

  @override
  AsyncValue<bool> hasAny(Ref ref) =>
      ref.watch(allDbImagesProvider).whenData((rows) => rows.isNotEmpty);

  @override
  AsyncValue<List<db.DbCapturedImage>> forSession(Ref ref, int sessionId) =>
      _oldestFirst(ref, (row) => row.sessionId == sessionId);

  @override
  AsyncValue<List<db.DbCapturedImage>> capturedBetween(
    Ref ref,
    DateTime start,
    DateTime end,
  ) => _oldestFirst(
    ref,
    (row) => !row.capturedAt.isBefore(start) && row.capturedAt.isBefore(end),
  );

  /// The one polled copy every list here is cut from.
  AsyncValue<List<db.DbCapturedImage>> _oldestFirst(
    Ref ref,
    bool Function(db.DbCapturedImage row) keep,
  ) => ref
      .watch(allDbImagesProvider)
      .whenData(
        (rows) =>
            rows.where(keep).toList()
              ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt)),
      );

  void dispose() {
    _disposed = true;
    unawaited(_pollSubscription?.cancel());
    _pollSubscription = null;
    for (final listener in _listeners.keys.toList()) {
      unawaited(listener.close());
    }
    _listeners.clear();
  }
}

/// The rows one open list shows of the whole table, or null when they are
/// the rows it already has.
typedef _Cut =
    List<db.DbCapturedImage>? Function(List<db.DbCapturedImage> rows);
