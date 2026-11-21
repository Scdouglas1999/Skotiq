import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test(
    'closing orphaned sessions selects and updates them in one transaction',
    () async {
      final trace = _SqlTrace();
      final db = SkotiqDatabase.forTesting(
        NativeDatabase.memory().interceptWith(trace),
      );
      addTearDown(db.close);
      final id = await db.sessionsDao.startSession(name: 'stranded');
      trace.events.clear();

      final closed = await db.sessionsDao.closeOrphanedSessions(
        cause: 'the process ended',
      );

      expect(closed, [id]);
      final row = await (db.select(
        db.imagingSessions,
      )..where((s) => s.id.equals(id))).getSingle();
      expect(row.status, SessionStatus.interrupted.token);
      expect(row.notes, contains('the process ended'));
      expect(trace.events.first, 'begin');
      expect(trace.events, contains('select'));
      expect(trace.events, contains('update'));
      expect(trace.events.last, 'commit');
      expect(
        trace.events.indexOf('begin'),
        lessThan(trace.events.indexOf('select')),
      );
      expect(
        trace.events.indexOf('update'),
        lessThan(trace.events.lastIndexOf('commit')),
      );
    },
  );
}

class _SqlTrace extends QueryInterceptor {
  final events = <String>[];

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    events.add('begin');
    return super.beginTransaction(parent);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) {
    events.add('commit');
    return super.commitTransaction(inner);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('FROM imaging_sessions')) events.add('select');
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('UPDATE imaging_sessions')) events.add('update');
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('UPDATE imaging_sessions')) events.add('update');
    return super.runCustom(executor, statement, args);
  }
}
