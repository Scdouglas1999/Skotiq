import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';

void main() {
  group('HYG CSV line parsing', () {
    test('parses valid HYG star line with proper name', () {
      // Simulated HYG v3.8 CSV line for a star with proper name
      // Columns: id,hip,hd,hr,gl,bf,proper,ra,dec,dist,...,mag,absmag,spect,ci,...,bayer,flam,con,...
      final line = _buildHygLine(
        id: '1',
        hip: '11767',
        hd: '8890',
        hr: '424',
        proper: 'Polaris',
        raHours: '2.53',
        dec: '89.264',
        mag: '1.98',
        spect: 'F7Ib',
        ci: '0.636',
        bayer: 'Alp',
        flam: '1',
        con: 'UMi',
      );

      final star = _parseHygLinePublic(line);
      expect(star, isNotNull);
      expect(star!.name, 'Polaris');
      expect(star.id, 'HIP11767');
      expect(star.magnitude, closeTo(1.98, 0.001));
      expect(star.spectralType, 'F7Ib');
      expect(star.constellation, 'UMi');
      expect(star.catalogIds, contains('HIP 11767'));
      expect(star.catalogIds, contains('HD 8890'));
      expect(star.catalogIds, contains('HR 424'));
    });

    test('parses star with Bayer designation when no proper name', () {
      final line = _buildHygLine(
        id: '100',
        hip: '50000',
        hd: '40000',
        hr: '',
        proper: '',
        raHours: '10.0',
        dec: '45.0',
        mag: '3.5',
        spect: 'A0V',
        ci: '0.0',
        bayer: 'Bet',
        flam: '',
        con: 'UMA',
      );

      final star = _parseHygLinePublic(line);
      expect(star, isNotNull);
      // Should use Bayer designation + constellation genitive
      expect(star!.name, contains('Bet'));
      expect(star.name, contains('Ursae Majoris'));
    });

    test('parses star with Flamsteed number when no proper name or Bayer', () {
      final line = _buildHygLine(
        id: '200',
        hip: '60000',
        hd: '55000',
        hr: '',
        proper: '',
        raHours: '12.0',
        dec: '30.0',
        mag: '5.2',
        spect: 'G2V',
        ci: '0.65',
        bayer: '',
        flam: '42',
        con: 'GEM',
      );

      final star = _parseHygLinePublic(line);
      expect(star, isNotNull);
      // Should use Flamsteed number + constellation name
      expect(star!.name, contains('42'));
      expect(star.name, contains('Gemini'));
    });

    test('uses HIP ID when available', () {
      final line = _buildHygLine(
        id: '5',
        hip: '12345',
        hd: '99999',
        hr: '',
        proper: 'TestStar',
        raHours: '5.0',
        dec: '20.0',
        mag: '4.0',
        spect: 'K0III',
        ci: '1.0',
        bayer: '',
        flam: '',
        con: 'ORI',
      );

      final star = _parseHygLinePublic(line);
      expect(star, isNotNull);
      expect(star!.id, 'HIP12345');
    });

    test('falls back to HD ID when no HIP', () {
      final line = _buildHygLine(
        id: '300',
        hip: '',
        hd: '77777',
        hr: '',
        proper: 'FaintStar',
        raHours: '8.0',
        dec: '-10.0',
        mag: '8.0',
        spect: 'M0V',
        ci: '1.5',
        bayer: '',
        flam: '',
        con: 'HYA',
      );

      final star = _parseHygLinePublic(line);
      expect(star, isNotNull);
      expect(star!.id, 'HD77777');
    });

    test('falls back to HYG ID when no HIP or HD', () {
      final line = _buildHygLine(
        id: '999',
        hip: '',
        hd: '',
        hr: '',
        proper: '',
        raHours: '15.0',
        dec: '-5.0',
        mag: '12.0',
        spect: '',
        ci: '',
        bayer: '',
        flam: '',
        con: '',
      );

      final star = _parseHygLinePublic(line);
      expect(star, isNotNull);
      expect(star!.id, 'HYG999');
      // Name should also fall back to the ID
      expect(star.name, 'HYG999');
    });

    test('returns null for line with too few columns', () {
      final star = _parseHygLinePublic('1,2,3,4,5');
      expect(star, isNull);
    });

    test('an unreadable ra/dec column rejects the row', () {
      final line = _buildHygLine(
        id: '50',
        hip: 'not_a_number',
        hd: '',
        hr: '',
        proper: 'BadData',
        raHours: 'abc',
        dec: 'xyz',
        mag: 'nope',
        spect: 'K0',
        ci: '',
        bayer: '',
        flam: '',
        con: '',
      );

      // A row with no readable position is skipped by the loader, never placed
      // at RA 0h / Dec 0. End-to-end coverage of the real parser lives in
      // hyg_unparseable_position_test.dart; this replica mirrors the contract.
      expect(() => _parseHygLinePublic(line), throwsFormatException);
    });

    test('a soft numeric field still degrades to null', () {
      final line = _buildHygLine(
        id: '50',
        hip: 'not_a_number',
        hd: '',
        hr: '',
        proper: 'BadData',
        raHours: '3.5',
        dec: '20.0',
        mag: 'nope',
        spect: 'K0',
        ci: '',
        bayer: '',
        flam: '',
        con: '',
      );

      // Magnitude and the cross-catalogue ids are optional: a star with an
      // unreadable magnitude is still a star at a known place.
      final star = _parseHygLinePublic(line);
      expect(star, isNotNull);
      expect(star!.magnitude, isNull);
      expect(star.id, 'HYG50');
    });

    test('CSV parsing handles quoted fields with commas', () {
      final parts = _parseCsvLinePublic('one,"two,three",four');
      expect(parts, ['one', 'two,three', 'four']);
    });

    test('CSV parsing handles empty fields', () {
      final parts = _parseCsvLinePublic('a,,c,,e');
      expect(parts, ['a', '', 'c', '', 'e']);
    });
  });

  group('OpenNGC DSO line parsing', () {
    test('parses valid galaxy entry', () {
      // Semicolon-separated OpenNGC format
      final line = _buildNgcLine(
        name: 'NGC0224',
        type: 'G',
        ra: '00:42:44.33',
        dec: '+41:16:07.5',
        constellation: 'And',
        majorAxis: '189.1',
        minorAxis: '61.7',
        posAngle: '35',
        bMag: '4.36',
        vMag: '3.44',
        messier: '31',
        commonName: 'Andromeda Galaxy',
      );

      final dso = _parseOpenNgcLinePublic(line);
      expect(dso, isNotNull);
      expect(dso!.id, 'NGC224'); // Leading zeros removed
      expect(dso.name, 'M31'); // Messier takes priority as display name
      expect(dso.type, DsoType.galaxy);
      expect(dso.magnitude, closeTo(3.44, 0.01));
      expect(dso.sizeArcMin, closeTo(189.1, 0.1));
      expect(dso.minorAxisArcMin, closeTo(61.7, 0.1));
      expect(dso.positionAngle, closeTo(35, 0.1));
      expect(dso.catalogIds, contains('M31'));
    });

    test('parses planetary nebula', () {
      final line = _buildNgcLine(
        name: 'NGC6720',
        type: 'PN',
        ra: '18:53:35.08',
        dec: '+33:01:45.0',
        constellation: 'Lyr',
        majorAxis: '1.4',
        minorAxis: '1.0',
        posAngle: '',
        bMag: '',
        vMag: '8.8',
        messier: '57',
        commonName: 'Ring Nebula',
      );

      final dso = _parseOpenNgcLinePublic(line);
      expect(dso, isNotNull);
      expect(dso!.type, DsoType.planetaryNebula);
      expect(dso.name, 'M57');
    });

    test('skips NonEx type entries', () {
      final line = _buildNgcLine(
        name: 'NGC9999',
        type: 'NonEx',
        ra: '12:00:00.0',
        dec: '+00:00:00.0',
        constellation: 'Vir',
      );

      final dso = _parseOpenNgcLinePublic(line);
      expect(dso, isNull);
    });

    test('skips Dup type entries', () {
      final line = _buildNgcLine(
        name: 'NGC1234',
        type: 'Dup',
        ra: '03:00:00.0',
        dec: '-10:00:00.0',
        constellation: 'Eri',
      );

      final dso = _parseOpenNgcLinePublic(line);
      expect(dso, isNull);
    });

    test('handles missing magnitude fields', () {
      final line = _buildNgcLine(
        name: 'IC0410',
        type: 'HII',
        ra: '05:22:06.00',
        dec: '+33:24:00.0',
        constellation: 'Aur',
        majorAxis: '40.0',
        bMag: '',
        vMag: '',
        commonName: 'Tadpoles Nebula',
      );

      final dso = _parseOpenNgcLinePublic(line);
      expect(dso, isNotNull);
      expect(dso!.magnitude, isNull);
      expect(dso.type, DsoType.hiiRegion);
      expect(dso.id, 'IC410'); // Leading zeros removed
    });

    test('normalizes NGC name by removing leading zeros', () {
      expect(_normalizeCatalogNamePublic('NGC0628'), 'NGC628');
      expect(_normalizeCatalogNamePublic('NGC0001'), 'NGC1');
      expect(_normalizeCatalogNamePublic('IC0434'), 'IC434');
      expect(_normalizeCatalogNamePublic('NGC7000'), 'NGC7000');
    });

    test('parses RA from HH:MM:SS.ss format correctly', () {
      // 06:45:08.92 = 6 + 45/60 + 8.92/3600 = 6.7524778 hours
      final ra = _parseRaPublic('06:45:08.92');
      expect(ra, isNotNull);
      expect(ra!, closeTo(6.7524778, 0.0001));
    });

    test('parses negative Dec correctly', () {
      // -16:42:58.0 = -(16 + 42/60 + 58/3600) = -16.7161
      final dec = _parseDecPublic('-16:42:58.0');
      expect(dec, isNotNull);
      expect(dec!, closeTo(-16.7161, 0.001));
    });

    test('parses positive Dec correctly', () {
      // +41:16:07.5 = 41 + 16/60 + 7.5/3600 = 41.2687
      final dec = _parseDecPublic('+41:16:07.5');
      expect(dec, isNotNull);
      expect(dec!, closeTo(41.2687, 0.001));
    });

    test('returns null for empty RA string', () {
      expect(_parseRaPublic(''), isNull);
    });

    test('returns null for malformed RA string', () {
      expect(_parseRaPublic('not:a:time'), isNull);
    });

    test('returns null for RA with wrong number of parts', () {
      expect(_parseRaPublic('12:30'), isNull);
    });

    test('rejects invalid Messier numbers above 110', () {
      final line = _buildNgcLine(
        name: 'NGC5555',
        type: 'G',
        ra: '14:00:00.0',
        dec: '+30:00:00.0',
        constellation: 'Boo',
        messier: '999', // Invalid
      );

      final dso = _parseOpenNgcLinePublic(line);
      expect(dso, isNotNull);
      // Should not have M999 in catalog IDs
      expect(dso!.catalogIds.any((c) => c.startsWith('M')), isFalse);
      // Display name should be the NGC name, not M999
      expect(dso.name, 'NGC5555');
    });

    test('DSO type codes map correctly', () {
      expect(_parseDsoTypePublic('OCl'), DsoType.openCluster);
      expect(_parseDsoTypePublic('GCl'), DsoType.globularCluster);
      expect(_parseDsoTypePublic('G'), DsoType.galaxy);
      expect(_parseDsoTypePublic('PN'), DsoType.planetaryNebula);
      expect(_parseDsoTypePublic('HII'), DsoType.hiiRegion);
      expect(_parseDsoTypePublic('DrkN'), DsoType.darkNebula);
      expect(_parseDsoTypePublic('EmN'), DsoType.emissionNebula);
      expect(_parseDsoTypePublic('RfN'), DsoType.reflectionNebula);
      expect(_parseDsoTypePublic('SNR'), DsoType.supernova);
      expect(_parseDsoTypePublic('Cl+N'), DsoType.clusterWithNebulosity);
      expect(_parseDsoTypePublic('*'), DsoType.star);
      expect(_parseDsoTypePublic('**'), DsoType.doubleStar);
      expect(_parseDsoTypePublic('GPair'), DsoType.galaxyPair);
      expect(_parseDsoTypePublic('GTrpl'), DsoType.galaxyTriplet);
      expect(_parseDsoTypePublic('GGroup'), DsoType.galaxyGroup);
      expect(_parseDsoTypePublic('UnknownType'), DsoType.other);
    });

    test('line with too few columns returns null', () {
      final dso = _parseOpenNgcLinePublic('NGC1;G;00:01:00.0');
      expect(dso, isNull);
    });
  });

  group('Star model', () {
    test('getStarColor returns blue for negative color index', () {
      const star = Star(
        id: 'test',
        name: 'Blue Star',
        coordinates: CelestialCoordinate(ra: 0, dec: 0),
        colorIndex: -0.5,
      );
      expect(star.getStarColor(), 0xFFAABBFF);
    });

    test('getStarColor returns white for near-zero color index', () {
      const star = Star(
        id: 'test',
        name: 'White Star',
        coordinates: CelestialCoordinate(ra: 0, dec: 0),
        colorIndex: 0.15,
      );
      expect(star.getStarColor(), 0xFFFFFFFF);
    });

    test('getStarColor returns red-orange for high color index', () {
      const star = Star(
        id: 'test',
        name: 'Red Star',
        coordinates: CelestialCoordinate(ra: 0, dec: 0),
        colorIndex: 1.8,
      );
      expect(star.getStarColor(), 0xFFFF6030);
    });

    test('getStarColor returns white for null color index', () {
      const star = Star(
        id: 'test',
        name: 'Unknown Star',
        coordinates: CelestialCoordinate(ra: 0, dec: 0),
        colorIndex: null,
      );
      expect(star.getStarColor(), 0xFFFFFFFF);
    });
  });

  group('DeepSkyObject model', () {
    test('sizeString formats major axis only', () {
      const dso = DeepSkyObject(
        id: 'NGC1',
        name: 'Test',
        coordinates: CelestialCoordinate(ra: 0, dec: 0),
        type: DsoType.galaxy,
        sizeArcMin: 10.5,
      );
      expect(dso.sizeString, "10.5'");
    });

    test('sizeString formats major x minor axes', () {
      const dso = DeepSkyObject(
        id: 'NGC2',
        name: 'Test',
        coordinates: CelestialCoordinate(ra: 0, dec: 0),
        type: DsoType.galaxy,
        sizeArcMin: 10.5,
        minorAxisArcMin: 5.2,
      );
      expect(dso.sizeString, "10.5' × 5.2'");
    });

    test('isMessier detects Messier objects in catalogIds', () {
      const dso = DeepSkyObject(
        id: 'NGC224',
        name: 'Andromeda Galaxy',
        coordinates: CelestialCoordinate(ra: 0.712, dec: 41.268),
        type: DsoType.galaxy,
        catalogIds: ['M31'],
      );
      expect(dso.isMessier, isTrue);
      expect(dso.messierNumber, 'M31');
    });

    test('isMessier returns false for non-Messier objects', () {
      const dso = DeepSkyObject(
        id: 'NGC7000',
        name: 'North America Nebula',
        coordinates: CelestialCoordinate(ra: 20.979, dec: 44.526),
        type: DsoType.emissionNebula,
      );
      expect(dso.isMessier, isFalse);
      expect(dso.messierNumber, isNull);
    });
  });

  group('DsoType extensions', () {
    test('isCluster identifies cluster types', () {
      expect(DsoType.openCluster.isCluster, isTrue);
      expect(DsoType.globularCluster.isCluster, isTrue);
      expect(DsoType.clusterWithNebulosity.isCluster, isTrue);
      expect(DsoType.galaxy.isCluster, isFalse);
    });

    test('isGalaxy identifies galaxy types', () {
      expect(DsoType.galaxy.isGalaxy, isTrue);
      expect(DsoType.galaxyPair.isGalaxy, isTrue);
      expect(DsoType.galaxyTriplet.isGalaxy, isTrue);
      expect(DsoType.galaxyGroup.isGalaxy, isTrue);
      expect(DsoType.nebula.isGalaxy, isFalse);
    });

    test('isNebula identifies nebula types', () {
      expect(DsoType.nebula.isNebula, isTrue);
      expect(DsoType.emissionNebula.isNebula, isTrue);
      expect(DsoType.reflectionNebula.isNebula, isTrue);
      expect(DsoType.planetaryNebula.isNebula, isTrue);
      expect(DsoType.darkNebula.isNebula, isTrue);
      expect(DsoType.hiiRegion.isNebula, isTrue);
      expect(DsoType.supernova.isNebula, isTrue);
      expect(DsoType.galaxy.isNebula, isFalse);
    });
  });
}

