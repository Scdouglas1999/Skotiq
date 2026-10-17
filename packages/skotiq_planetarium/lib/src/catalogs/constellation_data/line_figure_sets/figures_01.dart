part of '../../constellation_data.dart';

const _lineFigureSet01 = <ConstellationData>[
  // Orion
  ConstellationData(
    abbreviation: 'Ori',
    name: 'Orion',
    center: CelestialCoordinate(ra: 5.5, dec: 0),
    lines: [
      // Shoulders to Belt
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.9195, dec: 7.4070), // Betelgeuse
        end: CelestialCoordinate(ra: 5.5334, dec: -0.2991), // Mintaka
        startStarName: 'Betelgeuse',
        endStarName: 'Mintaka',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.4188, dec: 6.3497), // Bellatrix
        end: CelestialCoordinate(ra: 5.6793, dec: -1.9426), // Alnitak
        startStarName: 'Bellatrix',
        endStarName: 'Alnitak',
      ),
      // Belt
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.5334, dec: -0.2991), // Mintaka
        end: CelestialCoordinate(ra: 5.6036, dec: -1.2019), // Alnilam
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.6036, dec: -1.2019), // Alnilam
        end: CelestialCoordinate(ra: 5.6793, dec: -1.9426), // Alnitak
      ),
      // Feet
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.6793, dec: -1.9426), // Alnitak
        end: CelestialCoordinate(ra: 5.7958, dec: -9.6697), // Saiph
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.5334, dec: -0.2991), // Mintaka
        end: CelestialCoordinate(ra: 5.2422, dec: -8.2017), // Rigel
        endStarName: 'Rigel',
      ),
      // Shoulders
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.9195, dec: 7.4070), // Betelgeuse
        end: CelestialCoordinate(ra: 5.4188, dec: 6.3497), // Bellatrix
      ),
    ],
  ),

  // Ursa Major (Big Dipper)
  ConstellationData(
    abbreviation: 'UMa',
    name: 'Ursa Major',
    center: CelestialCoordinate(ra: 11.0, dec: 55),
    lines: [
      // Bowl
      ConstellationLine(
        start: CelestialCoordinate(ra: 11.0621, dec: 61.7510), // Dubhe
        end: CelestialCoordinate(ra: 11.0306, dec: 56.3824), // Merak
        startStarName: 'Dubhe',
        endStarName: 'Merak',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 11.0306, dec: 56.3824), // Merak
        end: CelestialCoordinate(ra: 11.8968, dec: 53.6948), // Phecda
        startStarName: 'Merak',
        endStarName: 'Phecda',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 11.8968, dec: 53.6948), // Phecda
        end: CelestialCoordinate(ra: 12.2571, dec: 57.0326), // Megrez
        startStarName: 'Phecda',
        endStarName: 'Megrez',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.2571, dec: 57.0326), // Megrez
        end: CelestialCoordinate(ra: 11.0621, dec: 61.7510), // Dubhe
        startStarName: 'Megrez',
        endStarName: 'Dubhe',
      ),
      // Handle
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.2571, dec: 57.0326), // Megrez
        end: CelestialCoordinate(ra: 12.9004, dec: 55.9598), // Alioth
        startStarName: 'Megrez',
        endStarName: 'Alioth',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.9004, dec: 55.9598), // Alioth
        end: CelestialCoordinate(ra: 13.3988, dec: 54.9254), // Mizar
        startStarName: 'Alioth',
        endStarName: 'Mizar',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 13.3988, dec: 54.9254), // Mizar
        end: CelestialCoordinate(ra: 13.7923, dec: 49.3133), // Alkaid
        startStarName: 'Mizar',
        endStarName: 'Alkaid',
      ),
    ],
  ),

  // Cassiopeia
  ConstellationData(
    abbreviation: 'Cas',
    name: 'Cassiopeia',
    center: CelestialCoordinate(ra: 1.0, dec: 60),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.1530, dec: 59.1498), // Caph
        end: CelestialCoordinate(ra: 0.6752, dec: 56.5373), // Schedar
        startStarName: 'Caph',
        endStarName: 'Schedar',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.6752, dec: 56.5373), // Schedar
        end: CelestialCoordinate(ra: 0.9453, dec: 60.7167), // Navi
        startStarName: 'Schedar',
        endStarName: 'Navi',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.9453, dec: 60.7167), // Navi
        end: CelestialCoordinate(ra: 1.4306, dec: 60.2352), // Ruchbah
        startStarName: 'Navi',
        endStarName: 'Ruchbah',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.4306, dec: 60.2352), // Ruchbah
        end: CelestialCoordinate(ra: 1.9065, dec: 63.6700), // Segin
        startStarName: 'Ruchbah',
        endStarName: 'Segin',
      ),
    ],
  ),

  // Cygnus (Northern Cross)
  ConstellationData(
    abbreviation: 'Cyg',
    name: 'Cygnus',
    center: CelestialCoordinate(ra: 20.5, dec: 40),
    lines: [
      // Main body
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.6905, dec: 45.2803), // Deneb
        end: CelestialCoordinate(ra: 19.5120, dec: 27.9597), // Albireo
        startStarName: 'Deneb',
        endStarName: 'Albireo',
      ),
      // Cross beam (simplified)
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.3706, dec: 40.2567), // Sadr
        end: CelestialCoordinate(ra: 19.7489, dec: 45.1309), // Gienah Cygni
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.3706, dec: 40.2567), // Sadr
        end: CelestialCoordinate(ra: 21.2156, dec: 30.2269), // Fawaris
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.6905, dec: 45.2803), // Deneb
        end: CelestialCoordinate(ra: 20.3706, dec: 40.2567), // Sadr
      ),
    ],
  ),

  // Leo
  ConstellationData(
    abbreviation: 'Leo',
    name: 'Leo',
    center: CelestialCoordinate(ra: 10.7, dec: 15),
    lines: [
      // Sickle
      ConstellationLine(
        start: CelestialCoordinate(ra: 10.1395, dec: 11.9672), // Regulus
        end: CelestialCoordinate(ra: 10.3328, dec: 19.8415), // Eta Leo
        startStarName: 'Regulus',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 10.3328, dec: 19.8415), // Eta Leo
        end: CelestialCoordinate(ra: 10.1220, dec: 23.7743), // Algieba
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 10.1220, dec: 23.7743), // Algieba
        end: CelestialCoordinate(ra: 10.2787, dec: 26.0072), // Zosma
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 10.2787, dec: 26.0072), // Zosma
        end: CelestialCoordinate(ra: 9.7644, dec: 26.0068), // Ras Elased
      ),
      // Body to tail
      ConstellationLine(
        start: CelestialCoordinate(ra: 10.2787, dec: 26.0072), // Zosma
        end: CelestialCoordinate(ra: 11.2351, dec: 20.5236), // Chertan
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 11.2351, dec: 20.5236), // Chertan
        end: CelestialCoordinate(ra: 11.8177, dec: 14.5720), // Denebola
        endStarName: 'Denebola',
      ),
      // Triangle
      ConstellationLine(
        start: CelestialCoordinate(ra: 10.1395, dec: 11.9672), // Regulus
        end: CelestialCoordinate(ra: 11.2351, dec: 20.5236), // Chertan
      ),
    ],
  ),

  // Scorpius
  ConstellationData(
    abbreviation: 'Sco',
    name: 'Scorpius',
    center: CelestialCoordinate(ra: 16.9, dec: -30),
    lines: [
      // Head to heart
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.0053, dec: -22.6217), // Dschubba
        end: CelestialCoordinate(ra: 16.4901, dec: -26.4320), // Antares
        endStarName: 'Antares',
      ),
      // Heart to tail
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.4901, dec: -26.4320), // Antares
        end: CelestialCoordinate(ra: 16.8364, dec: -34.2933), // Tau Sco
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.8364, dec: -34.2933), // Tau Sco
        end: CelestialCoordinate(ra: 17.2024, dec: -37.2959), // Epsilon Sco
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.2024, dec: -37.2959), // Epsilon Sco
        end: CelestialCoordinate(ra: 17.5601, dec: -37.1038), // Shaula
        endStarName: 'Shaula',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.5601, dec: -37.1038), // Shaula
        end: CelestialCoordinate(ra: 17.7081, dec: -39.0299), // Lesath
      ),
    ],
  ),

  // Gemini
  ConstellationData(
    abbreviation: 'Gem',
    name: 'Gemini',
    center: CelestialCoordinate(ra: 7.1, dec: 25),
    lines: [
      // Twins' heads
      ConstellationLine(
        start: CelestialCoordinate(ra: 7.5767, dec: 31.8884), // Castor
        end: CelestialCoordinate(ra: 7.7553, dec: 28.0262), // Pollux
        startStarName: 'Castor',
        endStarName: 'Pollux',
      ),
      // Bodies
      ConstellationLine(
        start: CelestialCoordinate(ra: 7.5767, dec: 31.8884), // Castor
        end: CelestialCoordinate(ra: 7.0683, dec: 20.5703), // Mebsuta
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 7.7553, dec: 28.0262), // Pollux
        end: CelestialCoordinate(ra: 7.1850, dec: 16.5403), // Wasat
      ),
      // Feet
      ConstellationLine(
        start: CelestialCoordinate(ra: 7.0683, dec: 20.5703), // Mebsuta
        end: CelestialCoordinate(ra: 6.6285, dec: 16.3993), // Alhena
        endStarName: 'Alhena',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 7.1850, dec: 16.5403), // Wasat
        end: CelestialCoordinate(ra: 6.7328, dec: 12.8959), // Mekbuda
      ),
    ],
  ),

  // Pegasus (Great Square)
  ConstellationData(
    abbreviation: 'Peg',
    name: 'Pegasus',
    center: CelestialCoordinate(ra: 22.7, dec: 20),
    lines: [
      // Great Square
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.1398, dec: 29.0904), // Alpheratz
        end: CelestialCoordinate(ra: 23.0629, dec: 28.0828), // Scheat
        startStarName: 'Alpheratz',
        endStarName: 'Scheat',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.0629, dec: 28.0828), // Scheat
        end: CelestialCoordinate(ra: 23.0798, dec: 15.2053), // Markab
        endStarName: 'Markab',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.0798, dec: 15.2053), // Markab
        end: CelestialCoordinate(ra: 0.2201, dec: 15.1836), // Algenib
        endStarName: 'Algenib',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.2201, dec: 15.1836), // Algenib
        end: CelestialCoordinate(ra: 0.1398, dec: 29.0904), // Alpheratz
      ),
      // Neck/Head
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.0629, dec: 28.0828), // Scheat
        end: CelestialCoordinate(ra: 22.1168, dec: 25.3450), // Matar
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.1168, dec: 25.3450), // Matar
        end: CelestialCoordinate(ra: 21.7440, dec: 9.8749), // Enif
      ),
    ],
  ),

  // Andromeda
  ConstellationData(
    abbreviation: 'And',
    name: 'Andromeda',
    center: CelestialCoordinate(ra: 0.8, dec: 38),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.1398, dec: 29.0904), // Alpheratz
        end: CelestialCoordinate(ra: 1.1621, dec: 35.6206), // Mirach
        startStarName: 'Alpheratz',
        endStarName: 'Mirach',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.1621, dec: 35.6206), // Mirach
        end: CelestialCoordinate(ra: 2.0650, dec: 42.3297), // Almach
        endStarName: 'Almach',
      ),
    ],
  ),

  // Taurus
  ConstellationData(
    abbreviation: 'Tau',
    name: 'Taurus',
    center: CelestialCoordinate(ra: 4.5, dec: 17),
    lines: [
      // V-shape head
      ConstellationLine(
        start: CelestialCoordinate(ra: 4.5988, dec: 16.5093), // Aldebaran
        end: CelestialCoordinate(ra: 4.4762, dec: 15.9620), // Theta2 Tau
        startStarName: 'Aldebaran',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 4.4762, dec: 15.9620), // Theta2 Tau
        end: CelestialCoordinate(ra: 4.3291, dec: 15.6277), // Gamma Tau
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 4.3291, dec: 15.6277), // Gamma Tau
        end: CelestialCoordinate(ra: 4.0113, dec: 12.4904), // Delta Tau
      ),
      // Horn tips
      ConstellationLine(
        start: CelestialCoordinate(ra: 4.5988, dec: 16.5093), // Aldebaran
        end: CelestialCoordinate(ra: 5.4382, dec: 28.6074), // Elnath
        endStarName: 'Elnath',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 4.4762, dec: 15.9620), // Theta2 Tau
        end: CelestialCoordinate(ra: 5.6276, dec: 21.1425), // Zeta Tau
      ),
    ],
  ),

  // Canis Major
  ConstellationData(
    abbreviation: 'CMa',
    name: 'Canis Major',
    center: CelestialCoordinate(ra: 6.8, dec: -22),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 6.7524, dec: -16.7161), // Sirius
        end: CelestialCoordinate(ra: 6.3783, dec: -17.9559), // Mirzam
        startStarName: 'Sirius',
        endStarName: 'Mirzam',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 6.7524, dec: -16.7161), // Sirius
        end: CelestialCoordinate(ra: 7.1399, dec: -26.3932), // Wezen
        endStarName: 'Wezen',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 7.1399, dec: -26.3932), // Wezen
        end: CelestialCoordinate(ra: 6.9771, dec: -28.9722), // Adhara
        endStarName: 'Adhara',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 6.9771, dec: -28.9722), // Adhara
        end: CelestialCoordinate(ra: 6.6111, dec: -32.5085), // Furud
      ),
    ],
  ),

  // Lyra
  ConstellationData(
    abbreviation: 'Lyr',
    name: 'Lyra',
    center: CelestialCoordinate(ra: 18.8, dec: 36),
    lines: [
      // Main parallelogram
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.6156, dec: 38.7837), // Vega
        end: CelestialCoordinate(ra: 18.7462, dec: 37.6050), // Epsilon1 Lyr
        startStarName: 'Vega',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.6156, dec: 38.7837), // Vega
        end: CelestialCoordinate(ra: 18.9782, dec: 36.8986), // Zeta1 Lyr
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.9782, dec: 36.8986), // Zeta1 Lyr
        end: CelestialCoordinate(ra: 18.9077, dec: 33.3627), // Sulafat
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.9077, dec: 33.3627), // Sulafat
        end: CelestialCoordinate(ra: 18.8348, dec: 33.3629), // Sheliak
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.8348, dec: 33.3629), // Sheliak
        end: CelestialCoordinate(ra: 18.9782, dec: 36.8986), // Zeta1 Lyr
      ),
    ],
  ),

  // Aquila
  ConstellationData(
    abbreviation: 'Aql',
    name: 'Aquila',
    center: CelestialCoordinate(ra: 19.7, dec: 3),
    lines: [
      // Main body
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.8464, dec: 8.8683), // Altair
        end: CelestialCoordinate(ra: 19.7714, dec: 10.6132), // Tarazed
        startStarName: 'Altair',
        endStarName: 'Tarazed',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.8464, dec: 8.8683), // Altair
        end: CelestialCoordinate(ra: 19.9216, dec: 6.4067), // Alshain
      ),
      // Wings
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.7714, dec: 10.6132), // Tarazed
        end: CelestialCoordinate(ra: 19.1042, dec: 13.8635), // Delta Aql
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.9216, dec: 6.4067), // Alshain
        end: CelestialCoordinate(ra: 20.1886, dec: -0.8215), // Theta Aql
      ),
    ],
  ),

  // Crux (Southern Cross)
  ConstellationData(
    abbreviation: 'Cru',
    name: 'Crux',
    center: CelestialCoordinate(ra: 12.5, dec: -60),
    lines: [
      // Vertical
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.5194, dec: -57.1132), // Gacrux
        end: CelestialCoordinate(ra: 12.4433, dec: -63.0990), // Acrux
        startStarName: 'Gacrux',
        endStarName: 'Acrux',
      ),
      // Horizontal
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.7953, dec: -59.6888), // Mimosa
        end: CelestialCoordinate(ra: 12.2523, dec: -58.7489), // Imai
        startStarName: 'Mimosa',
        endStarName: 'Imai',
      ),
    ],
  ),

  // Perseus
  ConstellationData(
    abbreviation: 'Per',
    name: 'Perseus',
    center: CelestialCoordinate(ra: 3.4, dec: 42),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 3.4054, dec: 49.8612), // Mirfak
        end: CelestialCoordinate(ra: 3.0795, dec: 53.5065), // Delta Per
        startStarName: 'Mirfak',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 3.4054, dec: 49.8612), // Mirfak
        end: CelestialCoordinate(ra: 3.7155, dec: 47.7876), // Gamma Per
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 3.7155, dec: 47.7876), // Gamma Per
        end: CelestialCoordinate(ra: 3.1364, dec: 40.9557), // Algol
        endStarName: 'Algol',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 3.1364, dec: 40.9557), // Algol
        end: CelestialCoordinate(ra: 2.8449, dec: 38.3188), // Rho Per
      ),
    ],
  ),

  // Bootes
  ConstellationData(
    abbreviation: 'Boo',
    name: 'Bootes',
    center: CelestialCoordinate(ra: 14.7, dec: 30),
    lines: [
      // Kite shape
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.2612, dec: 19.1825), // Arcturus
        end: CelestialCoordinate(ra: 13.9116, dec: 18.3979), // Eta Boo
        startStarName: 'Arcturus',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 13.9116, dec: 18.3979), // Eta Boo
        end: CelestialCoordinate(ra: 14.5308, dec: 30.3713), // Izar
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.5308, dec: 30.3713), // Izar
        end: CelestialCoordinate(ra: 14.7499, dec: 27.0743), // Delta Boo
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.7499, dec: 27.0743), // Delta Boo
        end: CelestialCoordinate(ra: 14.2612, dec: 19.1825), // Arcturus
      ),
      // Top
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.5308, dec: 30.3713), // Izar
        end: CelestialCoordinate(ra: 15.0322, dec: 40.3906), // Nekkar
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.7499, dec: 27.0743), // Delta Boo
        end: CelestialCoordinate(ra: 15.0322, dec: 40.3906), // Nekkar
      ),
    ],
  ),

  // Virgo
  ConstellationData(
    abbreviation: 'Vir',
    name: 'Virgo',
    center: CelestialCoordinate(ra: 13.0, dec: -4),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 13.4199, dec: -11.1614), // Spica
        end: CelestialCoordinate(ra: 12.6943, dec: -1.4494), // Porrima
        startStarName: 'Spica',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.6943, dec: -1.4494), // Porrima
        end: CelestialCoordinate(ra: 12.9264, dec: 3.3975), // Vindemiatrix
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.9264, dec: 3.3975), // Vindemiatrix
        end: CelestialCoordinate(ra: 13.0367, dec: 10.9592), // Delta Vir
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.6943, dec: -1.4494), // Porrima
        end: CelestialCoordinate(ra: 11.8446, dec: 1.7648), // Zaniah
      ),
    ],
  ),

  // Ursa Minor (Little Dipper)
  ConstellationData(
    abbreviation: 'UMi',
    name: 'Ursa Minor',
    center: CelestialCoordinate(ra: 15.0, dec: 75),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 2.5302, dec: 89.2641), // Polaris
        end: CelestialCoordinate(ra: 17.5369, dec: 86.5863), // Yildun
        startStarName: 'Polaris',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.5369, dec: 86.5863), // Yildun
        end: CelestialCoordinate(ra: 16.2917, dec: 75.7555), // Epsilon UMi
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.2917, dec: 75.7555), // Epsilon UMi
        end: CelestialCoordinate(ra: 15.7345, dec: 77.7945), // Zeta UMi
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.7345, dec: 77.7945), // Zeta UMi
        end: CelestialCoordinate(ra: 14.8451, dec: 74.1554), // Kochab
        endStarName: 'Kochab',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.8451, dec: 74.1554), // Kochab
        end: CelestialCoordinate(ra: 15.3453, dec: 71.8340), // Pherkad
        endStarName: 'Pherkad',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.3453, dec: 71.8340), // Pherkad
        end: CelestialCoordinate(ra: 16.2917, dec: 75.7555), // Epsilon UMi
      ),
    ],
  ),
];
