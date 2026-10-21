import '../celestial_object.dart';
import '../coordinate_system.dart';

/// A catalog designation such as `M 42`, `NGC 891`, `Sh2-129` or `B 33`,
/// reduced to a catalog key and a number so that every way of typing it
/// compares equal: `m42`, `M 42`, `Messier 42` and `M042` all parse to
/// `(M, 42)`.
class CatalogDesignation {
  /// Canonical catalog prefix: `M`, `NGC`, `IC`, `C`, `Sh2`, `B`, `LDN`, ...
  final String catalog;

  /// Catalog number without leading zeros.
  final int number;

  /// Optional single-letter component suffix (`NGC 5194A`), lower case.
  final String suffix;

  const CatalogDesignation(this.catalog, this.number, [this.suffix = '']);

  /// Spelling of each catalog prefix, keyed by the lower-case, space-free
  /// forms people type. Only catalogs where "prefix + number" names one
  /// object are listed; survey identifiers (2MASX, IRAS, ...) never parse.
  static const Map<String, String> _prefixes = {
    'm': 'M',
    'messier': 'M',
    'ngc': 'NGC',
    'ic': 'IC',
    'c': 'C',
    'caldwell': 'C',
    'sharpless': 'Sh2',
    'b': 'B',
    'barnard': 'B',
    'ldn': 'LDN',
    'lbn': 'LBN',
    'abell': 'Abell',
    'arp': 'Arp',
    'mel': 'Mel',
    'melotte': 'Mel',
    'cr': 'Cr',
    'collinder': 'Cr',
    'vdb': 'vdB',
    'ced': 'Ced',
    'ugc': 'UGC',
    'pgc': 'PGC',
    'mwsc': 'MWSC',
    'hd': 'HD',
    'hip': 'HIP',
    'hr': 'HR',
  };

  static final RegExp _sharpless = RegExp(
    r'^(?:sh2|sharpless2?)-?0*(\d+)([a-z]?)$',
  );
  static final RegExp _shape = RegExp(r'^([a-z]+)-?0*(\d+)([a-z]?)$');

  /// Parse [text] as a single catalog designation, or return null when it is
  /// not one (common names, survey identifiers, coordinates).
  static CatalogDesignation? parse(String text) {
    final compact = text.toLowerCase().replaceAll(RegExp(r'[\s_]+'), '');
    if (compact.isEmpty) return null;
    final sharpless = _sharpless.firstMatch(compact);
    if (sharpless != null) {
      return CatalogDesignation(
        'Sh2',
        int.parse(sharpless.group(1)!),
        sharpless.group(2)!,
      );
    }
    final match = _shape.firstMatch(compact);
    if (match == null) return null;
    final catalog = _prefixes[match.group(1)!];
    if (catalog == null) return null;
    final number = int.tryParse(match.group(2)!);
    if (number == null) return null;
    return CatalogDesignation(catalog, number, match.group(3)!);
  }

  /// Lower-case, space-free key: `m42`, `ngc891`, `sh2129`.
  String get key => '${catalog.toLowerCase()}$number$suffix';

  /// Display spelling: `M 42`, `NGC 891`, `Sh2-129`.
  String get display => catalog == 'Sh2'
      ? 'Sh2-$number${suffix.toUpperCase()}'
      : '$catalog $number${suffix.toUpperCase()}';

  @override
  bool operator ==(Object other) =>
      other is CatalogDesignation && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => display;
}

/// Lower-case a name, turn punctuation into spaces and collapse whitespace,
/// so `"Orion  Nebula"`, `"orion nebula"` and `"Orion-Nebula"` compare equal.
String normalizeTargetName(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r"[^a-z0-9]+"), ' ')
    .trim()
    .replaceFirst(RegExp(r'^the '), '');

/// Designations that name an object the OpenNGC catalog files under another
/// designation. M102 is not in OpenNGC; it is conventionally NGC 5866.
const Map<String, String> kDesignationAliases = {'m102': 'ngc5866'};

