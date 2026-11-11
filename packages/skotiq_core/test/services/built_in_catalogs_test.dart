// The deep-sky catalog that ships in the app: it is the pinned OpenNGC file,
// and a fresh install resolves deep-sky names with no network and nothing
// downloaded.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/src/services/built_in_catalogs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter test runs in the package root.
  final packageRoot = Directory.current.absolute.path;
  late Directory catalogDir;

  setUpAll(() {
    // Serve `packages/skotiq_core/...` asset keys from the source tree.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      const prefix = 'packages/skotiq_core/';
      if (!key.startsWith(prefix)) return null;
      final file = File(p.join(packageRoot, key.substring(prefix.length)));
      if (!await file.exists()) return null;
      return ByteData.sublistView(await file.readAsBytes());
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  setUp(() async {
    catalogDir = await Directory.systemTemp.createTemp('sk_built_in_');
  });

  tearDown(() async {
    if (await catalogDir.exists()) await catalogDir.delete(recursive: true);
  });

  test('the shipped OpenNGC file is the one the catalog download pins', () {
    final bytes = File(
      p.join(packageRoot, 'assets', 'catalogs', 'NGC.csv'),
    ).readAsBytesSync();
    expect(sha256.convert(bytes).toString(), SkyCatalog.dso.sha256);
  });

  test('a fresh install finds Messier, NGC and IC objects by name', () async {
    final manager = CatalogManager.instance;
    await manager.initialize(catalogDir.path, builtIn: builtInCatalogs);

    final status = await manager.status(SkyCatalog.dso);
    expect(status.isInstalled, isTrue);
    expect(status.version, SkyCatalog.dso.version);

    final m31 = (await manager.search('M31')).first;
    expect(m31.name, 'M31');
    expect(m31.ra, closeTo(10.68, 0.01));
    expect(m31.dec, closeTo(41.27, 0.01));
    expect((await manager.search('M34')).first.name, 'M34');
    expect((await manager.search('NGC 891')).first.catalogId, 'NGC891');
    expect((await manager.search('IC 434')).first.catalogId, 'IC434');
  });
}
