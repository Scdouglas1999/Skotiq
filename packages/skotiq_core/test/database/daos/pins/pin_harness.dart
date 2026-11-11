// Records what a DAO returns, what it throws and what it leaves in its tables,
// and compares the record with a golden file written by the code the DAO
// replaced. Set SKOTIQ_PIN_UPDATE=1 to (re)write the golden.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DataClass, ValueSerializer, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

/// Fixed timestamps for seeded rows, far from the wall clock so a value the
/// code under test stamps with "now" can be told apart from a seeded one.
final DateTime pinT0 = DateTime.utc(2025, 3, 1, 22);
DateTime pinT(int minutes) => pinT0.add(Duration(minutes: minutes));

SkotiqDatabase openPinDatabase() =>
    SkotiqDatabase.forTesting(NativeDatabase.memory());

class PinRecorder {
  PinRecorder(this.name, {this.encode});

  final String name;

  /// Turns the DAO's own model types into JSON-able maps; anything it returns
  /// null for falls through to the generic encoding.
  final Object? Function(Object value)? encode;

  /// Text replaced before a string is pinned, for values a test cannot fix
  /// in advance (a temporary directory, a wall-clock time inside a note).
  final Map<Pattern, String> scrub = {};

  final Map<String, Object?> _entries = {};
  final int _startSeconds =
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  void record(String label, Object? value) {
    if (_entries.containsKey(label)) {
      throw StateError('pin label "$label" recorded twice');
    }
    _entries[label] = _canon(value);
  }

  /// Runs [body] and records its result, or the error it threw.
  Future<void> call(String label, Future<Object?> Function() body) async {
    Object? result;
    try {
      result = await body();
    } on Object catch (error) {
      // A SQLite error quotes the statement it ran; the statement text is how
      // the query was written, not what it did, so only the error is pinned.
      final message = '$error'.split('\n  Causing statement:').first;
      result = {'threw': error.runtimeType.toString(), 'message': message};
    }
    record(label, result);
  }

  /// Records every row of [table] in rowid order, each column as stored.
  Future<void> dump(SkotiqDatabase db, String table, String label) async {
    final rows = await db
        .customSelect('SELECT * FROM "$table" ORDER BY rowid')
        .get();
    final typed = await db
        .customSelect(
          'SELECT ${await _typeofColumns(db, table)} FROM "$table" '
          'ORDER BY rowid',
        )
        .get();
    record('$label :: $table', [
      for (var i = 0; i < rows.length; i++)
        {
          for (final entry in rows[i].data.entries)
            entry.key: {
              'v': _stamp(entry.value),
              't': typed[i].data['t_${entry.key}'],
            },
        },
    ]);
  }

  Future<String> _typeofColumns(SkotiqDatabase db, String table) async {
    final cols = await db.customSelect('PRAGMA table_info("$table")').get();
    return cols
        .map((c) => c.data['name'] as String)
        .map((n) => 'typeof("$n") AS "t_$n"')
        .join(', ');
  }

  /// A value stamped from the wall clock during the test is pinned as `<now>`.
  Object? _stamp(Object? value) {
    if (value is String) {
      var text = value;
      scrub.forEach((from, to) => text = text.replaceAll(from, to));
      return text;
    }
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    if (value is int) {
      if (value >= _startSeconds - 1 && value <= now + 1) return '<now s>';
      if (value >= (_startSeconds - 1) * 1000 && value <= (now + 1) * 1000) {
        return '<now ms>';
      }
    }
    return value;
  }

  Object? _canon(Object? value) {
    if (value == null || value is bool || value is String || value is num) {
      return _stamp(value);
    }
    final custom = encode?.call(value);
    if (custom != null) return _canon(custom);
    if (value is DataClass) {
      return _canon(value.toJson(serializer: const _AsIsSerializer()));
    }
    if (value is DateTime) {
      final seconds = value.toUtc().millisecondsSinceEpoch ~/ 1000;
      if (_stamp(seconds) is String) {
        return value.isUtc ? '<now utc>' : '<now local>';
      }
      return value.isUtc
          ? value.toIso8601String()
          : '${value.toUtc().toIso8601String()} (local)';
    }
    if (value is Enum) return '${value.runtimeType}.${value.name}';
    if (value is Set) {
      final list = [for (final v in value) _canon(v)];
      list.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
      return {'set': list};
    }
    if (value is Iterable) return [for (final v in value) _canon(v)];
    if (value is Map) {
      return {for (final e in value.entries) '${e.key}': _canon(e.value)};
    }
    if (value is Record) return _stamp(value.toString());
    throw ArgumentError('no pin encoding for ${value.runtimeType}');
  }