/// Common names that name a deep-sky object, mapped to its designations.
///
/// The OpenNGC "Common names" column covers many of these already; this table
/// fills the names people actually type that it does not carry ("Andromeda",
/// "Pleiades").
const Map<String, List<String>> kWellKnownDsoNames = {
  'andromeda': ['M31', 'NGC224'],
  'andromeda galaxy': ['M31', 'NGC224'],
  'orion nebula': ['M42', 'NGC1976'],
  'great orion nebula': ['M42', 'NGC1976'],
  'ring nebula': ['M57', 'NGC6720'],
  'crab nebula': ['M1', 'NGC1952'],
  'whirlpool galaxy': ['M51', 'NGC5194'],
  'sombrero galaxy': ['M104', 'NGC4594'],
  'pinwheel galaxy': ['M101', 'NGC5457'],
  'triangulum galaxy': ['M33', 'NGC598'],
  'lagoon nebula': ['M8', 'NGC6523'],
  'eagle nebula': ['M16', 'NGC6611'],
  'pillars of creation': ['M16', 'NGC6611'],
  'omega nebula': ['M17', 'NGC6618'],
  'swan nebula': ['M17', 'NGC6618'],
  'trifid nebula': ['M20', 'NGC6514'],
  'dumbbell nebula': ['M27', 'NGC6853'],
  'hercules cluster': ['M13', 'NGC6205'],
  'great hercules cluster': ['M13', 'NGC6205'],
  'wild duck cluster': ['M11', 'NGC6705'],
  'pleiades': ['M45'],
  'seven sisters': ['M45'],
  'beehive cluster': ['M44', 'NGC2632'],
  'praesepe': ['M44', 'NGC2632'],
  'horsehead nebula': ['IC434', 'B33'],
  'flame nebula': ['NGC2024'],
  'rosette nebula': ['NGC2238'],
  'north america nebula': ['NGC7000'],
  'pelican nebula': ['IC5070'],
  'veil nebula': ['NGC6960', 'NGC6992'],
  'owl nebula': ['M97', 'NGC3587'],
  'cat eye nebula': ['NGC6543'],
  'cats eye nebula': ['NGC6543'],
  'helix nebula': ['NGC7293'],
  'double cluster': ['C14'],
  'bode galaxy': ['M81', 'NGC3031'],
  'bodes galaxy': ['M81', 'NGC3031'],
  'cigar galaxy': ['M82', 'NGC3034'],
  'sunflower galaxy': ['M63', 'NGC5055'],
  'black eye galaxy': ['M64', 'NGC4826'],
  'sculptor galaxy': ['NGC253'],
  'centaurus a': ['NGC5128'],
  'southern pinwheel': ['M83', 'NGC5236'],
  'antennae galaxies': ['NGC4038', 'NGC4039'],
  'leo triplet': ['M65', 'M66', 'NGC3628'],
  'hamburger galaxy': ['NGC3628'],
  'needle galaxy': ['NGC4565'],
  'cocoon nebula': ['IC5146'],
  'bubble nebula': ['NGC7635'],
  'elephant trunk nebula': ['IC1396'],
  'barnard loop': ['Sh2-276'],
  'barnards loop': ['Sh2-276'],
  'soul nebula': ['IC1848'],
  'heart nebula': ['IC1805'],
  'running man nebula': ['NGC1977'],
  'california nebula': ['NGC1499'],
  'pacman nebula': ['NGC281'],
  'flaming star nebula': ['IC405'],
  'cone nebula': ['NGC2264'],
  'christmas tree cluster': ['NGC2264'],
  'blinking planetary': ['NGC6826'],
  'blue snowball': ['NGC7662'],
  'saturn nebula': ['NGC7009'],
  'eskimo nebula': ['NGC2392'],
  'little dumbbell': ['M76', 'NGC650'],
  'phantom galaxy': ['M74', 'NGC628'],
  'butterfly cluster': ['M6', 'NGC6405'],
  'ptolemy cluster': ['M7', 'NGC6475'],
  'starfish cluster': ['M38', 'NGC1912'],
  'hyades': ['C41'],
  'coalsack': ['C99'],
  'cave nebula': ['C9'],
};

/// Deep-sky objects people frame that the OpenNGC NGC.csv does not list:
/// the Pleiades and M40 live in OpenNGC's addendum, which the app does not
/// download, and four Caldwell objects have no NGC/IC entry carrying their C
/// number. Positions are SIMBAD's (ICRS, J2000).
const List<DeepSkyObject> kSupplementalDsos = [
  DeepSkyObject(
    id: 'M45',
    name: 'M45',
    coordinates: CelestialCoordinate(ra: 3.773389, dec: 24.113889),
    type: DsoType.openCluster,
    magnitude: 1.6,
    sizeArcMin: 110,
    constellation: 'Taurus',
    catalogIds: ['M45', 'Mel 22'],
    commonNames: 'Pleiades,Seven Sisters',
  ),
  DeepSkyObject(
    id: 'M40',
    name: 'M40',
    coordinates: CelestialCoordinate(ra: 12.37, dec: 58.083333),
    type: DsoType.doubleStar,
    magnitude: 8.4,
    sizeArcMin: 0.8,
    constellation: 'Ursa Major',
    catalogIds: ['M40', 'Winnecke 4'],
  ),
  DeepSkyObject(
    id: 'Sh2-155',
    name: 'Cave Nebula',
    coordinates: CelestialCoordinate(ra: 22.951641, dec: 62.635916),
    type: DsoType.hiiRegion,
    sizeArcMin: 50,
    constellation: 'Cepheus',
    catalogIds: ['C 009', 'Sh2-155'],
    commonNames: 'Cave Nebula',
  ),
  DeepSkyObject(
    id: 'C14',
    name: 'Double Cluster',
    coordinates: CelestialCoordinate(ra: 2.344167, dec: 57.141389),
    type: DsoType.openCluster,
    magnitude: 3.7,
    sizeArcMin: 60,
    constellation: 'Perseus',
    catalogIds: ['C 014'],
    commonNames: 'Double Cluster,h and chi Persei',
  ),
  DeepSkyObject(
    id: 'Mel 25',
    name: 'Hyades',
    coordinates: CelestialCoordinate(ra: 4.496472, dec: 16.948056),
    type: DsoType.openCluster,
    magnitude: 0.5,
    sizeArcMin: 330,
    constellation: 'Taurus',
    catalogIds: ['C 041', 'Mel 25'],
    commonNames: 'Hyades',
  ),
  DeepSkyObject(
    id: 'C99',
    name: 'Coalsack Nebula',
    coordinates: CelestialCoordinate(ra: 12.521944, dec: -63.743333),
    type: DsoType.darkNebula,
    sizeArcMin: 400,
    constellation: 'Crux',
    catalogIds: ['C 099'],
    commonNames: 'Coalsack Nebula,Coalsack',
  ),
];
