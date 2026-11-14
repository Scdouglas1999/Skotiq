// Settings written by the build this refactor started from (c04d55c8d) must
// read back unchanged.
//
// `test/fixtures/settings/` was produced by that build:
//   * `base_settings_store.db`: a database in which every setting holds a
//     value other than its default.
//   * `base_settings_behavior.json`: what that build did with each stored
//     row, each row of a client write, and each wire value, for a range of
//     well-formed and malformed inputs.
//   * `base_install_rows.json`: the rows a fresh install was seeded with.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart' as models;
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/settings/app_settings_codec.dart';
import 'package:skotiq_core/src/settings/app_settings_table.dart';
import 'package:skotiq_core/src/settings/setting.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';

Map<String, String> _changed(
  Map<String, String> from,
  Map<String, String> to,
) => {
  for (final key in to.keys)
    if (from[key] != to[key]) key: to[key]!,
};

/// Whether [setting] holds stored and received values to bounds or to a set
/// of allowed values. The base build did that only on some of the paths a
/// value arrives by; it now happens on all of them.
bool _sanitizes(Setting<Object?> setting) => switch (setting) {
  IntSetting(:final min, :final max) => min != null || max != null,
  DoubleSetting(:final min, :final max) => min != null || max != null,
  TextSetting(:final allowed, :final normalize, :final emptyWireIsFallback) =>
    allowed != null || normalize != null || emptyWireIsFallback,
  BoolMapSetting() || DoubleMapSetting() => true,
  _ => false,
};

/// Settings declared after the base build. A base store has no row for
/// them, so they must read as their defaults; every other comparison here is
/// made without them.
const Set<String> _addedSinceBase = {
  'qhy_discovery_enabled',
  'catalog_base_url',
  'camera_file_saving',
  'xisf_compression',
  'xisf_checksums',
  'recovery_park_and_close_when_gives_up',
};

/// Wire fields of settings declared after the base build; the base wire form
/// is compared without them.
const Set<String> _wireAddedSinceBase = {
  'cameraFileSaving',
  'xisfCompression',
  'xisfChecksums',
};