// Helper functions that replicate private parsing logic for testing

/// Builds a minimal HYG v3.8 CSV line with 30 columns
String _buildHygLine({
  required String id,
  String hip = '',
  String hd = '',
  String hr = '',
  String gl = '',
  String bf = '',
  String proper = '',
  String raHours = '0',
  String dec = '0',
  String dist = '10',
  String pmra = '0',
  String pmdec = '0',
  String rv = '0',
  String mag = '',
  String absmag = '',
  String spect = '',
  String ci = '',
  String x = '0',
  String y = '0',
  String z = '0',
  String vx = '0',
  String vy = '0',
  String vz = '0',
  String rarad = '0',
  String decrad = '0',
  String pmrarad = '0',
  String pmdecrad = '0',
  String bayer = '',
  String flam = '',
  String con = '',
}) {
  return [
    id,
    hip,
    hd,
    hr,
    gl,
    bf,
    proper,
    raHours,
    dec,
    dist,
    pmra,
    pmdec,
    rv,
    mag,
    absmag,
    spect,
    ci,
    x,
    y,
    z,
    vx,
    vy,
    vz,
    rarad,
    decrad,
    pmrarad,
    pmdecrad,
    bayer,
    flam,
    con,
  ].join(',');
}

/// Replicates HygStarCatalog._parseHygLine
Star? _parseHygLinePublic(String line) {
  final parts = _parseCsvLinePublic(line);
  if (parts.length < 30) return null;

  final hygId = int.tryParse(parts[0]) ?? 0;
  final hipId = int.tryParse(parts[1]);
  final hdId = int.tryParse(parts[2]);
  final hrId = int.tryParse(parts[3]);
  final properName = parts.length > 6 ? parts[6] : '';
  final raHours = _requireSkyAnglePublic(parts[7], 'ra');
  final dec = _requireSkyAnglePublic(parts[8], 'dec');
  final magnitude = double.tryParse(parts[13]);
  final spectralType = parts.length > 15 ? parts[15] : null;
  final colorIndex = parts.length > 16 ? double.tryParse(parts[16]) : null;
  final bayerDesignation = parts.length > 27 ? parts[27] : null;
  final flamsteedNumber = parts.length > 28 ? parts[28] : null;
  final constellation = parts.length > 29 ? parts[29] : null;

  String id;
  if (hipId != null && hipId > 0) {
    id = 'HIP$hipId';
  } else if (hdId != null && hdId > 0) {
    id = 'HD$hdId';
  } else {
    id = 'HYG$hygId';
  }

  String starName = properName;
  if (starName.isEmpty &&
      bayerDesignation != null &&
      bayerDesignation.isNotEmpty) {
    starName =
        '$bayerDesignation ${_getConstellationGenitive(constellation ?? '')}';
  }
  if (starName.isEmpty &&
      flamsteedNumber != null &&
      flamsteedNumber.isNotEmpty) {
    starName = '$flamsteedNumber ${_getConstellationName(constellation ?? '')}';
  }
  if (starName.isEmpty) {
    starName = id;
  }

  final catalogIds = <String>[];
  if (hipId != null && hipId > 0) catalogIds.add('HIP $hipId');
  if (hdId != null && hdId > 0) catalogIds.add('HD $hdId');
  if (hrId != null && hrId > 0) catalogIds.add('HR $hrId');

  return Star(
    id: id,
    name: starName.trim(),
    coordinates: CelestialCoordinate(ra: raHours, dec: dec),
    magnitude: magnitude,
    spectralType: spectralType?.isNotEmpty == true ? spectralType : null,
    colorIndex: colorIndex,
    constellation: constellation?.isNotEmpty == true ? constellation : null,
    catalogIds: catalogIds,
  );
}

