import 'dart:io';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show PhotometricBand, PhotometricCatalogService, PhotometricCatalogSource;

/// A VizieR APASS response with [rows] stars around M67, with r'mag.
String _vizier(int rows) {
  final b = StringBuffer()
    ..writeln('#INFO\tservice_protocol=ASU')
    ..writeln("RAJ2000\tDEJ2000\tVmag\tBmag\tr'mag")
    ..writeln('deg\tdeg\tmag\tmag\tmag')
    ..writeln('----------\t----------\t------\t------\t------');
  for (var i = 0; i < rows; i++) {
    b.writeln(
      '${(132.8 + (i % 200) * 1e-3).toStringAsFixed(6)}\t'
      '+${(11.8 + (i ~/ 200) * 1e-3).toStringAsFixed(6)}\t13.000\t13.600\t12.850',
    );
  }
  return b.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late SkotiqDatabase db;

  setUp(() {
    support = Directory.systemTemp.createTempSync('apass-cache-test');
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );
  });
  tearDown(() async {
    await db.close();
    support.deleteSync(recursive: true);
  });

  Future<int> requestsForTwoCones(int rows) async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(_vizier(rows), 200);
    });
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final serviceProvider = Provider(
      (ref) => PhotometricCatalogService(ref, client: client),
    );
    final service = container.read(serviceProvider);
    for (var i = 0; i < 2; i++) {
      final cone = await service.coneSearch(
        raDegrees: 132.85,
        decDegrees: 11.82,
        radiusDegrees: 0.5,
      );
      expect(cone.source, PhotometricCatalogSource.localApass);
      expect(cone.stars.first.magIn(PhotometricBand.sloanR), 12.85);
    }
    return requests;
  }

  test(
    'a complete cone is fetched once and then read from the cache',
    () async {
      expect(await requestsForTwoCones(1200), 1);
    },
  );

  test('a cone cut off at the row limit is used but not cached', () async {
    expect(await requestsForTwoCones(20000), 2);
  });
  test(
    'failed requests do not delay every sequential science consumer',
    () async {
      var requests = 0;
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final provider = Provider(
        (ref) => PhotometricCatalogService(
          ref,
          client: MockClient((_) async {
            requests++;
            throw TimeoutException('offline');
          }),
        ),
      );
      final service = container.read(provider);
      for (var i = 0; i < 3; i++) {
        final result = await service.coneSearch(
          raDegrees: 24.2,
          decDegrees: 15.8,
          radiusDegrees: 1.25,
        );
        expect(result.source, PhotometricCatalogSource.localHyg);
      }
      expect(requests, 2); // One attempt per mirror, not per consumer.
    },
  );

  test(
    'a failed mirror falls back to the other mirror and caches the result',
    () async {
      final hosts = <String>[];
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final provider = Provider(
        (ref) => PhotometricCatalogService(
          ref,
          client: MockClient((r) async {
            hosts.add(r.url.host);
            if (r.url.host == 'vizier.cds.unistra.fr') {
              throw TimeoutException('offline');
            }
            return http.Response(_vizier(1200), 200);
          }),
        ),
      );
      final service = container.read(provider);
      for (var i = 0; i < 2; i++) {
        final result = await service.coneSearch(
          raDegrees: 132.85,
          decDegrees: 11.82,
          radiusDegrees: .5,
        );
        expect(result.source, PhotometricCatalogSource.localApass);
      }
      expect(hosts, ['vizier.cds.unistra.fr', 'vizier.idia.ac.za']);
    },
  );

  test(
    'failed endpoints are retried after cooldown, including invalid HTTP 200 tables',
    () async {
      var now = DateTime.utc(2026, 10, 30);
      var requests = 0;
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final provider = Provider(
        (ref) => PhotometricCatalogService(
          ref,
          now: () => now,
          client: MockClient((_) async {
            requests++;
            return http.Response('<html>temporarily unavailable</html>', 200);
          }),
        ),
      );
      final service = container.read(provider);
      Future<void> query() async {
        final result = await service.coneSearch(
          raDegrees: 24.2,
          decDegrees: 15.8,
          radiusDegrees: 1.25,
        );
        expect(result.source, PhotometricCatalogSource.localHyg);
      }

      await query();
      now = now.add(const Duration(minutes: 4));
      await query();
      expect(requests, 2);
      now = now.add(const Duration(minutes: 1));
      await query();
      expect(requests, 4);
    },
  );
}