  /// Compares the record with `test/database/daos/pins/<name>.golden.json`.
  void verify() {
    final file = File('test/database/daos/pins/$name.golden.json');
    final actual = '${const JsonEncoder.withIndent('  ').convert(_entries)}\n';
    if (Platform.environment['SKOTIQ_PIN_UPDATE'] == '1') {
      file.writeAsStringSync(actual);
      return;
    }
    expect(
      file.existsSync(),
      isTrue,
      reason:
          'golden ${file.path} is missing; write it with the code being '
          'pinned and SKOTIQ_PIN_UPDATE=1',
    );
    final expected = file.readAsStringSync();
    if (actual == expected) return;
    final want = const LineSplitter().convert(expected);
    final got = const LineSplitter().convert(actual);
    final diffs = <String>[];
    for (var i = 0; i < want.length || i < got.length; i++) {
      final w = i < want.length ? want[i] : '<end>';
      final g = i < got.length ? got[i] : '<end>';
      if (w != g && diffs.length < 40) {
        diffs.add('line ${i + 1}:\n  golden: $w\n  actual: $g');
      }
    }
    fail('$name differs from its golden at\n${diffs.join('\n')}');
  }
}

/// The rows most pins hang off: three targets, two sessions, one equipment
/// profile and a handful of captured frames.
class PinSeed {
  PinSeed._(this.targets, this.sessions, this.profile, this.images);

  final List<int> targets;
  final List<int> sessions;
  final int profile;
  final List<int> images;

  static Future<PinSeed> create(SkotiqDatabase db) async {
    final targets = <int>[];
    for (final name in ['M31', 'NGC 891', 'IC 1805']) {
      targets.add(
        await db.customInsert(
          'INSERT INTO targets (name, ra, dec, created_at, updated_at) '
          'VALUES (?, 1.0, 40.0, ?, ?)',
          variables: [
            Variable.withString(name),
            Variable.withInt(pinT0.millisecondsSinceEpoch ~/ 1000),
            Variable.withInt(pinT0.millisecondsSinceEpoch ~/ 1000),
          ],
        ),
      );
    }
    final sessions = <int>[];
    for (var i = 0; i < 2; i++) {
      sessions.add(
        await db.customInsert(
          'INSERT INTO imaging_sessions (start_time) VALUES (?)',
          variables: [
            Variable.withInt(pinT(i * 60).millisecondsSinceEpoch ~/ 1000),
          ],
        ),
      );
    }
    final profile = await db.customInsert(
      "INSERT INTO equipment_profiles (name) VALUES ('Pin rig')",
    );
    final images = <int>[];
    for (var i = 0; i < 6; i++) {
      images.add(
        await db.customInsert(
          'INSERT INTO captured_images (file_path, file_name, '
          'exposure_duration, captured_at, session_id, target_id) '
          'VALUES (?, ?, 120.0, ?, ?, ?)',
          variables: [
            Variable.withString('/frames/f$i.fits'),
            Variable.withString('f$i.fits'),
            Variable.withInt(pinT(i).millisecondsSinceEpoch ~/ 1000),
            Variable.withInt(sessions[i % 2]),
            Variable.withInt(targets[i % 3]),
          ],
        ),
      );
    }
    return PinSeed._(targets, sessions, profile, images);
  }
}

/// Hands drift row fields over unconverted, so a DateTime keeps its zone.
class _AsIsSerializer extends ValueSerializer {
  const _AsIsSerializer();

  @override
  T fromJson<T>(dynamic json) => json as T;

  @override
  dynamic toJson<T>(T value) => value;
}