/// Replicates HygStarCatalog._requireSkyAngle
double _requireSkyAnglePublic(String raw, String column) {
  final value = double.tryParse(raw);
  if (value == null || !value.isFinite) {
    throw FormatException('HYG $column column is not a finite number', raw);
  }
  return value;
}

/// Replicates HygStarCatalog._parseCsvLine
List<String> _parseCsvLinePublic(String line) {
  final parts = <String>[];
  var current = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (char == '"') {
      inQuotes = !inQuotes;
    } else if (char == ',' && !inQuotes) {
      parts.add(current.toString().trim());
      current = StringBuffer();
    } else {
      current.write(char);
    }
  }
  parts.add(current.toString().trim());
  return parts;
}

/// Builds a minimal OpenNGC semicolon-separated line
/// The format requires at least 29 columns for full parsing.
String _buildNgcLine({
  required String name,
  required String type,
  required String ra,
  required String dec,
  required String constellation,
  String majorAxis = '',
  String minorAxis = '',
  String posAngle = '',
  String bMag = '',
  String vMag = '',
  String jMag = '',
  String hMag = '',
  String kMag = '',
  String surfBr = '',
  String hubble = '',
  String cstarUMag = '',
  String cstarBMag = '',
  String cstarVMag = '',
  String messier = '',
  String identifiers = '',
  String commonName = '',
}) {
  // OpenNGC has ~29 columns separated by semicolons
  // Columns: Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;
  //          J-Mag;H-Mag;K-Mag;SurfBr;Hubble;Cstar U-Mag;Cstar B-Mag;Cstar V-Mag;
  //          M;NGC;IC;Cstar Names;Identifiers;
  //          Messier;NGC cross;IC cross;...;Common names;NED notes;OpenNGC notes
  // Note: column indices in the source code are: 0:Name, 1:Type, 2:RA, 3:Dec,
  // 4:Const, 5:MajAx, 6:MinAx, 7:PosAng, 8:B-Mag, 9:V-Mag,
  // 10-22: various, 23: Messier, 24-26: cross-IDs, 27: Identifiers, 28: Common names
  final columns = <String>[
    name, type, ra, dec, constellation,
    majorAxis, minorAxis, posAngle, bMag, vMag,
    jMag, hMag, kMag, surfBr, hubble,
    cstarUMag, cstarBMag, cstarVMag,
    '', '', '', '', '',
    messier, // column 23
    '', '', '',
    identifiers, // column 27
    commonName, // column 28
  ];
  return columns.join(';');
}

