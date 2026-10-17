// Tests for SavedServersService.
//
// The service is a pure data layer: SharedPreferences + secure storage
// + a small JSON blob. We exercise the persistence round-trip, mutation
// helpers, and the legacy-migration latch using
// SharedPreferences.setMockInitialValues + FlutterSecureStorage's
// built-in test helper.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/saved_servers_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Deterministic RNG so generated ids are stable across runs — a
  // collision check elsewhere in the suite would otherwise flake. A
  // counter-based stream is fine here; SavedServersService only uses
  // _random for opaque ids, so any 16-byte sequence works.
  Random fixedRandom() {
    return Random(1);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  group('SavedServer JSON', () {
    test('round-trips non-secret fields without including the auth token', () {
      final s = SavedServer(
        id: 'abc123',
        displayName: 'Observatory',
        host: '10.0.0.4',
        port: 8080,
        authToken: 'super-secret',
        pinnedFingerprint: 'ff' * 32,
        lastConnectedAt: DateTime.parse('2026-05-25T22:30:00Z'),
        notes: 'permanent pier',
      );
      final json = s.toJsonNonSecret();
      expect(
        json.containsKey('authToken'),
        isFalse,
        reason: 'authToken must NEVER leak into the JSON blob',
      );
      expect(json['pinnedFingerprint'], 'ff' * 32);
      final reloaded = SavedServer.fromJsonNonSecret(json);
      expect(reloaded.id, 'abc123');
      expect(reloaded.displayName, 'Observatory');
      expect(reloaded.host, '10.0.0.4');
      expect(reloaded.port, 8080);
      expect(
        reloaded.authToken,
        isNull,
        reason: 'token comes from secure storage, not JSON',
      );
      expect(reloaded.pinnedFingerprint, 'ff' * 32);
      expect(reloaded.lastConnectedAt, DateTime.parse('2026-05-25T22:30:00Z'));
      expect(reloaded.notes, 'permanent pier');
    });

    test('rejects malformed payloads', () {
      expect(
        () => SavedServer.fromJsonNonSecret(<String, dynamic>{
          'displayName': 'x',
          'host': 'h',
          'port': 8080,
        }),
        throwsA(isA<FormatException>()),
        reason: 'missing id must throw',
      );
      expect(
        () => SavedServer.fromJsonNonSecret(<String, dynamic>{
          'id': 'x',
          'displayName': 'y',
          'host': 'h',
          'port': 0,
        }),
        throwsA(isA<FormatException>()),
        reason: 'invalid port (<=0) must throw',
      );
    });
  });

  group('SavedServersService persistence', () {
    test(
      'add then loadAll surfaces the entry, token round-trips secure storage',
      () async {
        final service = SavedServersService(random: fixedRandom());
        final added = await service.add(
          displayName: 'Observatory',
          host: '10.0.0.4',
          port: 8080,
          authToken: 'bearer-token-value',
          pinnedFingerprint: 'ab' * 32,
        );
        expect(added.id, isNotEmpty);

        final all = await service.loadAll();
        expect(all, hasLength(1));
        expect(all.first.displayName, 'Observatory');
        expect(
          all.first.authToken,
          isNull,
          reason: 'loadAll never reads the token; tokenFor does',
        );

        final token = await service.tokenFor(added.id);
        expect(token, 'bearer-token-value');

        // The JSON blob must NOT contain the token.
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(SavedServersStorageKeys.list)!;
        expect(raw.contains('bearer-token-value'), isFalse);
        final decoded = jsonDecode(raw);
        expect(decoded, isA<List>());
      },
    );

    test(
      'upsert by host:port replaces the existing row rather than appending',
      () async {
        final service = SavedServersService(random: fixedRandom());
        final first = await service.add(
          displayName: 'Original',
          host: '10.0.0.4',
          port: 8080,
          authToken: 'token-1',
        );
        final second = await service.upsert(
          displayName: 'Renamed',
          host: '10.0.0.4',
          port: 8080,
          authToken: 'token-2',
        );
        expect(
          second.id,
          first.id,
          reason: 'upsert should reuse the existing row id',
        );
        final all = await service.loadAll();
        expect(all, hasLength(1));
        expect(all.first.displayName, 'Renamed');
        expect(await service.tokenFor(first.id), 'token-2');
      },
    );

    test('upsert with null token leaves the stored token intact', () async {
      final service = SavedServersService(random: fixedRandom());
      final row = await service.add(
        displayName: 'Rig',
        host: '10.0.0.5',
        port: 8080,
        authToken: 'keep-me',
      );
      await service.upsert(
        id: row.id,
        displayName: 'Rig (renamed)',
        host: '10.0.0.5',
        port: 8080,
        // authToken: null — must NOT clear the stored secret
      );
      expect(await service.tokenFor(row.id), 'keep-me');
      final reloaded = (await service.loadAll()).single;
      expect(reloaded.displayName, 'Rig (renamed)');
    });

    test('rename updates only the displayName', () async {
      final service = SavedServersService(random: fixedRandom());
      final row = await service.add(
        displayName: 'A',
        host: '10.0.0.7',
        port: 8080,
      );
      final renamed = await service.rename(row.id, 'Backyard');
      expect(renamed.displayName, 'Backyard');
      final reloaded = (await service.loadAll()).single;
      expect(reloaded.displayName, 'Backyard');
      expect(reloaded.host, '10.0.0.7');
      expect(reloaded.port, 8080);
    });

    test('setNotes persists the free-text field', () async {
      final service = SavedServersService(random: fixedRandom());
      final row = await service.add(
        displayName: 'A',
        host: '10.0.0.7',
        port: 8080,
      );
      await service.setNotes(row.id, 'Travel scope · indoor wifi');
      final reloaded = (await service.loadAll()).single;
      expect(reloaded.notes, 'Travel scope · indoor wifi');
    });

    test('concurrent mutations do not erase one another', () async {
      final service = SavedServersService(random: fixedRandom());
      final row = await service.add(
        displayName: 'Original',
        host: '10.0.0.7',
        port: 8080,
      );

      await Future.wait<Object?>([
        service.rename(row.id, 'Backyard'),
        service.setNotes(row.id, 'Permanent pier'),
        service.touchLastConnected(row.id),
      ]);

      final reloaded = (await service.loadAll()).single;
      expect(reloaded.displayName, 'Backyard');
      expect(reloaded.notes, 'Permanent pier');
      expect(reloaded.lastConnectedAt, isNotNull);
    });

    test('a failed mutation does not poison the mutation queue', () async {
      final service = SavedServersService(random: fixedRandom());

      await expectLater(
        service.rename('missing', 'Never written'),
        throwsStateError,
      );
      final added = await service.add(
        displayName: 'Recovery',
        host: '10.0.0.8',
        port: 8080,
      );

      expect((await service.loadAll()).single.id, added.id);
    });

    test('touchLastConnected stamps now and re-sorts by recency', () async {
      final service = SavedServersService(random: fixedRandom());
      final older = await service.add(
        displayName: 'Older',
        host: '10.0.0.1',
        port: 8080,
        lastConnectedAt: DateTime.now().subtract(const Duration(hours: 4)),
      );
      final newer = await service.add(
        displayName: 'Newer',
        host: '10.0.0.2',
        port: 8080,
        lastConnectedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );
      var all = await service.loadAll();
      expect(all.first.id, newer.id);
      await service.touchLastConnected(older.id);
      all = await service.loadAll();
      expect(
        all.first.id,
        older.id,
        reason: 'touching lastConnected re-sorts to the top',
      );
    });

    test(
      'removeById drops the row and wipes its secure-storage token',
      () async {
        final service = SavedServersService(random: fixedRandom());
        final a = await service.add(
          displayName: 'A',
          host: '10.0.0.1',
          port: 8080,
          authToken: 'token-a',
        );
        final b = await service.add(
          displayName: 'B',
          host: '10.0.0.2',
          port: 8080,
          authToken: 'token-b',
        );
        await service.removeById(a.id);
        final remaining = await service.loadAll();
        expect(remaining, hasLength(1));
        expect(remaining.single.id, b.id);
        expect(
          await service.tokenFor(a.id),
          isNull,
          reason: 'token must be wiped on removal',
        );
        expect(await service.tokenFor(b.id), 'token-b');
      },
    );

    test('removeToken keeps the row but clears the stored secret', () async {
      final service = SavedServersService(random: fixedRandom());
      final row = await service.add(
        displayName: 'A',
        host: '10.0.0.1',
        port: 8080,
        authToken: 'token-x',
      );
      await service.removeToken(row.id);
      final reloaded = (await service.loadAll()).single;
      expect(reloaded.id, row.id);
      expect(await service.tokenFor(row.id), isNull);
    });

    test(
      'toDiscoveredServer composes the legacy DiscoveredServer shape',
      () async {
        final service = SavedServersService(random: fixedRandom());
        final row = await service.add(
          displayName: 'Backyard',
          host: '10.0.0.50',
          port: 8081,
          authToken: 'paired-token',
          pinnedFingerprint: 'cd' * 32,
        );
        final ds = await service.toDiscoveredServer(row.id);
        expect(ds, isNotNull);
        expect(ds!.host, '10.0.0.50');
        expect(ds.webPort, 8081);
        expect(ds.authToken, 'paired-token');
        expect(ds.fingerprint, 'cd' * 32);
        expect(ds.authRequired, isTrue);
      },
    );
  });

  group('SavedServersService corruption handling', () {
    test(
      'non-JSON blob is dropped (logged) and loadAll returns empty',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          SavedServersStorageKeys.list: '{not valid json',
          // Pretend migration already ran so loadAll doesn't try to
          // import a legacy entry on top.
          SavedServersStorageKeys.migrated: true,
        });
        final service = SavedServersService(random: fixedRandom());
        final all = await service.loadAll();
        expect(all, isEmpty);
        // After the reset, a subsequent add should land cleanly.
        await service.add(displayName: 'Fresh', host: '10.0.0.1', port: 8080);
        expect(await service.loadAll(), hasLength(1));
      },
    );

    test(
      'malformed individual rows are skipped but valid ones survive',
      () async {
        final goodRow = {
          'id': 'good-1',
          'displayName': 'Good',
          'host': '10.0.0.10',
          'port': 8080,
        };
        final badRow = {
          // missing id
          'displayName': 'Bad',
          'host': '10.0.0.11',
          'port': 8080,
        };
        SharedPreferences.setMockInitialValues(<String, Object>{
          SavedServersStorageKeys.list: jsonEncode([goodRow, badRow]),
          SavedServersStorageKeys.migrated: true,
        });
        final service = SavedServersService(random: fixedRandom());
        final all = await service.loadAll();
        expect(all, hasLength(1));
        expect(all.single.id, 'good-1');
      },
    );
  });

  group('SavedServersService legacy migration', () {
    test(
      'with no legacy server, migration is a no-op and sets the latch',
      () async {
        final service = SavedServersService(random: fixedRandom());
        final all = await service.loadAll();
        expect(all, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(SavedServersStorageKeys.migrated), isTrue);
      },
    );

    test(
      'legacy migration latch prevents re-import across loadAll calls',
      () async {
        // Pre-seed the latch so loadAll skips the import phase, then
        // verify a synthetic entry survives multiple loadAll calls.
        SharedPreferences.setMockInitialValues(<String, Object>{
          SavedServersStorageKeys.migrated: true,
        });
        final service = SavedServersService(random: fixedRandom());
        final added = await service.add(
          displayName: 'Imported',
          host: '10.0.0.99',
          port: 8080,
        );
        final first = await service.loadAll();
        final second = await service.loadAll();
        expect(first, hasLength(1));
        expect(second, hasLength(1));
        expect(first.first.id, added.id);
        expect(second.first.id, added.id);
      },
    );
  });
}
