// Settings shared between a host and its linked clients: a save sends only
// what it changed, and a JSON-object row is merged field by field.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart' as models;
import 'package:skotiq_core/src/providers/settings_provider.dart';

void main() {
  group('remoteSettingsPatch', () {
    const before = models.AppSettings(
      autoConnect: true,
      fileNamingPattern: r'$TARGET',
      latitude: 44.5,
      longitude: -121.3,
      elevation: 100,
      location: models.ObserverLocation(
        latitude: 44.5,
        longitude: -121.3,
        elevation: 100,
      ),
    );

    test('carries only the changed field', () {
      final patch = remoteSettingsPatch(
        before,
        before.copyWith(fileNamingPattern: r'$TARGET_X'),
      );
      expect(patch, {'fileNamingPattern': r'$TARGET_X'});
    });

    test('is empty when nothing changed', () {
      expect(remoteSettingsPatch(before, before), isEmpty);
    });

    test('a site change carries the whole site', () {
      final patch = remoteSettingsPatch(
        before,
        before.copyWith(
          latitude: 40,
          location: const models.ObserverLocation(
            latitude: 40,
            longitude: -121.3,
            elevation: 100,
          ),
        ),
      );
      expect(patch.keys.toSet(), {
        'latitude',
        'longitude',
        'elevation',
        'location',
      });
      expect((patch['location'] as Map)['latitude'], 40);
    });
  });

  group('SettingsDao.mergeJsonObject', () {
    test('lays fields over the stored object', () {
      final merged = SettingsDao.mergeJsonObject(
        '{"exposureTime":12.0,"gain":100}',
        {'gain': 222},
        base: {'exposureTime': 2.0, 'gain': 0, 'offset': 50},
      );
      expect(jsonDecode(merged), {'exposureTime': 12.0, 'gain': 222});
    });

    test('starts from base when no object is stored', () {
      for (final current in [null, '', 'not json', '[1,2]']) {
        final merged = SettingsDao.mergeJsonObject(
          current,
          {'gain': 5},
          base: {'exposureTime': 2.0, 'gain': 0},
        );
        expect(jsonDecode(merged), {
          'exposureTime': 2.0,
          'gain': 5,
        }, reason: '$current');
      }
    });
  });
}