/// Replicates OpenNgcDsoCatalog._parseOpenNgcLine
DeepSkyObject? _parseOpenNgcLinePublic(String line) {
  final parts = line.split(';');
  if (parts.length < 10) return null;

  var ngcName = parts[0].trim();
  final typeCode = parts[1].trim();

  if (typeCode == 'NonEx' || typeCode == 'Dup') return null;

  ngcName = _normalizeCatalogNamePublic(ngcName);

  final ra = _parseRaPublic(parts[2]);
  if (ra == null) return null;

  final dec = _parseDecPublic(parts[3]);
  if (dec == null) return null;

  final constellation = parts[4].trim();
  final majorAxis = double.tryParse(parts[5]);
  final minorAxis = double.tryParse(parts[6]);
  final positionAngle = double.tryParse(parts[7]);
  final bMag = double.tryParse(parts[8]);
  final vMag = double.tryParse(parts[9]);

  final magnitude = vMag ?? bMag;

  String? messier;
  if (parts.length > 23 && parts[23].isNotEmpty) {
    final messierNum = int.tryParse(parts[23].trim());
    if (messierNum != null && messierNum >= 1 && messierNum <= 110) {
      messier = 'M$messierNum';
    }
  }

  String? commonNames;
  if (parts.length > 28 && parts[28].isNotEmpty) {
    commonNames = parts[28];
  }

  final catalogIds = <String>[];
  if (parts.length > 27 && parts[27].isNotEmpty) {
    catalogIds.addAll(
      parts[27].split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
    );
  }
  if (messier != null) {
    catalogIds.add(messier);
  }

  String displayName;
  if (messier != null) {
    displayName = messier;
  } else if (commonNames != null && commonNames.isNotEmpty) {
    displayName = commonNames.split(',').first.trim();
  } else {
    displayName = ngcName;
  }

  final size = majorAxis;

  return DeepSkyObject(
    id: ngcName,
    name: displayName,
    coordinates: CelestialCoordinate(ra: ra, dec: dec),
    type: _parseDsoTypePublic(typeCode),
    magnitude: magnitude,
    sizeArcMin: size,
    constellation: constellation,
    catalogIds: catalogIds,
    positionAngle: positionAngle,
    minorAxisArcMin: minorAxis,
  );
}

