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
  // How close a centering must land. Seeded, so a fresh install has the row;
  // a base store has none and reads the 5 arcsecond default.
  'centering_tolerance_arcsec',
  'image_grading_eccentricity_baseline_percent',
  'image_grading_star_count_drop_percent',
  // The phone's demo rig switch, kept on this device.
  'demo_rig',
};

/// Settings the native plate-solver preference has held since the base build
/// ([Setting.heldNatively]): their rows, written by the base build, stay in
/// the database unread (a replace-restore still writes a backup's rows into
/// the preference), and the settings document takes them from the
/// preference. Every comparison of state-derived rows is made without them.
final Set<String> _heldNatively = AppSettingsCodec.heldNativelyKeys;

/// Wire fields of settings declared after the base build; the base wire form
/// is compared without them.
const Set<String> _wireAddedSinceBase = {
  'cameraFileSaving',
  'xisfCompression',
  'xisfChecksums',
  'imageGradingEccentricityBaselinePercent',
  'imageGradingStarCountDropPercent',
  'centeringToleranceArcsec',
  'demoRig',
};

/// A default changed on purpose since the base build. A stored row still
/// reads as written; only what a missing value falls back to differs.
class _ChangedDefault {
  const _ChangedDefault(
    this.key,
    this.wire,
    this.row,
    this.wireValue, {
    this.rowsReadWithoutDefault = false,
  });

  /// Stored key and wire field.
  final String key;
  final String wire;

  /// The new default as a stored row and as a wire value. The wire value is
  /// null when the check is off.
  final String row;
  final Object? wireValue;

  /// Every stored row, malformed ones included, reads without the default
  /// (a switch reads anything but `true` as off), so a row read back as the
  /// old default now reads as that same value, which differs from the new
  /// default.
  final bool rowsReadWithoutDefault;
}

/// Smart Night chooses each target's filters unless the user picks one set
/// ('auto'). A run held by a mount fault recovers on its own (owner,
/// 2026-11-17).
const List<_ChangedDefault> _defaultsChangedSinceBase = [
  _ChangedDefault(
    'smart_night_default_strategy',
    'smartNightDefaultStrategy',
    'auto',
    'auto',
  ),
  _ChangedDefault(
    'mount_guard_auto_sync_resume',
    'mountGuardAutoSyncResume',
    'true',
    true,
    rowsReadWithoutDefault: true,
  ),
  _ChangedDefault(
    'image_grading_hfr_threshold_px',
    'imageGradingHfrThresholdPx',
    'null',
    null,
  ),
  _ChangedDefault(
    'image_grading_eccentricity_threshold',
    'imageGradingEccentricityThreshold',
    'null',
    null,
  ),
  _ChangedDefault(
    'image_grading_star_count_min',
    'imageGradingStarCountMin',
    'null',
    null,
  ),
];

final Set<String> _changedDefaultKeys = {
  for (final changed in _defaultsChangedSinceBase) changed.key,
};

/// [fixture] with [_defaultsChangedSinceBase] applied to the base build's
/// defaults.
Map<String, dynamic> _withChangedDefaults(Map<String, dynamic> fixture) {
  final defaults = fixture['defaults'] as Map;
  for (final changed in _defaultsChangedSinceBase) {
    final oldDefault = defaults[changed.key];
    defaults[changed.key] = changed.row;
    (fixture['fromWireEmpty'] as Map)[changed.key] = changed.row;
    (fixture['wireDefault'] as Map)[changed.wire] = changed.wireValue;
    if (!changed.rowsReadWithoutDefault) continue;
    final perRaw = (fixture['fullLoad'] as Map)[changed.key] as Map?;
    perRaw?.updateAll((raw, expected) {
      final read = (expected as Map)[changed.key] ?? oldDefault;
      return read == changed.row ? <String, dynamic>{} : {changed.key: read};
    });
  }
  return fixture;
}

