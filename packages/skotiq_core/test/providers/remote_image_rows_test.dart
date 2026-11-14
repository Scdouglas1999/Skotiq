import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

db.DbCapturedImage _row(int id, {int sessionId = 7, String? path}) {
  final at = DateTime.utc(2026, 11, 7, 21).add(Duration(minutes: id));
  return db.DbCapturedImage(
    id: id,
    filePath: path ?? '/captures/frame_$id.fits',
    fileName: 'frame_$id.fits',
    fileFormat: 'fits',
    sessionId: sessionId,
    frameType: 'light',
    exposureDuration: 180.0,
    binX: 1,
    binY: 1,
    isPlateSolved: false,
    capturedAt: at,
    createdAt: at,
    isAccepted: true,
  );
}

/// Owner, Heart Nebula night 2026-11-07: a linked client showed new frames
/// about 15 s after the host. The frame strip and the session list waited for
/// the 30 s poll of the host's whole image table; measured on a sim pair the
/// client's strip moved in jumps of five frames, 28 s behind the host.
void main() {
  late StreamController<List<db.DbCapturedImage>> poll;
  late List<int> rowFetches;
  late List<int> sessionFetches;
  late Map<int, db.DbCapturedImage> host;
  late RemoteImageRows rows;

  setUp(() {
    poll = StreamController<List<db.DbCapturedImage>>.broadcast();
    rowFetches = [];
    sessionFetches = [];
    host = {
      for (final id in [1, 2, 3]) id: _row(id),
    };
    rows = RemoteImageRows(
      poll: () => poll.stream,
      fetchRow: (id) async {
        rowFetches.add(id);
        return host[id]?.toJson();
      },
      fetchSessionRows: (sessionId) async {
        sessionFetches.add(sessionId);
        return [
          for (final row in host.values)
            if (row.sessionId == sessionId) row.toJson(),
        ];
      },
    );
  });

  tearDown(() async {
    rows.dispose();
    await poll.close();
  });

  test('a frame the host lists is fetched by id at once', () async {
    final seen = <List<int>>[];
    final sub = rows.watchAll().listen(
      (r) => seen.add([for (final x in r) x.id]),
    );
    poll.add([_row(3), _row(2), _row(1)]);
    await pumpEventQueue();

    host[4] = _row(4);
    await rows.addRows([1, 2, 3, 4]);
    await pumpEventQueue();

    expect(rowFetches, [4], reason: 'only the row this client lacks');
    expect(seen.last, [4, 3, 2, 1]);
    await sub.cancel();
  });

  test('the next poll replaces what was fetched one by one', () async {
    final stream = rows.watchAll();
    final seen = <List<int>>[];
    final sub = stream.listen((r) => seen.add([for (final x in r) x.id]));
    poll.add([_row(2), _row(1)]);
    await pumpEventQueue();
    host[3] = _row(3);
    await rows.addRows([3]);
    poll.add([_row(3), _row(2), _row(1)]);
    await pumpEventQueue();

    expect(seen.last, [3, 2, 1]);
    expect(rows.current!.where((r) => r.id == 3), hasLength(1));
    await sub.cancel();
  });

  test('a saved frame with no row reads its session again', () async {
    final sub = rows.watchAll().listen((_) {});
    poll.add([_row(2), _row(1)]);
    await pumpEventQueue();

    // A rejected frame: in the host's image table, not in its session list.
    host[3] = _row(3, path: '/captures/Reject/frame_3.fits');
    await rows.refreshSessionOf('/captures/Reject/frame_3.fits');
    await pumpEventQueue();

    expect(sessionFetches, [7]);
    expect(rows.current!.map((r) => r.id), [3, 2, 1]);

    // A frame already here costs nothing.
    await rows.refreshSessionOf('/captures/frame_2.fits');
    expect(sessionFetches, [7]);
    await sub.cancel();
  });

  test('before the first poll nothing is fetched one by one', () async {
    await rows.addRows([1, 2]);
    expect(rowFetches, isEmpty);
  });

  test('a provider rebuilt by an invalidation reads the table again', () async {
    var polls = 0;
    final rebuilt = RemoteImageRows(
      poll: () {
        polls++;
        return poll.stream;
      },
      fetchRow: (_) async => null,
      fetchSessionRows: (_) async => const [],
    );
    addTearDown(rebuilt.dispose);
    final first = rebuilt.watchAll().listen((_) {});
    poll.add([_row(1)]);
    await pumpEventQueue();

    final seen = <List<int>>[];
    final second = rebuilt.watchAll().listen(
      (r) => seen.add([for (final x in r) x.id]),
    );
    await first.cancel();
    poll.add([_row(2), _row(1)]);
    await pumpEventQueue();

    expect(polls, 2);
    expect(seen, [
      [2, 1],
    ], reason: 'no rows from before the change first');
    await second.cancel();
  });
}