/// Replicates OpenNgcDsoCatalog._normalizeCatalogName
String _normalizeCatalogNamePublic(String name) {
  final match = RegExp(
    r'^(NGC|IC)\s*(0*)(\d+)$',
    caseSensitive: false,
  ).firstMatch(name);
  if (match != null) {
    final prefix = match.group(1)!.toUpperCase();
    final number = match.group(3)!;
    return '$prefix$number';
  }
  return name;
}

/// Replicates OpenNgcDsoCatalog._parseRa
double? _parseRaPublic(String raStr) {
  if (raStr.isEmpty) return null;
  final parts = raStr.split(':');
  if (parts.length != 3) return null;

  final h = double.tryParse(parts[0]);
  final m = double.tryParse(parts[1]);
  final s = double.tryParse(parts[2]);

  if (h == null || m == null || s == null) return null;

  return h + m / 60 + s / 3600;
}

/// Replicates OpenNgcDsoCatalog._parseDec
double? _parseDecPublic(String decStr) {
  if (decStr.isEmpty) return null;

  final sign = decStr.startsWith('-') ? -1 : 1;
  final clean = decStr.replaceAll('+', '').replaceAll('-', '');
  final parts = clean.split(':');
  if (parts.length != 3) return null;

  final d = double.tryParse(parts[0]);
  final m = double.tryParse(parts[1]);
  final s = double.tryParse(parts[2]);

  if (d == null || m == null || s == null) return null;

  return sign * (d + m / 60 + s / 3600);
}

