// Name search over the installed star catalog: which names find a star and
// what the result is called.

import 'dart:io';

import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

const _header =
    'id,hip,hd,hr,gl,bf,proper,ra,dec,dist,pmra,pmdec,rv,mag,absmag,spect,ci,'
    'x,y,z,vx,vy,vz,rarad,decrad,pmrarad,pmdecrad,bayer,flam,con,comp,'
    'comp_primary,base,lum,var,var_min,var_max';

const _openNgcHeader =
    'Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;'
    'SurfBr;Hubble;Pax;Pm-RA;Pm-Dec;RadVel;Redshift;Cstar U-Mag;Cstar B-Mag;'
    'Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;Common names;NED notes;'
    'OpenNGC notes;Sources';

String _dso(String id, String messier, {String common = ''}) =>
    '$id;G;00:42:44.35;+41:16:08.6;And;10.00;5.00;;4.00;4.00;;;;;;;;;;;;;;'
    '$messier;;;;;$common;;;test';

String _row({
  required int id,
  required int hip,
  String proper = '',
  String bayer = '',
  String con = '',
  double mag = 4.0,
}) =>
    '$id,$hip,,,,,$proper,0.5,41.0,10,0,0,0,$mag,0,A0V,0.0,0,0,0,0,0,0,0,0,0,0,'
    '$bayer,,$con,1,$id,,,,,';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sk_name_search_');
    await File('${dir.path}/hyg_v44.csv').writeAsString(
      [
        _header,
        _row(id: 1, hip: 91262, proper: 'Vega', con: 'Lyr', mag: 0.03),
        _row(id: 2, hip: 3881, bayer: 'Nu', con: 'And'),
        _row(id: 3, hip: 3293, mag: 7.0),
      ].join('\n'),
    );
    await File('${dir.path}/NGC.csv').writeAsString(
      [
        _openNgcHeader,
        _dso('NGC5272', '003'),
        _dso('NGC0224', '031'),
        _dso('NGC0700', ''),
        _dso('NGC7000', '', common: 'North America Nebula'),
      ].join('\n'),
    );
    await CatalogManager.instance.initialize(dir.path);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('a proper name and a catalog number find the star', () async {
    expect((await CatalogManager.instance.search('vega')).single.name, 'Vega');
    expect(
      (await CatalogManager.instance.search('HIP 91262')).single.name,
      'Vega',
    );
  });

  test('a constellation name does not list the stars named after it', () async {
    expect(await CatalogManager.instance.search('andromeda'), isEmpty);
  });

  test('a star without a proper name is called by its designation', () async {
    final bayer = await CatalogManager.instance.search('HIP 3881');
    expect(bayer.single.name, 'Nu Andromedae');
    final bare = await CatalogManager.instance.search('HIP 3293');
    expect(bare.single.name, 'HIP 3293');
  });

  test('a designation does not find the objects whose number it extends',
      () async {
    Future<List<String>> ids(String query) async => [
          for (final r in await CatalogManager.instance.search(query))
            r.catalogId,
        ];
    expect(await ids('M31'), ['NGC224']);
    expect(await ids('M 3'), contains('NGC5272'));
    expect(await ids('NGC 7000'), ['NGC7000']);
    expect(await ids('NGC 7000 nebula'), ['NGC7000']);
  });
}
