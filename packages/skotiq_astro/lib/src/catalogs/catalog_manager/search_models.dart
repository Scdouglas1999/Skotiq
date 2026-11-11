part of '../catalog_manager.dart';

/// Unified search result from catalog manager
class CatalogSearchResult {
  final String name;
  final String catalogId;
  final double ra; // Degrees
  final double dec; // Degrees
  final String type;
  final double? magnitude;
  final String? constellation;
  final String? size;

  const CatalogSearchResult({
    required this.name,
    required this.catalogId,
    required this.ra,
    required this.dec,
    required this.type,
    this.magnitude,
    this.constellation,
    this.size,
  });
}

/// Parsed star data from HYG database
class HygStarData {
  final int id;
  final int? hipId;
  final int? hdId;
  final String? properName;
  final double ra; // Right ascension in degrees
  final double dec; // Declination in degrees
  final double? distance; // Distance in parsecs
  final double? magnitude; // Apparent visual magnitude
  final double? absoluteMagnitude;
  final String? spectralType;
  final String? constellation;
  final double? colorIndex; // B-V color index

  const HygStarData({
    required this.id,
    this.hipId,
    this.hdId,
    this.properName,
    required this.ra,
    required this.dec,
    this.distance,
    this.magnitude,
    this.absoluteMagnitude,
    this.spectralType,
    this.constellation,
    this.colorIndex,
  });

  /// Parse a line from the HYG CSV file
  /// Format: id,hip,hd,hr,gl,bf,proper,ra,dec,dist,pmra,pmdec,rv,mag,absmag,spect,ci,x,y,z,vx,vy,vz,rarad,decrad,pmrarad,pmdecrad,bayer,flam,con,comp,comp_primary,base,lum,var,var_min,var_max
  factory HygStarData.fromCsvLine(String line) {
    final parts = line.split(',');

    // Handle quoted fields
    final cleanParts = <String>[];
    var inQuotes = false;
    var current = '';

    for (final part in parts) {
      if (inQuotes) {
        current += ',$part';
        if (part.endsWith('"')) {
          cleanParts.add(current.substring(1, current.length - 1));
          inQuotes = false;
          current = '';
        }
      } else if (part.startsWith('"') && !part.endsWith('"')) {
        inQuotes = true;
        current = part;
      } else {
        cleanParts.add(part.replaceAll('"', ''));
      }
    }

    final p = cleanParts;

    return HygStarData(
      id: int.tryParse(p[0]) ?? 0,
      hipId: int.tryParse(p[1]),
      hdId: int.tryParse(p[2]),
      properName: p.length > 6 && p[6].isNotEmpty ? p[6] : null,
      ra: (double.tryParse(p[7]) ?? 0) * 15, // Convert from hours to degrees
      dec: double.tryParse(p[8]) ?? 0,
      distance: double.tryParse(p[9]),
      magnitude: double.tryParse(p[13]),
      absoluteMagnitude: double.tryParse(p[14]),
      spectralType: p.length > 15 && p[15].isNotEmpty ? p[15] : null,
      colorIndex: p.length > 16 ? double.tryParse(p[16]) : null,
      constellation: p.length > 29 && p[29].isNotEmpty ? p[29] : null,
    );
  }

  /// Get star name (proper name, or HIP/HD designation)
  String get name {
    if (properName != null && properName!.isNotEmpty) {
      return properName!;
    }
    if (hipId != null) {
      return 'HIP $hipId';
    }
    if (hdId != null) {
      return 'HD $hdId';
    }
    return 'Star $id';
  }

  /// Get catalog ID
  String get catalogId {
    if (hipId != null) {
      return 'HIP$hipId';
    }
    if (hdId != null) {
      return 'HD$hdId';
    }
    return 'HYG$id';
  }
}

/// Parsed deep sky object data from OpenNGC
class OpenNgcData {
  final String name; // NGC/IC designation
  final String type; // Object type code
  final double ra; // Right ascension in degrees
  final double dec; // Declination in degrees
  final double? magnitude; // Visual magnitude
  final double? majorAxis; // Major axis in arcminutes
  final double? minorAxis; // Minor axis in arcminutes
  final double? positionAngle; // Position angle in degrees
  final String? messier; // Messier designation
  final String? ngcId; // NGC ID if IC object
  final String? commonNames; // Common names
  final String constellation;
  final String? notes;

  const OpenNgcData({
    required this.name,
    required this.type,
    required this.ra,
    required this.dec,
    this.magnitude,
    this.majorAxis,
    this.minorAxis,
    this.positionAngle,
    this.messier,
    this.ngcId,
    this.commonNames,
    required this.constellation,
    this.notes,
  });

