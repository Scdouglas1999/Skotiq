// The online-catalog gate FAILS CLOSED.
//
// `_onlineEnabled()` decides whether the photometric catalog service is
// allowed to perform network egress (live APASS/VizieR cone searches). When
// the settings read faults it must default to OFFLINE (false) so a broken
// settings store can never silently open network access. The absent-key
// product default (no row => online) is preserved.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/services/science/photometric_catalog_service.dart';

class _ThrowingSettingsDao extends SettingsDao {
  _ThrowingSettingsDao(super.db);

  @override
  Future<String?> getSetting(String key) async {
    throw StateError('settings store unavailable');
  }
}

void main() {
  late SkotiqDatabase db;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  PhotometricCatalogService serviceWith(SettingsDao dao) {
    final container = ProviderContainer(
      overrides: [settingsDaoProvider.overrideWithValue(dao)],
    );
    addTearDown(container.dispose);
    return container.read(photometricCatalogServiceProvider);
  }

  test('fails CLOSED (returns false) when the settings read throws', () async {
    final service = serviceWith(_ThrowingSettingsDao(db));
    expect(await service.debugOnlineEnabled(), isFalse);
  });

  test('returns false when the setting is explicitly disabled', () async {
    await db.settingsDao.setSetting(
      PhotometricCatalogService.onlineEnabledSettingKey,
      'false',
    );
    final service = serviceWith(db.settingsDao);
    expect(await service.debugOnlineEnabled(), isFalse);
  });

  test('defaults to online-enabled when the setting is absent', () async {
    final service = serviceWith(db.settingsDao);
    expect(await service.debugOnlineEnabled(), isTrue);
  });
}