/// Replicates OpenNgcDsoCatalog._parseDsoType
DsoType _parseDsoTypePublic(String typeCode) {
  switch (typeCode) {
    case '*':
      return DsoType.star;
    case '**':
      return DsoType.doubleStar;
    case '*Ass':
      return DsoType.association;
    case 'OCl':
      return DsoType.openCluster;
    case 'GCl':
      return DsoType.globularCluster;
    case 'Cl+N':
      return DsoType.clusterWithNebulosity;
    case 'G':
      return DsoType.galaxy;
    case 'GPair':
      return DsoType.galaxyPair;
    case 'GTrpl':
      return DsoType.galaxyTriplet;
    case 'GGroup':
      return DsoType.galaxyGroup;
    case 'PN':
      return DsoType.planetaryNebula;
    case 'HII':
      return DsoType.hiiRegion;
    case 'DrkN':
      return DsoType.darkNebula;
    case 'EmN':
      return DsoType.emissionNebula;
    case 'Neb':
      return DsoType.nebula;
    case 'RfN':
      return DsoType.reflectionNebula;
    case 'SNR':
      return DsoType.supernova;
    case 'Nova':
      return DsoType.nova;
    default:
      return DsoType.other;
  }
}

// Constellation lookup tables (subset for testing)
const _constellationGenitives = {
  'AND': 'Andromedae',
  'ARI': 'Arietis',
  'AUR': 'Aurigae',
  'BOO': 'Bootis',
  'CMA': 'Canis Majoris',
  'CMI': 'Canis Minoris',
  'CYG': 'Cygni',
  'DRA': 'Draconis',
  'GEM': 'Geminorum',
  'HYA': 'Hydrae',
  'LEO': 'Leonis',
  'LYR': 'Lyrae',
  'ORI': 'Orionis',
  'PER': 'Persei',
  'SCO': 'Scorpii',
  'TAU': 'Tauri',
  'UMA': 'Ursae Majoris',
  'UMI': 'Ursae Minoris',
  'VIR': 'Virginis',
};

const _constellationNames = {
  'AND': 'Andromeda',
  'ARI': 'Aries',
  'AUR': 'Auriga',
  'BOO': 'Boötes',
  'CMA': 'Canis Major',
  'CMI': 'Canis Minor',
  'CYG': 'Cygnus',
  'DRA': 'Draco',
  'GEM': 'Gemini',
  'HYA': 'Hydra',
  'LEO': 'Leo',
  'LYR': 'Lyra',
  'ORI': 'Orion',
  'PER': 'Perseus',
  'SCO': 'Scorpius',
  'TAU': 'Taurus',
  'UMA': 'Ursa Major',
  'UMI': 'Ursa Minor',
  'VIR': 'Virgo',
};

String _getConstellationGenitive(String constellation) {
  return _constellationGenitives[constellation.toUpperCase()] ?? constellation;
}

String _getConstellationName(String abbr) {
  return _constellationNames[abbr.toUpperCase()] ?? abbr;
}