/// [rows] without the settings the base build did not have.
Map<String, String> _baseOnly(Map<String, String> rows) => {
  for (final entry in rows.entries)
    if (!_addedSinceBase.contains(entry.key)) entry.key: entry.value,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixture =
      jsonDecode(
            File(
              'test/fixtures/settings/base_settings_behavior.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final baseDefaults = Map<String, String>.from(fixture['defaults'] as Map);
  final baseRows = Map<String, String>.from(fixture['nonDefaultStored'] as Map);

  test(
    'a settings store written by the base build loads with every value',
    () async {
      final scratch = Directory.systemTemp.createTempSync('skotiq_settings_');
      final copy = File('${scratch.path}/skotiq.db');
      File('test/fixtures/settings/base_settings_store.db').copySync(copy.path);
      final database = SkotiqDatabase.forTesting(NativeDatabase(copy));
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
        scratch.deleteSync(recursive: true);
      });

      final loaded = await container.read(appSettingsProvider.future);
      final allRows = container
          .read(appSettingsProvider.notifier)
          .storedRowsOf(loaded);
      final rows = _baseOnly(allRows);
      expect(rows, baseRows);
      for (final key in _addedSinceBase) {
        final setting = AppSettingsCodec.settingForKey(key)!;
        expect(
          allRows[key],
          setting.toRows(setting.fallback)[key],
          reason: '$key has no row in a base store, so it reads as its default',
        );
      }

      // Every setting the fixture could move off its default did move, so a
      // setting that silently fell back to its default would show up here.
      final atDefault = [
        for (final setting in kAppSettingsTable)
          if (!_addedSinceBase.contains(setting.key) &&
              rows[setting.key] == baseDefaults[setting.key])
            setting.key,
      ];
      expect(atDefault, unorderedEquals(['image_format', 'bit_depth']));

      // Saving everything back writes the same rows the base build wrote.
      await container.read(appSettingsProvider.notifier).saveRows(rows);
      expect({
        for (final key in baseRows.keys)
          key: await database.settingsDao.getSetting(key),
      }, baseRows);
    },
  );

  test(
    'a fresh install is seeded with the rows the base build seeded',
    () async {
      final expected = Map<String, String>.from(
        jsonDecode(
              File(
                'test/fixtures/settings/base_install_rows.json',
              ).readAsStringSync(),
            )
            as Map,
      );
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final all = await database.settingsDao.getAllSettings();
      expect({
        for (final key in expected.keys)
          if (all.containsKey(key)) key: all[key],
      }, expected);
      expect(
        [
          for (final key in AppSettingsCodec.storedKeys)
            if (all.containsKey(key) && !expected.containsKey(key)) key,
        ],
        isEmpty,
        reason: 'rows the base build did not seed',
      );
    },
  );

  test('defaults and the stored form match the base build', () {
    expect(AppSettingsCodec.storedKeys.difference(_addedSinceBase), {
      ...(fixture['storedKeys'] as List).cast<String>(),
    });
    expect(
      _baseOnly(AppSettingsCodec.toRows(const AppSettingsState())),
      baseDefaults,
    );
    expect(
      _baseOnly(
        AppSettingsCodec.toRows(
          AppSettingsCodec.fromRows(
            Map<String, String>.from(fixture['nonDefaultRows'] as Map),
          ),
        ),
      ),
      baseRows,
    );
  });

  test('every stored row reads as the base build read it', () {
    (fixture['fullLoad'] as Map<String, dynamic>).forEach((key, perRaw) {
      (perRaw as Map<String, dynamic>).forEach((raw, expected) {
        // The base build could only save frames as FITS and read every
        // stored archive format as FITS; XISF is now a format frames are
        // saved in, so a stored XISF reads as XISF.
        if (key == 'image_format' && raw.toUpperCase() == 'XISF') {
          expect(
            AppSettingsCodec.toRows(AppSettingsCodec.fromRows({key: raw}))[key],
            'XISF',
          );
          return;
        }
        final got = _changed(
          baseDefaults,
          _baseOnly(
            AppSettingsCodec.toRows(AppSettingsCodec.fromRows({key: raw})),
          ),
        );
        expect(got, expected, reason: '$key = ${jsonEncode(raw)}');
      });
    });
  });

  test('a client write of one row applies as in the base build', () {
    final b = AppSettingsCodec.fromRows(baseRows);
    (fixture['partial'] as Map<String, dynamic>).forEach((key, perRaw) {
      final setting = AppSettingsCodec.settingForKey(key)!;
      final refusedByBase = (perRaw as Map<String, dynamic>).values.any(
        (v) => v == 'ERR:UnsupportedError',
      );
      expect(
        !AppSettingsCodec.hostKeys.contains(key),
        refusedByBase,
        reason: 'whether a linked client may write $key',
      );
      if (refusedByBase) return;
      perRaw.forEach((raw, expected) {
        final got = _changed(
          baseRows,
          _baseOnly(
            AppSettingsCodec.toRows(AppSettingsCodec.applyRows(b, {key: raw})),
          ),
        );
        if (_sanitizes(setting) && !_sameMap(got, expected)) return;
        expect(got, expected, reason: '$key = ${jsonEncode(raw)}');
      });
    });
  });

  test('the wire form matches the base build', () {
    Map<String, dynamic> plain(models.AppSettings s) =>
        (jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>)
          ..removeWhere((key, _) => _wireAddedSinceBase.contains(key));
    expect(
      plain(AppSettingsCodec.toWire(const AppSettingsState())),
      fixture['wireDefault'],
    );
    expect(
      plain(AppSettingsCodec.toWire(AppSettingsCodec.fromRows(baseRows))),
      fixture['wireNonDefault'],
    );
    expect(
      _baseOnly(
        AppSettingsCodec.toRows(
          AppSettingsCodec.fromWire(
            models.AppSettings.fromJson(
              Map<String, dynamic>.from(fixture['wireNonDefault'] as Map),
            ),
          ),
        ),
      ),
      fixture['fromWireNonDefault'],
    );
    expect(
      _baseOnly(
        AppSettingsCodec.toRows(
          AppSettingsCodec.fromWire(const models.AppSettings()),
        ),
      ),
      fixture['fromWireEmpty'],
    );
  });

  test('a single wire change applies as in the base build', () {
    final b = AppSettingsCodec.fromRows(baseRows);
    final wireKeys = {
      for (final setting in kAppSettingsTable)
        if (setting.sync == SettingSync.host) setting.wire: setting,
    };
    (fixture['events'] as Map<String, dynamic>).forEach((key, perValue) {
      final setting = wireKeys[key];
      (perValue as Map<String, dynamic>).forEach((label, expected) {
        final next = AppSettingsCodec.applyWireChange(
          b,
          key,
          jsonDecode(label),
        );
        final got = next == null
            ? null
            : _changed(baseRows, _baseOnly(AppSettingsCodec.toRows(next)));
        if (setting == null) {
          // Not a wire field. The base build answered to one stored key
          // here, `sidebar_collapsed`, to replay a client's own display
          // rows; those now go through the stored form instead.
          expect(got, isNull, reason: key);
          return;
        }
        if (_sanitizes(setting) && !_sameJson(got, expected)) return;
        expect(got, expected, reason: '$key = $label');
      });
    });
  });
}

bool _sameMap(Map<String, String> a, Object? b) => _sameJson(a, b);

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || a[key] != b[key]) return false;
    }
    return true;
  }
  return a == b;
}
