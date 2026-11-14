// The location lives in two stores and both must be written.
//
// `POST /api/settings/location` writes the canonical backend (native) store,
// which `GET /api/settings/location` and the planetarium read. The scheduler
// and "tonight" suggestion subsystems read observer lat/lon from the Drift
// `settingsDao`, which on a headless appliance is otherwise only populated by
// the GUI settings flow that never runs there — so without the mirror a remote
// client gets a working planetarium and a permanently "No observer location
// configured" scheduler.
//
// This test pins the mirror in `handleSetLocation` so the two stores cannot
// silently diverge.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart' as settings_models;
import 'package:skotiq_core/models.dart' as settings_models;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_desktop/headless_api/handlers/profile_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// Minimal fake whose `setLocation` succeeds (the real disconnected backend
/// throws NotConnected, which would short-circuit the handler before the
/// mirror runs). Only the two location methods are exercised here.
class _FakeProfileSettingsBackend implements ProfileSettingsBackend {
  settings_models.ObserverLocation? _location;

  @override
  Future<void> setLocation(settings_models.ObserverLocation? location) async {
    _location = location;
  }

  @override
  Future<settings_models.ObserverLocation?> getLocation() async => _location;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  test('set location mirrors lat/lon/elev into the settings DAO', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        profileSettingsBackendProvider.overrideWithValue(
          _FakeProfileSettingsBackend(),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    // DAO starts unset (zeros) — the scheduler reads this as "no location".
    expect(await db.settingsDao.read(AppSettingDefs.latitude), 0.0);

    final handlers = ProfileHandlers(container);
    final response = await handlers.handleSetLocation(
      Request(
        'POST',
        Uri.parse('http://localhost/api/settings/location'),
        body: jsonEncode({
          'location': {'latitude': 40.0, 'longitude': -74.0, 'elevation': 50.0},
        }),
      ),
    );
    expect(response.statusCode, 200);

    // The mirror must have populated the DAO that the scheduler reads.
    expect(await db.settingsDao.read(AppSettingDefs.latitude), 40.0);
    expect(await db.settingsDao.read(AppSettingDefs.longitude), -74.0);
    expect(await db.settingsDao.read(AppSettingDefs.elevation), 50.0);
  });

  test('clearing location zeroes the mirrored DAO values', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    await db.settingsDao.write(AppSettingDefs.latitude, 12.0);
    await db.settingsDao.write(AppSettingDefs.longitude, 34.0);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        profileSettingsBackendProvider.overrideWithValue(
          _FakeProfileSettingsBackend(),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final handlers = ProfileHandlers(container);
    final response = await handlers.handleSetLocation(
      Request(
        'POST',
        Uri.parse('http://localhost/api/settings/location'),
        body: jsonEncode({'location': null}),
      ),
    );
    expect(response.statusCode, 200);

    expect(await db.settingsDao.read(AppSettingDefs.latitude), 0.0);
    expect(await db.settingsDao.read(AppSettingDefs.longitude), 0.0);
  });

  test(
    'a body without the location wrapper is refused and keeps the site',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final backend = _FakeProfileSettingsBackend();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          profileSettingsBackendProvider.overrideWithValue(backend),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      final handlers = ProfileHandlers(container);
      Future<Response> post(Object body) => translateHandlerErrors(
        handlers.handleSetLocation(
          Request(
            'POST',
            Uri.parse('http://localhost/api/settings/location'),
            body: jsonEncode(body),
          ),
        ),
      );

      expect(
        (await post({
          'location': {
            'latitude': 44.5,
            'longitude': -121.3,
            'elevation': 100.0,
          },
        })).statusCode,
        200,
      );
      final bare = await post({
        'latitude': 40.0,
        'longitude': -100.0,
        'elevation': 5.0,
      });
      expect(bare.statusCode, 400);
      expect((await backend.getLocation())?.latitude, 44.5);
      expect(await db.settingsDao.read(AppSettingDefs.latitude), 44.5);

      final partial = await post({
        'location': {'latitude': 40.0},
      });
      expect(partial.statusCode, 400);
      expect((await backend.getLocation())?.latitude, 44.5);

      // An explicit null still clears it.
      expect((await post({'location': null})).statusCode, 200);
      expect(await backend.getLocation(), isNull);
    },
  );
}
