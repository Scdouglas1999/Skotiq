// What a switch that is on by default reads from row text no build writes
// (`1`, `True`, an empty row, ...). Each such switch keeps the reading its
// own reader had before it was declared in the settings catalog, so a
// database carrying such a row (hand-edited, restored from another tool)
// behaves as it did.
//
// A switch added to either catalog with a default of on has to be placed in
// one of the three groups below, which is a decision about those rows.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/settings/app_settings_table.dart';
import 'package:skotiq_core/src/settings/setting.dart';
import 'package:skotiq_core/src/settings/store_settings.dart';

/// Read by the feature with [Setting.decodeStrict]: it stops on text it
/// cannot read instead of running with a value the operator did not choose.
const _strictlyRead = {
  'replay_debug.enabled',
  'science.overlay.enabled',
  'science.feature.photometry',
  'science.feature.photometric_calibration',
  'science.feature.transparency',
  'science.feature.psf_map',
  'science.feature.astrometric_residuals',
  'science.feature.frame_quality_maps',
  'science.feature.surface3d',
  'science.retention.manual_purge_only',
  'science.writeback.fits_header_enabled',
};

/// Their readers took anything but `false` as on (or, for the alert switch,
/// anything unreadable as the default, which is on).
const _onUnlessFalse = {
  'tutorials_enabled',
  'frame_watch_recenter_enabled',
  'frame_watch_obstruction_detection',
  'calibration.auto_dark_from_library',
  'transient_alert_notify_on_new',
};

void main() {
  final defaultOn = [
    for (final setting in [...kAppSettingsTable, ...StoreSettings.all])
      if (setting is BoolSetting && setting.fallback) setting,
  ];
  final storeKeys = {for (final setting in StoreSettings.all) setting.key};

  test('every default-on switch of the features has a decided reading', () {
    final undecided = [
      for (final setting in defaultOn)
        if (storeKeys.contains(setting.key) &&
            !_strictlyRead.contains(setting.key) &&
            !_onUnlessFalse.contains(setting.key))
          setting.key,
    ];
    expect(undecided, isEmpty);
    expect(
      {
        ..._strictlyRead,
        ..._onUnlessFalse,
      }.difference({for (final setting in defaultOn) setting.key}),
      isEmpty,
      reason: 'a listed key is no longer a default-on switch',
    );
  });

  for (final setting in defaultOn) {
    bool read(String? raw) => setting.decode(raw, setting.fallback);

    if (_strictlyRead.contains(setting.key)) {
      test('${setting.key} is read strictly', () {
        expect(setting.decodeStrict(null), isTrue);
        expect(setting.decodeStrict(''), isTrue);
        expect(setting.decodeStrict('true'), isTrue);
        expect(setting.decodeStrict('True'), isTrue);
        expect(setting.decodeStrict('false'), isFalse);
        expect(setting.decodeStrict(' FALSE '), isFalse);
        expect(() => setting.decodeStrict('1'), throwsFormatException);
        expect(() => setting.decodeStrict('0'), throwsFormatException);
        expect(() => setting.decodeStrict('yes'), throwsFormatException);
      });
    } else if (_onUnlessFalse.contains(setting.key)) {
      test('${setting.key} is on unless the row says false', () {
        expect(read(null), isTrue);
        expect(read('true'), isTrue);
        expect(read('True'), isTrue);
        expect(read('1'), isTrue);
        expect(read('0'), isTrue);
        expect(read(''), isTrue);
        expect(read('yes'), isTrue);
        expect(read('false'), isFalse);
        expect(read('FALSE'), isFalse);
      });
    } else {
      // The application settings: as the reader they had before the catalog
      // (`value.toLowerCase() == 'true'`, default only with no row).
      test('${setting.key} is on only for true', () {
        expect(read(null), isTrue);
        expect(read('true'), isTrue);
        expect(read('True'), isTrue);
        expect(read('TRUE'), isTrue);
        expect(read('false'), isFalse);
        expect(read('1'), isFalse);
        expect(read('0'), isFalse);
        expect(read(''), isFalse);
        expect(read('yes'), isFalse);
      });
    }
  }

  test('connecting the equipment at start needs a stored yes', () {
    final setting = kAppSettingsTable.singleWhere(
      (setting) => setting.key == 'auto_connect_equipment',
    );
    // The setting is on when nothing is stored (and an install is seeded
    // with that row); the start-up reader asks with off as the answer for a
    // missing row. `settings_provider.dart` AutoConnectSettingsNotifier.
    expect(setting.fallback, isTrue);
    expect(setting.fromRows(const {}, false), isFalse);
    expect(
      setting.fromRows(const {'auto_connect_equipment': 'true'}, false),
      isTrue,
    );
    expect(
      setting.fromRows(const {'auto_connect_equipment': 'false'}, false),
      isFalse,
    );
    expect(
      setting.fromRows(const {'auto_connect_equipment': ''}, false),
      isFalse,
    );
    expect(
      setting.fromRows(const {'auto_connect_equipment': '1'}, false),
      isFalse,
    );
  });
}