/// [rows], the rows a base install was seeded with, with the changed
/// defaults seeded instead.
Map<String, String> _installRowsWithChangedDefaults(Map<String, String> rows) {
  for (final changed in _defaultsChangedSinceBase) {
    if (rows.containsKey(changed.key)) rows[changed.key] = changed.row;
  }
  return rows;
}

/// [changes] without a change to a value that is now the default: the base
/// build read it as a change from its own default.
Map<String, dynamic> _withoutNewDefaults(Map<String, dynamic> changes) => {
  for (final entry in changes.entries)
    if (!_defaultsChangedSinceBase.any(
      (changed) => changed.key == entry.key && changed.row == entry.value,
    ))
      entry.key: entry.value,
};

/// [rows] without the settings the base build did not have, and without
/// those [_heldNatively].
Map<String, String> _baseOnly(Map<String, String> rows) => {
  for (final entry in rows.entries)
    if (!_addedSinceBase.contains(entry.key) &&
        !_heldNatively.contains(entry.key))
      entry.key: entry.value,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixture = _withChangedDefaults(
    jsonDecode(
          File(
            'test/fixtures/settings/base_settings_behavior.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>,
  );
  final baseDefaults = _baseOnly(
    Map<String, String>.from(fixture['defaults'] as Map),
  );
  final baseStoreRows = Map<String, String>.from(
    fixture['nonDefaultStored'] as Map,
  );
  final baseRows = _baseOnly(baseStoreRows);

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
      for (final key in _heldNatively) {
        expect(allRows, isNot(contains(key)));
        expect(
          await database.settingsDao.getSetting(key),
          baseStoreRows[key],
          reason: '$key stays in the database as the base build wrote it',
        );
      }
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
      // A changed default can be the value the fixture moved it to.
      final atDefault = [
        for (final setting in kAppSettingsTable)
          if (!_addedSinceBase.contains(setting.key) &&
              !_heldNatively.contains(setting.key) &&
              !_changedDefaultKeys.contains(setting.key) &&
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
      final expected = _installRowsWithChangedDefaults(
        Map<String, String>.from(
          jsonDecode(
                File(
                  'test/fixtures/settings/base_install_rows.json',
                ).readAsStringSync(),
              )
              as Map,
        ),
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
            if (all.containsKey(key) &&
                !expected.containsKey(key) &&
                !_addedSinceBase.contains(key))
              key,
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
      if (_heldNatively.contains(key)) {
        expect(
          AppSettingsCodec.toRows(AppSettingsCodec.fromRows({key: 'x'})),
          isNot(contains(key)),
          reason: '$key is never read',
        );
        return;
      }
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
        expect(
          got,
          _withoutNewDefaults(expected as Map<String, dynamic>),
          reason: '$key = ${jsonEncode(raw)}',
        );
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
      if (_heldNatively.contains(key)) {
        expect(
          AppSettingsCodec.toRows(AppSettingsCodec.applyRows(b, {key: 'x'})),
          AppSettingsCodec.toRows(b),
          reason: '$key is never applied',
        );
        return;
      }
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
    final heldWire = {
      for (final setting in kAppSettingsTable)
        if (setting.heldNatively) setting.wire,
    };
    final wireNonDefault = Map<String, dynamic>.from(
      fixture['wireNonDefault'] as Map,
    );
    expect(
      plain(
        AppSettingsCodec.toWire(
          AppSettingsCodec.fromRows(baseRows),
          heldNatively: {
            for (final wire in heldWire) wire: wireNonDefault[wire],
          },
        ),
      ),
      wireNonDefault,
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
      _baseOnly(Map<String, String>.from(fixture['fromWireNonDefault'] as Map)),
    );
    expect(
      _baseOnly(
        AppSettingsCodec.toRows(
          AppSettingsCodec.fromWire(const models.AppSettings()),
        ),
      ),
      _baseOnly(Map<String, String>.from(fixture['fromWireEmpty'] as Map)),
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
      if (setting != null && setting.heldNatively) {
        expect(
          AppSettingsCodec.applyWireChange(b, key, 'x'),
          isNull,
          reason: '$key goes to the preference, not the settings',
        );
        return;
      }
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