  /// Parse a line from the OpenNGC CSV file
  /// Format: Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;SurfBr;Hubble;Pax;Pm-RA;Pm-Dec;RadVel;Redshift;Cstar U-Mag;Cstar B-Mag;Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;Common names;NED notes;OpenNGC notes;Sources
  /// Column indices:
  /// 0:Name, 1:Type, 2:RA, 3:Dec, 4:Const, 5:MajAx, 6:MinAx, 7:PosAng,
  /// 8:B-Mag, 9:V-Mag, 10:J-Mag, 11:H-Mag, 12:K-Mag, 13:SurfBr, 14:Hubble,
  /// 15:Pax, 16:Pm-RA, 17:Pm-Dec, 18:RadVel, 19:Redshift,
  /// 20:Cstar U-Mag, 21:Cstar B-Mag, 22:Cstar V-Mag,
  /// 23:M, 24:NGC, 25:IC, 26:Cstar Names, 27:Identifiers,
  /// 28:Common names, 29:NED notes, 30:OpenNGC notes, 31:Sources
  factory OpenNgcData.fromCsvLine(String line) {
    final parts = line.split(';');

    // Parse RA (format: HH:MM:SS.ss)
    double parseRa(String raStr) {
      if (raStr.isEmpty) return 0;
      try {
        final parts = raStr.split(':');
        if (parts.length == 3) {
          final h = double.parse(parts[0]);
          final m = double.parse(parts[1]);
          final s = double.parse(parts[2]);
          return (h + m / 60 + s / 3600) * 15; // Convert to degrees
        }
        // Fallback: try parsing as decimal degrees directly
        final val = double.tryParse(raStr);
        if (val != null) return val;
      } catch (e) {
        // Ignore error and return 0
      }
      return 0;
    }

    // Parse Dec (format: +/-DD:MM:SS.s)
    double parseDec(String decStr) {
      if (decStr.isEmpty) return 0;
      final sign = decStr.startsWith('-') ? -1 : 1;
      final clean = decStr.replaceAll('+', '').replaceAll('-', '');
      final parts = clean.split(':');
      if (parts.length != 3) return 0;
      final d = double.tryParse(parts[0]) ?? 0;
      final m = double.tryParse(parts[1]) ?? 0;
      final s = double.tryParse(parts[2]) ?? 0;
      return sign * (d + m / 60 + s / 3600);
    }

    return OpenNgcData(
      name: parts[0],
      type: parts[1],
      ra: parseRa(parts[2]),
      dec: parseDec(parts[3]),
      constellation: parts.length > 4 ? parts[4] : '',
      majorAxis: parts.length > 5 ? double.tryParse(parts[5]) : null,
      minorAxis: parts.length > 6 ? double.tryParse(parts[6]) : null,
      positionAngle: parts.length > 7 ? double.tryParse(parts[7]) : null,
      magnitude: parts.length > 9 ? double.tryParse(parts[9]) : null, // V-Mag
      messier: _parseMessier(parts.length > 23 ? parts[23] : ''),
      ngcId: parts.length > 24 && parts[24].isNotEmpty
          ? 'NGC ${parts[24]}'
          : null,
      commonNames: parts.length > 28 && parts[28].isNotEmpty ? parts[28] : null,
      notes: parts.length > 30 && parts[30].isNotEmpty ? parts[30] : null,
    );
  }

  /// Get the display name (Messier if available, then common name, then catalog ID)
  String get displayName {
    if (messier != null) return messier!;
    if (commonNames != null && commonNames!.isNotEmpty) {
      return commonNames!.split(',').first.trim();
    }
    return name;
  }

  static String? _parseMessier(String raw) {
    final messierNum = int.tryParse(raw.trim());
    if (messierNum == null || messierNum < 1 || messierNum > 110) {
      return null;
    }
    return 'M$messierNum';
  }

  /// Get object type description
  String get typeDescription {
    switch (type) {
      case '*':
        return 'Star';
      case '**':
        return 'Double Star';
      case '*Ass':
        return 'Association of Stars';
      case 'OCl':
        return 'Open Cluster';
      case 'GCl':
        return 'Globular Cluster';
      case 'Cl+N':
        return 'Cluster + Nebula';
      case 'G':
        return 'Galaxy';
      case 'GPair':
        return 'Galaxy Pair';
      case 'GTrpl':
        return 'Galaxy Triplet';
      case 'GGroup':
        return 'Galaxy Group';
      case 'PN':
        return 'Planetary Nebula';
      case 'HII':
        return 'HII Region';
      case 'DrkN':
        return 'Dark Nebula';
      case 'EmN':
        return 'Emission Nebula';
      case 'Neb':
        return 'Nebula';
      case 'RfN':
        return 'Reflection Nebula';
      case 'SNR':
        return 'Supernova Remnant';
      case 'Nova':
        return 'Nova';
      case 'NonEx':
        return 'Non-Existent';
      case 'Dup':
        return 'Duplicate Entry';
      case 'Other':
        return 'Other';
      default:
        return type;
    }
  }

  /// Get object size string
  String? get sizeString {
    if (majorAxis == null) return null;
    if (minorAxis != null && minorAxis != majorAxis) {
      return "${majorAxis!.toStringAsFixed(1)}' × ${minorAxis!.toStringAsFixed(1)}'";
    }
    return "${majorAxis!.toStringAsFixed(1)}'";
  }
}

/// Star catalog loader that reads from downloaded HYG database
