// The one catalog installer: install from a file, download, status, verify,
// uninstall. Network is a fake client; the directory is a temp directory.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

const _ngcCsv =
    'Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;'
    'SurfBr;Hubble;Pax;Pm-RA;Pm-Dec;RadVel;Redshift;Cstar U-Mag;Cstar B-Mag;'
    'Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;Common names;NED notes;'
    'OpenNGC notes;Sources\n'
    'NGC0001;G;00:07:15.84;+27:42:29.1;Peg;1.59;1.07;112;;13.4;;;;;Sb;;;;;;;;;;;;;;;;;\n';

const _gladeCsv =
    'RAJ2000,DEJ2000,Bmag,zhelio,PGC\n10.0,20.0,15.1,0.01,1\n'
    '10.1,20.1,16.2,0.02,2\n';

void main() {
  final manager = CatalogManager.instance;
  late Directory tempDir;
  late Directory srcDir;
  late http.Client Function() savedFactory;

  Future<File> source(String name, String content) async {
    final file = File('${srcDir.path}/$name');
    await file.writeAsString(content);
    return file;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_catalog_installer_');
    srcDir = await Directory.systemTemp.createTemp('sk_catalog_src_');
    await manager.initialize(tempDir.path);
    savedFactory = CatalogInstaller.httpClientFactory;
  });

  tearDown(() async {
    CatalogInstaller.httpClientFactory = savedFactory;
    for (final dir in [tempDir, srcDir]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  group('install from a file', () {
    test('install, status, verify, uninstall round trip', () async {
      final expectedSha = sha256.convert(utf8.encode(_ngcCsv)).toString();
      final install = await manager.installFromFile(
        SkyCatalog.dso,
        await source('ngc.csv', _ngcCsv),
        expectedSha256: expectedSha,
      );
      expect(install.sha256, expectedSha);
      expect(install.sizeBytes, utf8.encode(_ngcCsv).length);
      expect(install.objectCount, 1);

      var status = await manager.status(SkyCatalog.dso);
      expect(status.state, CatalogInstallStatus.installed);
      expect(status.isInstalled, isTrue);
      expect(status.sizeBytes, install.sizeBytes);
      expect(status.objectCount, 1);
      expect(status.expectedHash, expectedSha);
      expect(
        await File('${manager.pathOf(SkyCatalog.dso)}.partial').exists(),
        isFalse,
      );

      final verified = await manager.verify(only: SkyCatalog.dso);
      expect(verified[SkyCatalog.dso]!.ok, isTrue);
      expect(verified[SkyCatalog.dso]!.actualHash, expectedSha);
      expect((await manager.status(SkyCatalog.dso)).lastVerified, isNotNull);

      expect(await manager.uninstall(SkyCatalog.dso), isTrue);
      status = await manager.status(SkyCatalog.dso);
      expect(status.state, CatalogInstallStatus.missing);
      expect(await manager.uninstall(SkyCatalog.dso), isFalse);

      final after = await manager.verify(only: SkyCatalog.dso);
      expect(after[SkyCatalog.dso]!.errors, contains('not_installed'));
    });

    test('a file that does not hash to the expected value is refused, and '
        'the installed catalog stays', () async {
      await manager.installFromFile(
        SkyCatalog.dso,
        await source('good.csv', _ngcCsv),
      );
      await expectLater(
        manager.installFromFile(
          SkyCatalog.dso,
          await source('other.csv', '$_ngcCsv\n'),
          expectedSha256: 'a' * 64,
        ),
        throwsA(isA<CatalogHashMismatchException>()),
      );
      final status = await manager.status(SkyCatalog.dso);
      expect(status.sizeBytes, utf8.encode(_ngcCsv).length);
    });

    test('an empty file is refused and does not clobber the installed '
        'catalog', () async {
      await manager.installFromFile(
        SkyCatalog.stars,
        await source('good.csv', 'id,hip\n1,11767\n'),
      );
      final goodSize = (await manager.status(SkyCatalog.stars)).sizeBytes;

      await expectLater(
        manager.installFromFile(
          SkyCatalog.stars,
          await source('empty.csv', ''),
        ),
        throwsA(isA<CatalogDownloadException>()),
      );
      final status = await manager.status(SkyCatalog.stars);
      expect(status.isInstalled, isTrue);
      expect(status.sizeBytes, goodSize);
      expect(
        await File('${manager.pathOf(SkyCatalog.stars)}.partial').exists(),
        isFalse,
      );
    });

    test('the annotation tier is recorded and read back', () async {
      await manager.installFromFile(
        SkyCatalog.annotation,
        await source('glade.csv', _gladeCsv),
        tier: AnnotationPackage.essential,
      );
      final status = await manager.status(SkyCatalog.annotation);
      expect(status.annotationPackage, AnnotationPackage.essential);
      expect(status.objectCount, 2);
    });
  });

  group('what is already on disk', () {
    test('a zero-byte catalog file is not an install', () async {
      await File(manager.pathOf(SkyCatalog.stars)).writeAsBytes(const []);
      final status = await manager.status(SkyCatalog.stars);
      expect(status.isInstalled, isFalse);
      expect(status.state, CatalogInstallStatus.corrupted);
    });

    test('metadata written by earlier builds still reads', () async {
      // The two shapes the retired installers wrote.
      await File('${tempDir.path}/hyg_v44.csv').writeAsString('id\n1\n');
      await File('${tempDir.path}/stars_metadata.json').writeAsString(
        '{"source":"HYG Star Database","version":"4.4","package":"complete",'
        '"objectCount":119614,"installedDate":"2026-09-09T20:28:02.786963",'
        '"sha256":"ea0e"}',
      );
      await File(
        '${tempDir.path}/glade_plus_galaxies.csv',
      ).writeAsString(_gladeCsv);
      await File('${tempDir.path}/annotation_metadata.json').writeAsString(
        '{"source":"GLADE+ Galaxy Catalog","version":"2022",'
        '"package":"complete","magnitudeLimit":99.0,"objectCount":23181758,'
        '"installedDate":"2026-09-09T20:36:36.714557"}',
      );

      final stars = await manager.status(SkyCatalog.stars);
      expect(stars.state, CatalogInstallStatus.installed);
      expect(stars.objectCount, 119614);
      expect(stars.version, '4.4');
      expect(stars.installedAt, DateTime(2026, 9, 9, 20, 28, 2, 786, 963));
      expect(stars.expectedHash, 'ea0e');

      final annotation = await manager.status(SkyCatalog.annotation);
      expect(annotation.annotationPackage, AnnotationPackage.complete);
      expect(annotation.objectCount, 23181758);
    });

    test('unreadable metadata leaves the catalog usable', () async {
      await File(manager.pathOf(SkyCatalog.dso)).writeAsString(_ngcCsv);
      await File('${tempDir.path}/dso_metadata.json').writeAsString('{nope');
      final status = await manager.status(SkyCatalog.dso);
      expect(status.state, CatalogInstallStatus.partial);
      expect(status.isInstalled, isTrue);
    });

    test('uninstall removes data and metadata, and nothing else', () async {
      final files = [
        File('${tempDir.path}/hyg_v44.csv'),
        File('${tempDir.path}/hyg_v42.csv'),
        File('${tempDir.path}/stars_metadata.json'),
      ];
      final kept = File('${tempDir.path}/NGC.csv');
      for (final file in [...files, kept]) {
        await file.writeAsString('installed');
      }
      expect(await manager.uninstall(SkyCatalog.stars), isTrue);
      for (final file in files) {
        expect(await file.exists(), isFalse, reason: file.path);
      }
      expect(await kept.exists(), isTrue);
    });
  });

  group('download', () {
    test('a download installs, reports progress and events, and leaves '
        'nothing in flight', () async {
      final payload = utf8.encode(_gladeCsv);
      CatalogInstaller.httpClientFactory = () => _FakeClient((_) => payload);

      final progress = <DownloadProgress>[];
      final events = <String>[];
      final sub = manager.events.listen((e) => events.add(e.eventType));
      addTearDown(sub.cancel);

      final result = await manager.install(
        SkyCatalog.annotation,
        tier: AnnotationPackage.essential,
        jobId: 'job-1',
        onProgress: progress.add,
      );
      await Future<void>.delayed(Duration.zero);

      expect(result.objectCount, 2);
      expect(result.sha256, sha256.convert(payload).toString());
      expect(progress.first.isTerminal, isFalse);
      expect(progress.last.isComplete, isTrue);
      expect(
        events,
        containsAllInOrder([
          'CatalogDownloadStarted',
          'CatalogDownloadComplete',
        ]),
      );
      expect(manager.activeDownloads, isEmpty);

      final status = await manager.status(SkyCatalog.annotation);
      expect(status.isInstalled, isTrue);
      expect(status.annotationPackage, AnnotationPackage.essential);
      expect(status.expectedHash, result.sha256);
      expect(
        tempDir.listSync().where((f) => f.path.endsWith('.partial')),
        isEmpty,
      );
    });

    test('every candidate is tried, and a failure leaves the installed '
        'catalog alone', () async {
      await manager.installFromFile(
        SkyCatalog.dso,
        await source('good.csv', _ngcCsv),
      );
      final urls = <String>[];
      CatalogInstaller.httpClientFactory = () => _FakeClient((url) {
        urls.add(url);
        return null; // 404
      });

      final progress = <DownloadProgress>[];
      await expectLater(
        manager.install(SkyCatalog.dso, onProgress: progress.add),
        throwsA(
          isA<CatalogDownloadException>().having(
            (e) => e.phase,
            'phase',
            'http_send',
          ),
        ),
      );
      expect(urls, [
        '$kCatalogReleaseBaseUrl/NGC.csv',
        SkyCatalog.dso.upstreamUrl,
      ]);
      expect(progress.last.error, contains('HTTP 404'));
      expect(manager.activeDownloads, isEmpty);
      final status = await manager.status(SkyCatalog.dso);
      expect(status.sizeBytes, utf8.encode(_ngcCsv).length);
    });

    test('a mirror set for self-hosting is asked first, and clearing it '
        'goes back to the release', () async {
      final urls = <String>[];
      CatalogInstaller.httpClientFactory = () => _FakeClient((url) {
        urls.add(url);
        return null;
      });
      addTearDown(() => manager.setCatalogBaseUrl(''));

      manager.setCatalogBaseUrl(' https://mirror.example.org/catalogs/ ');
      expect(manager.catalogBaseUrl, 'https://mirror.example.org/catalogs/');
      await expectLater(
        manager.install(SkyCatalog.dso),
        throwsA(isA<CatalogDownloadException>()),
      );
      expect(urls, [
        'https://mirror.example.org/catalogs/NGC.csv',
        SkyCatalog.dso.upstreamUrl,
      ]);

      manager.setCatalogBaseUrl('');
      expect(manager.catalogBaseUrl, kCatalogReleaseBaseUrl);
    });

    test('a mirror address that is not http or https is refused', () {
      expect(
        () => manager.setCatalogBaseUrl('ftp://mirror.example.org/c'),
        throwsArgumentError,
      );
      expect(manager.catalogBaseUrl, kCatalogReleaseBaseUrl);
      expect(catalogBaseUrlProblem('https://mirror.example.org/c'), isNull);
      expect(catalogBaseUrlProblem('http://10.0.0.5:8080/c'), isNull);
      expect(catalogBaseUrlProblem('mirror.example.org/c'), isNotNull);
      expect(catalogBaseUrlProblem('https:///c'), isNotNull);
      expect(catalogBaseUrlProblem('https://example.org/c?x=1'), isNotNull);
    });

    test('servers that cannot be reached fail with a plain message', () async {
      CatalogInstaller.httpClientFactory = () => _FakeClient(
        (url) =>
            throw http.ClientException('Connection failed', Uri.parse(url)),
      );
      await expectLater(
        manager.install(SkyCatalog.stars),
        throwsA(
          isA<CatalogDownloadException>().having(
            (e) => e.message,
            'message',
            'Could not reach github.com or codeberg.org. '
                'Check the internet connection and try again.',
          ),
        ),
      );
    });

    test(
      'bytes that do not match the published checksum are refused',
      () async {
        CatalogInstaller.httpClientFactory = () =>
            _FakeClient((_) => utf8.encode(_ngcCsv));
        await expectLater(
          manager.install(SkyCatalog.dso),
          throwsA(isA<CatalogHashMismatchException>()),
        );
        expect((await manager.status(SkyCatalog.dso)).isInstalled, isFalse);
      },
    );

    test(
      'a second install of a catalog already downloading is refused',
      () async {
        final gate = Completer<void>();
        CatalogInstaller.httpClientFactory = () =>
            _FakeClient((_) => utf8.encode(_gladeCsv), gate: gate.future);
        final first = manager.install(SkyCatalog.annotation);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(manager.activeDownloads.keys, [SkyCatalog.annotation]);
        await expectLater(
          manager.install(SkyCatalog.annotation),
          throwsA(isA<CatalogDownloadException>()),
        );
        gate.complete();
        await first;
      },
    );
  });
}

/// Serves `respond(url)` as a 200 body, or a 404 when it returns null.
class _FakeClient extends http.BaseClient {
  _FakeClient(this.respond, {this.gate});

  final List<int>? Function(String url) respond;
  final Future<void>? gate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = respond(request.url.toString());
    if (body == null) {
      return http.StreamedResponse(const Stream.empty(), 404, request: request);
    }
    Stream<List<int>> stream() async* {
      if (gate != null) await gate;
      yield body;
    }

    return http.StreamedResponse(
      stream(),
      200,
      contentLength: body.length,
      request: request,
    );
  }
}
