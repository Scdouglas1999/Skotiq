import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_planetarium/src/catalogs/mpcorb.dart';
import 'package:skotiq_planetarium/src/services/element_refresh_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_element_refresh_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // One real-format MPCORB record (Ceres) the parser accepts.
  const ceresMpcorb =
      '00001    3.34  0.12 K239D  60.07881   73.42179   80.25496   10.58688  '
      '0.0788175  0.21424651   2.7656460  0 MPO719049  7283 122 1801-2023 0.65 '
      'M-v 30h MPCLINUX   0000      (1) Ceres              20230906';

  // One CometEls.txt record (Halley).
  const halleyComet =
      '0001P         1986 02  9.6671  0.587104  0.967658  111.3324   58.4204'
      '  162.2627  20240101  4.0  6.0  1P/Halley';

  group('ElementRefreshService', () {
    test('refresh downloads, caches to disk, and parses', () async {
      final service = ElementRefreshService(
        cacheDirectory: tempDir.path,
        clientFactory: () => MockClient((req) async {
          if (req.url.path.contains('CometEls') ||
              req.url.toString().contains('Comet')) {
            return http.Response(halleyComet, 200);
          }
          return http.Response(ceresMpcorb, 200);
        }),
        now: () => DateTime.utc(2026, 6, 1),
      );

      final result = await service.refresh();
      expect(result.asteroids, isNotEmpty);
      expect(result.asteroids.first.commonName, 'Ceres');
      expect(result.comets, isNotEmpty);

      // Disk cache was written.
      expect(File('${tempDir.path}/mpc_asteroids.txt').existsSync(), isTrue);
      expect(File('${tempDir.path}/mpc_comets.txt').existsSync(), isTrue);
    });

    test('loadCached reads disk without hitting the network', () async {
      // Seed the cache via a refresh.
      await ElementRefreshService(
        cacheDirectory: tempDir.path,
        clientFactory: () => MockClient((req) async {
          if (req.url.toString().contains('Comet')) {
            return http.Response(halleyComet, 200);
          }
          return http.Response(ceresMpcorb, 200);
        }),
        now: () => DateTime.utc(2026, 6, 1),
      ).refresh();

      // A fresh service with a client that would THROW if called.
      final offline = ElementRefreshService(
        cacheDirectory: tempDir.path,
        clientFactory: () =>
            MockClient((_) async => throw StateError('network used')),
      );
      final cached = await offline.loadCached();
      expect(cached.asteroids, isNotEmpty);
      expect(cached.asteroids.first.commonName, 'Ceres');
    });

    test('refresh falls back to stale cache when the network fails', () async {
      // Seed cache.
      await ElementRefreshService(
        cacheDirectory: tempDir.path,
        clientFactory: () => MockClient((req) async {
          if (req.url.toString().contains('Comet')) {
            return http.Response(halleyComet, 200);
          }
          return http.Response(ceresMpcorb, 200);
        }),
        now: () => DateTime.utc(2026, 6, 1),
      ).refresh();

      // Now both endpoints 500 — should keep the cached asteroids.
      final failing = ElementRefreshService(
        cacheDirectory: tempDir.path,
        clientFactory: () => MockClient((_) async => http.Response('', 500)),
        now: () => DateTime.utc(2026, 6, 8),
      );
      final result = await failing.refresh();
      expect(
        result.asteroids,
        isNotEmpty,
        reason: 'stale cache should survive a failed refresh',
      );
      expect(result.hasRefreshFailures, isTrue);
      expect(result.asteroidRefreshError, isNotNull);
      expect(result.cometRefreshError, isNotNull);
    });

    test(
      'a one-source failure is visible alongside the successful source',
      () async {
        final service = ElementRefreshService(
          cacheDirectory: tempDir.path,
          clientFactory: () => MockClient((request) async {
            if (request.url.toString().contains('Comet')) {
              return http.Response(halleyComet, 200);
            }
            return http.Response('', 503);
          }),
          now: () => DateTime.utc(2026, 6, 1),
        );

        final result = await service.refresh();

        expect(result.asteroids, isEmpty);
        expect(result.comets, isNotEmpty);
        expect(result.asteroidRefreshError, contains('503'));
        expect(result.cometRefreshError, isNull);
        expect(result.refreshFailureSummary, contains('Asteroids'));
      },
    );

    test('network requests have a finite timeout', () async {
      final service = ElementRefreshService(
        cacheDirectory: tempDir.path,
        requestTimeout: const Duration(milliseconds: 1),
        clientFactory: () => MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response(ceresMpcorb, 200);
        }),
      );

      await expectLater(service.refresh(), throwsA(isA<Exception>()));
    });

    test(
      'refresh throws only when network fails AND nothing is cached',
      () async {
        final service = ElementRefreshService(
          cacheDirectory: tempDir.path,
          clientFactory: () => MockClient((_) async => http.Response('', 503)),
        );
        expect(service.refresh(), throwsA(isA<Exception>()));
      },
    );

    test('isStale respects the schedule', () {
      final service = ElementRefreshService(
        cacheDirectory: tempDir.path,
        now: () => DateTime.utc(2026, 6, 10),
      );
      const weekly = ElementRefreshConfig();
      final one = [MpcOrbParser.parseAsteroidLine(ceresMpcorb)!];
      final fresh = RefreshedElements(
        asteroids: one,
        asteroidsFetchedAt: DateTime.utc(2026, 6, 9),
      );
      final old = RefreshedElements(
        asteroids: one,
        asteroidsFetchedAt: DateTime.utc(2026, 5, 1),
      );
      expect(service.isStale(fresh, weekly), isFalse);
      expect(service.isStale(old, weekly), isTrue);

      const manual = ElementRefreshConfig(
        schedule: ElementRefreshSchedule.manual,
      );
      expect(service.isStale(old, manual), isFalse);
    });

    test('config persists and reloads', () async {
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      const cfg = ElementRefreshConfig(
        schedule: ElementRefreshSchedule.daily,
        maxAsteroidAbsoluteMag: 9.0,
      );
      await service.saveConfig(cfg);
      final loaded = await service.loadConfig();
      expect(loaded.schedule, ElementRefreshSchedule.daily);
      expect(loaded.maxAsteroidAbsoluteMag, 9.0);
    });
  });

  group('ElementRefreshConfig authority', () {
    String configPath() => '${tempDir.path}/element_refresh_config.json';
    Future<void> writeConfig(String contents) =>
        File(configPath()).writeAsString(contents);

    test('missing config file is a legitimate first-run default', () async {
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      final cfg = await service.loadConfig();
      expect(cfg.schedule, ElementRefreshSchedule.weekly);
      expect(cfg.asteroidUrl, ElementRefreshConfig.defaultAsteroidUrl);
      expect(cfg.cometUrl, ElementRefreshConfig.defaultCometUrl);
    });

    test('corrupt JSON throws instead of masquerading as defaults', () async {
      await writeConfig('{not valid json');
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      expect(service.loadConfig(), throwsA(isA<FormatException>()));
    });

    test('non-object JSON throws', () async {
      await writeConfig('[1, 2, 3]');
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      expect(service.loadConfig(), throwsA(isA<FormatException>()));
    });

    test('unknown schedule name throws', () async {
      await writeConfig(jsonEncode({'schedule': 'biweekly'}));
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      expect(service.loadConfig(), throwsA(isA<FormatException>()));
    });

    test('wrong-typed schedule throws', () async {
      await writeConfig(jsonEncode({'schedule': 7}));
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      expect(service.loadConfig(), throwsA(isA<FormatException>()));
    });

    test('empty / non-http / hostless URLs throw', () async {
      for (final bad in <String>[
        '',
        'ftp://example.com/x',
        'not-a-url',
        'http://',
        '/relative/path.txt',
      ]) {
        await writeConfig(jsonEncode({'asteroidUrl': bad}));
        final service = ElementRefreshService(cacheDirectory: tempDir.path);
        await expectLater(
          service.loadConfig(),
          throwsA(isA<FormatException>()),
          reason: 'URL "$bad" should be rejected',
        );
      }
    });

    test('templated asteroid {year} URL is accepted', () async {
      await writeConfig(
        jsonEncode({
          'asteroidUrl': 'https://example.org/mpc/{year}/bright.txt',
        }),
      );
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      final cfg = await service.loadConfig();
      expect(cfg.asteroidUrl, contains('{year}'));
    });

    test('unknown or unsupported URL placeholders are rejected', () async {
      for (final config in [
        {'asteroidUrl': 'https://example.org/{month}/bright.txt'},
        {'cometUrl': 'https://example.org/{year}/comets.txt'},
      ]) {
        await writeConfig(jsonEncode(config));
        final service = ElementRefreshService(cacheDirectory: tempDir.path);
        await expectLater(service.loadConfig(), throwsFormatException);
      }
    });

    test('auto retry cooldown suppresses restart hammering', () async {
      final now = DateTime.utc(2026, 6, 1, 12);
      final service = ElementRefreshService(
        cacheDirectory: tempDir.path,
        now: () => now,
      );

      expect(service.isAutoRetryDue(null), isTrue);
      expect(
        service.isAutoRetryDue(now.subtract(const Duration(minutes: 59))),
        isFalse,
      );
      expect(
        service.isAutoRetryDue(now.subtract(const Duration(hours: 1))),
        isTrue,
      );
      expect(
        service.isAutoRetryDue(now.add(const Duration(minutes: 1))),
        isTrue,
      );
    });

    test('wrong-typed magnitude throws', () async {
      await writeConfig(jsonEncode({'maxAsteroidAbsoluteMag': 'bright'}));
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      expect(service.loadConfig(), throwsA(isA<FormatException>()));
    });

    test('out-of-range magnitude throws', () async {
      await writeConfig(jsonEncode({'maxAsteroidAbsoluteMag': 1e9}));
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      expect(service.loadConfig(), throwsA(isA<FormatException>()));
    });

    test('non-finite magnitude fails validation', () {
      expect(
        () => ElementRefreshConfig.validate(
          const ElementRefreshConfig(maxAsteroidAbsoluteMag: double.infinity),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('genuinely missing optional keys fall back to defaults', () async {
      await writeConfig(jsonEncode({'schedule': 'daily'}));
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      final cfg = await service.loadConfig();
      expect(cfg.schedule, ElementRefreshSchedule.daily);
      expect(cfg.asteroidUrl, ElementRefreshConfig.defaultAsteroidUrl);
      expect(cfg.cometUrl, ElementRefreshConfig.defaultCometUrl);
      expect(
        cfg.maxAsteroidAbsoluteMag,
        ElementRefreshConfig.defaultMaxAsteroidAbsoluteMag,
      );
    });

    test(
      'saveConfig rejects an invalid config and preserves the prior file',
      () async {
        final service = ElementRefreshService(cacheDirectory: tempDir.path);
        await service.saveConfig(
          const ElementRefreshConfig(schedule: ElementRefreshSchedule.daily),
        );

        // A config with a bad URL must be rejected BEFORE the file is touched.
        await expectLater(
          service.saveConfig(
            const ElementRefreshConfig(asteroidUrl: 'nonsense'),
          ),
          throwsA(isA<FormatException>()),
        );

        final loaded = await service.loadConfig();
        expect(
          loaded.schedule,
          ElementRefreshSchedule.daily,
          reason: 'prior valid config must survive a rejected save',
        );
        expect(File('${configPath()}.tmp').existsSync(), isFalse);
      },
    );

    test('successful atomic save leaves no temp file behind', () async {
      final service = ElementRefreshService(cacheDirectory: tempDir.path);
      await service.saveConfig(
        const ElementRefreshConfig(schedule: ElementRefreshSchedule.monthly),
      );
      expect(File('${configPath()}.tmp').existsSync(), isFalse);
      expect(File(configPath()).existsSync(), isTrue);
      final loaded = await service.loadConfig();
      expect(loaded.schedule, ElementRefreshSchedule.monthly);
    });

    test(
      'loadCached stays offline-safe when the config authority is corrupt',
      () async {
        // A valid asteroid cache sitting next to a corrupt config file.
        await File(
          '${tempDir.path}/mpc_asteroids.txt',
        ).writeAsString(ceresMpcorb);
        await writeConfig('{ broken');
        final service = ElementRefreshService(cacheDirectory: tempDir.path);

        // loadConfig itself surfaces the corruption...
        await expectLater(
          service.loadConfig(),
          throwsA(isA<FormatException>()),
        );
        // ...but cached elements still load using the default parse threshold.
        final cached = await service.loadCached();
        expect(cached.asteroids, isNotEmpty);
        expect(cached.asteroids.first.commonName, 'Ceres');
      },
    );
  });
}
