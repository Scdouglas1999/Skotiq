// Tests for /api/catalog/... handlers.
//
// Uses a temp-directory CatalogManager.instance (the manager is a
// singleton; we re-initialize per test). The download path's network
// fetch is exercised only at the wiring level (jobId returned, job
// queued) — actual byte streaming is covered through the
// installFromFile flow, which exercises the same SHA-256 / metadata /
// loader-invalidation code paths without hitting the real upstream.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/catalog_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

Future<void> _pumpUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('pumpUntil predicate did not become true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Builds a minimum-viable NGC.csv body matching the OpenNGC schema so
/// `_countObjects` returns a sensible non-zero count after install.
String _miniNgcCsvBody() {
  const header =
      'Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;'
      'SurfBr;Hubble;Pax;Pm-RA;Pm-Dec;RadVel;Redshift;Cstar U-Mag;Cstar B-Mag;'
      'Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;Common names;NED notes;'
      'OpenNGC notes;Sources';
  const row =
      'NGC0001;G;00:07:15.84;+27:42:29.1;Peg;1.59;1.07;112;;13.4;;;;;Sb;;;;;;;;;;;;;;;;;';
  return '$header\n$row\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CatalogHandlers', () {
    late Directory tempCatalogDir;
    late JobManager jobManager;
    late CatalogHandlers handlers;
    late List<({String eventType, Map<String, Object?> data})> emittedEvents;
    late StreamSubscription<CatalogEvent> evtSub;

    setUp(() async {
      tempCatalogDir = await Directory.systemTemp.createTemp(
        'ns_catalog_handlers_test_',
      );
      await CatalogManager.instance.initialize(tempCatalogDir.path);

      emittedEvents = [];
      evtSub = CatalogManager.instance.events.listen((e) {
        emittedEvents.add((eventType: e.eventType, data: e.data));
      });

      jobManager = JobManager(emitEvent: (_) {});
      handlers = CatalogHandlers(jobManager: jobManager);
    });

    tearDown(() async {
      await evtSub.cancel();
      await jobManager.dispose();
      for (final name in CatalogManager.knownCatalogs.keys) {
        try {
          await CatalogManager.instance.uninstall(name);
        } catch (_) {
          // Best-effort cleanup.
        }
      }
      if (await tempCatalogDir.exists()) {
        await tempCatalogDir.delete(recursive: true);
      }
    });

    // GET /api/catalog/status
    test('returns missing entries when nothing installed', () async {
      final response = await translateHandlerErrors(
        handlers.handleStatus(
          Request('GET', Uri.parse('http://localhost/api/catalog/status')),
        ),
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      final catalogs = body['catalogs'] as List;
      expect(catalogs.length, CatalogManager.knownCatalogs.length);
      for (final c in catalogs) {
        expect((c as Map)['status'], 'missing');
      }
      expect(body['totalBytes'], 0);
      expect(body['dataDir'], isA<String>());
    });

    test('reports installed entries after installFromFile', () async {
      final csv = _miniNgcCsvBody();
      final csvBytes = utf8.encode(csv);
      final expectedSha = sha256.convert(csvBytes).toString();
      final src = await Directory.systemTemp.createTemp('ns_src_');
      final srcFile = File('${src.path}/source.csv');
      await srcFile.writeAsString(csv);
      await CatalogManager.instance.installFromFile(
        name: 'dso',
        source: srcFile,
        expectedSha256: expectedSha,
      );
      await src.delete(recursive: true);

      final response = await translateHandlerErrors(
        handlers.handleStatus(
          Request('GET', Uri.parse('http://localhost/api/catalog/status')),
        ),
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      final catalogs = body['catalogs'] as List;
      final dso =
          catalogs.firstWhere((c) => (c as Map)['name'] == 'dso') as Map;
      expect(dso['status'], 'installed');
      expect(dso['sizeBytes'], csvBytes.length);
      expect(dso['expectedHash'], expectedSha);
    });

    // GET /api/catalog/available
    test('lists known catalogs and caches the response', () async {
      final response1 = await translateHandlerErrors(
        handlers.handleAvailable(
          Request('GET', Uri.parse('http://localhost/api/catalog/available')),
        ),
      );
      final body1 = jsonDecode(await response1.readAsString()) as Map;
      expect(body1['cache'], 'miss');
      final available = body1['available'] as List;
      expect(
        available.map((e) => (e as Map)['name']).toSet(),
        equals(CatalogManager.knownCatalogs.keys.toSet()),
      );

      final response2 = await translateHandlerErrors(
        handlers.handleAvailable(
          Request('GET', Uri.parse('http://localhost/api/catalog/available')),
        ),
      );
      final body2 = jsonDecode(await response2.readAsString()) as Map;
      expect(body2['cache'], 'hit');
    });

    // POST /api/catalog/download
    test('returns a jobId and starts a job', () async {
      final response = await translateHandlerErrors(
        handlers.handleDownload(
          Request(
            'POST',
            Uri.parse('http://localhost/api/catalog/download'),
            body: jsonEncode({'name': 'dso'}),
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['jobId'], isA<String>());
      expect(body['commandId'], body['jobId']);
      expect(body['operation'], 'catalog.download');
      expect(body['state'], 'queued');

      // Cancel so we don't actually hit the upstream during the test run.
      jobManager.cancel(body['jobId'] as String);
      await _pumpUntil(() {
        final j = jobManager.get(body['jobId'] as String);
        return j != null && j.state.isTerminal;
      });
    });

    test('rejects unknown catalog names', () async {
      final response = await translateHandlerErrors(
        handlers.handleDownload(
          Request(
            'POST',
            Uri.parse('http://localhost/api/catalog/download'),
            body: jsonEncode({'name': 'not-a-catalog'}),
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      expect(response.statusCode, 400);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['code'], 'invalid_request');
      expect(body['field'], 'name');
    });

    test(
      'install via installFromFile emits CatalogDownloadComplete event',
      () async {
        // This proves the event-emission path used by the download job
        // works end-to-end. We exercise it via the upload code path so
        // the test stays offline.
        final csv = _miniNgcCsvBody();
        final csvBytes = utf8.encode(csv);
        final expectedSha = sha256.convert(csvBytes).toString();
        final src = await Directory.systemTemp.createTemp('ns_src_');
        final srcFile = File('${src.path}/source.csv');
        await srcFile.writeAsString(csv);

        await CatalogManager.instance.installFromFile(
          name: 'dso',
          source: srcFile,
          expectedSha256: expectedSha,
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(
          emittedEvents.map((e) => e.eventType),
          contains('CatalogDownloadComplete'),
        );

        await src.delete(recursive: true);
      },
    );

    // POST /api/catalog/upload
    test('succeeds with matching sha256', () async {
      final csv = _miniNgcCsvBody();
      final csvBytes = utf8.encode(csv);
      final expectedSha = sha256.convert(csvBytes).toString();

      final response = await translateHandlerErrors(
        handlers.handleUpload(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/catalog/upload?name=dso&sha256=$expectedSha',
            ),
            body: csvBytes,
            headers: {'content-type': 'application/octet-stream'},
          ),
        ),
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      final installed = body['installed'] as Map;
      expect(installed['name'], 'dso');
      expect(installed['sha256'], expectedSha);
      expect(installed['sizeBytes'], csvBytes.length);
    });

    test('rejects mismatched sha256', () async {
      final csv = _miniNgcCsvBody();
      final csvBytes = utf8.encode(csv);
      final wrongSha = 'a' * 64;

      final response = await translateHandlerErrors(
        handlers.handleUpload(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/catalog/upload?name=dso&sha256=$wrongSha',
            ),
            body: csvBytes,
            headers: {'content-type': 'application/octet-stream'},
          ),
        ),
      );
      expect(response.statusCode, 400);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'sha256_mismatch');
      expect(body['expected'], wrongSha);
    });

    test('rejects malformed sha256 query param', () async {
      final response = await translateHandlerErrors(
        handlers.handleUpload(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/catalog/upload?name=dso&sha256=not-hex',
            ),
            body: [0x01, 0x02, 0x03],
            headers: {'content-type': 'application/octet-stream'},
          ),
        ),
      );
      expect(response.statusCode, 400);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'sha256');
    });

    test('rejects missing name', () async {
      final csv = _miniNgcCsvBody();
      final response = await translateHandlerErrors(
        handlers.handleUpload(
          Request(
            'POST',
            Uri.parse('http://localhost/api/catalog/upload'),
            body: utf8.encode(csv),
            headers: {'content-type': 'application/octet-stream'},
          ),
        ),
      );
      expect(response.statusCode, 400);
    });

    // POST /api/catalog/verify
    test(
      'returns per-catalog SHA-256 result for an installed catalog',
      () async {
        final csv = _miniNgcCsvBody();
        final csvBytes = utf8.encode(csv);
        final expectedSha = sha256.convert(csvBytes).toString();
        final src = await Directory.systemTemp.createTemp('ns_src_v_');
        final srcFile = File('${src.path}/source.csv');
        await srcFile.writeAsString(csv);
        await CatalogManager.instance.installFromFile(
          name: 'dso',
          source: srcFile,
          expectedSha256: expectedSha,
        );
        await src.delete(recursive: true);

        final response = await translateHandlerErrors(
          handlers.handleVerify(
            Request(
              'POST',
              Uri.parse('http://localhost/api/catalog/verify'),
              body: jsonEncode({'name': 'dso'}),
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString()) as Map;
        final verified = body['verified'] as Map;
        final dsoResult = verified['dso'] as Map;
        expect(dsoResult['ok'], isTrue);
        expect(dsoResult['expectedHash'], expectedSha);
        expect(dsoResult['actualHash'], expectedSha);
      },
    );

    test('with empty body verifies all catalogs', () async {
      final response = await translateHandlerErrors(
        handlers.handleVerify(
          Request('POST', Uri.parse('http://localhost/api/catalog/verify')),
        ),
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      final verified = body['verified'] as Map;
      expect(
        verified.keys.toSet(),
        equals(CatalogManager.knownCatalogs.keys.toSet()),
      );
      for (final v in verified.values) {
        final m = v as Map;
        expect(m['ok'], isFalse);
        expect((m['errors'] as List).contains('not_installed'), isTrue);
      }
    });

    // DELETE /api/catalog/{name}
    test('removes an installed catalog and returns 200', () async {
      final csv = _miniNgcCsvBody();
      final csvBytes = utf8.encode(csv);
      final expectedSha = sha256.convert(csvBytes).toString();
      final src = await Directory.systemTemp.createTemp('ns_src_d_');
      final srcFile = File('${src.path}/source.csv');
      await srcFile.writeAsString(csv);
      await CatalogManager.instance.installFromFile(
        name: 'dso',
        source: srcFile,
        expectedSha256: expectedSha,
      );
      await src.delete(recursive: true);

      final response = await translateHandlerErrors(
        handlers.handleDelete(
          Request('DELETE', Uri.parse('http://localhost/api/catalog/dso')),
          'dso',
        ),
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['status'], 'uninstalled');
      expect(body['name'], 'dso');
      expect(await File('${tempCatalogDir.path}/NGC.csv').exists(), isFalse);
    });

    test('returns 404 when catalog not installed', () async {
      final response = await translateHandlerErrors(
        handlers.handleDelete(
          Request('DELETE', Uri.parse('http://localhost/api/catalog/dso')),
          'dso',
        ),
      );
      expect(response.statusCode, 404);
    });

    test('rejects unknown name', () async {
      final response = await translateHandlerErrors(
        handlers.handleDelete(
          Request('DELETE', Uri.parse('http://localhost/api/catalog/bogus')),
          'bogus',
        ),
      );
      expect(response.statusCode, 400);
    });

    // POST /api/catalog/reload
    test('reload triggers CatalogManager.reload and emits event', () async {
      final response = await translateHandlerErrors(
        handlers.handleReload(
          Request('POST', Uri.parse('http://localhost/api/catalog/reload')),
        ),
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['status'], 'reloaded');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        emittedEvents.map((e) => e.eventType),
        contains('CatalogReloaded'),
      );
    });
  });
}
