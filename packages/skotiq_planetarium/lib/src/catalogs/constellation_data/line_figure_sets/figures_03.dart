part of '../../constellation_data.dart';

const _lineFigureSet03 = <ConstellationData>[
  // Lupus
  ConstellationData(
    abbreviation: 'Lup',
    name: 'Lupus',
    center: CelestialCoordinate(ra: 15.3, dec: -42),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.6985, dec: -47.3884), // Alpha Lup
        end: CelestialCoordinate(ra: 14.9758, dec: -43.1340), // Beta Lup
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.9758, dec: -43.1340), // Beta Lup
        end: CelestialCoordinate(ra: 15.3560, dec: -40.6474), // Gamma Lup
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.3560, dec: -40.6474), // Gamma Lup
        end: CelestialCoordinate(ra: 15.5856, dec: -41.1668), // Delta Lup
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.5856, dec: -41.1668), // Delta Lup
        end: CelestialCoordinate(ra: 15.3783, dec: -44.6896), // Epsilon Lup
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.3783, dec: -44.6896), // Epsilon Lup
        end: CelestialCoordinate(ra: 14.6985, dec: -47.3884), // Alpha Lup
      ),
    ],
  ),

  // Corona Borealis
  ConstellationData(
    abbreviation: 'CrB',
    name: 'Corona Borealis',
    center: CelestialCoordinate(ra: 15.9, dec: 30),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.5780, dec: 26.7147), // Alphecca
        end: CelestialCoordinate(ra: 15.4630, dec: 29.1057), // Nusakan
        startStarName: 'Alphecca',
        endStarName: 'Nusakan',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.4630, dec: 29.1057), // Nusakan
        end: CelestialCoordinate(ra: 15.7126, dec: 31.3592), // Theta CrB
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.5780, dec: 26.7147), // Alphecca
        end: CelestialCoordinate(ra: 15.9899, dec: 26.8779), // Gamma CrB
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.9899, dec: 26.8779), // Gamma CrB
        end: CelestialCoordinate(ra: 16.0240, dec: 29.8511), // Delta CrB
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.0240, dec: 29.8511), // Delta CrB
        end: CelestialCoordinate(ra: 15.9592, dec: 30.2882), // Epsilon CrB
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.9592, dec: 30.2882), // Epsilon CrB
        end: CelestialCoordinate(ra: 15.7126, dec: 31.3592), // Theta CrB
      ),
    ],
  ),

  // Coma Berenices
  ConstellationData(
    abbreviation: 'Com',
    name: 'Coma Berenices',
    center: CelestialCoordinate(ra: 12.8, dec: 23),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(
          ra: 13.1664,
          dec: 17.5293,
        ), // Alpha Com (Diadem)
        end: CelestialCoordinate(ra: 13.1979, dec: 27.8781), // Beta Com
        startStarName: 'Diadem',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 13.1979, dec: 27.8781), // Beta Com
        end: CelestialCoordinate(ra: 12.4491, dec: 28.2685), // Gamma Com
      ),
    ],
  ),

  // Canes Venatici
  ConstellationData(
    abbreviation: 'CVn',
    name: 'Canes Venatici',
    center: CelestialCoordinate(ra: 13.1, dec: 40),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.9338, dec: 38.3183), // Cor Caroli
        end: CelestialCoordinate(ra: 12.5624, dec: 41.3574), // Chara
        startStarName: 'Cor Caroli',
        endStarName: 'Chara',
      ),
    ],
  ),

  // Triangulum
  ConstellationData(
    abbreviation: 'Tri',
    name: 'Triangulum',
    center: CelestialCoordinate(ra: 2.2, dec: 32),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(
          ra: 1.8853,
          dec: 29.5789,
        ), // Alpha Tri (Mothallah)
        end: CelestialCoordinate(ra: 2.1591, dec: 34.9872), // Beta Tri
        startStarName: 'Mothallah',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 2.1591, dec: 34.9872), // Beta Tri
        end: CelestialCoordinate(ra: 2.2886, dec: 33.8473), // Gamma Tri
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 2.2886, dec: 33.8473), // Gamma Tri
        end: CelestialCoordinate(ra: 1.8853, dec: 29.5789), // Alpha Tri
      ),
    ],
  ),

  // Sagitta
  ConstellationData(
    abbreviation: 'Sge',
    name: 'Sagitta',
    center: CelestialCoordinate(ra: 19.8, dec: 18.5),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.6790, dec: 18.0139), // Gamma Sge
        end: CelestialCoordinate(ra: 19.7894, dec: 18.5340), // Delta Sge
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.7894, dec: 18.5340), // Delta Sge
        end: CelestialCoordinate(ra: 19.9838, dec: 19.4920), // Alpha Sge (Sham)
        endStarName: 'Sham',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.6790, dec: 18.0139), // Gamma Sge
        end: CelestialCoordinate(ra: 19.6844, dec: 17.4763), // Beta Sge
      ),
    ],
  ),

  // Vulpecula
  ConstellationData(
    abbreviation: 'Vul',
    name: 'Vulpecula',
    center: CelestialCoordinate(ra: 20.2, dec: 25),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(
          ra: 19.4784,
          dec: 24.6650,
        ), // Alpha Vul (Anser)
        end: CelestialCoordinate(ra: 20.6337, dec: 27.7545), // 13 Vul
        startStarName: 'Anser',
      ),
    ],
  ),

  // Delphinus
  ConstellationData(
    abbreviation: 'Del',
    name: 'Delphinus',
    center: CelestialCoordinate(ra: 20.7, dec: 13),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.6259, dec: 14.5952), // Sualocin
        end: CelestialCoordinate(ra: 20.5537, dec: 11.3032), // Rotanev
        startStarName: 'Sualocin',
        endStarName: 'Rotanev',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.5537, dec: 11.3032), // Rotanev
        end: CelestialCoordinate(ra: 20.7243, dec: 15.0746), // Gamma Del
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.7243, dec: 15.0746), // Gamma Del
        end: CelestialCoordinate(ra: 20.7763, dec: 16.1243), // Delta Del
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.7763, dec: 16.1243), // Delta Del
        end: CelestialCoordinate(ra: 20.6259, dec: 14.5952), // Sualocin
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.7763, dec: 16.1243), // Delta Del
        end: CelestialCoordinate(
          ra: 20.6240,
          dec: 11.3714,
        ), // Epsilon Del (tail)
      ),
    ],
  ),

  // Equuleus
  ConstellationData(
    abbreviation: 'Equ',
    name: 'Equuleus',
    center: CelestialCoordinate(ra: 21.2, dec: 8),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(
          ra: 21.1726,
          dec: 10.0063,
        ), // Alpha Equ (Kitalpha)
        end: CelestialCoordinate(ra: 21.2415, dec: 6.8112), // Delta Equ
        startStarName: 'Kitalpha',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 21.2415, dec: 6.8112), // Delta Equ
        end: CelestialCoordinate(ra: 21.2635, dec: 5.2481), // Gamma Equ
      ),
    ],
  ),

  // Lacerta
  ConstellationData(
    abbreviation: 'Lac',
    name: 'Lacerta',
    center: CelestialCoordinate(ra: 22.5, dec: 45),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.5216, dec: 50.2825), // Alpha Lac
        end: CelestialCoordinate(ra: 22.3925, dec: 46.5365), // Beta Lac
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.3925, dec: 46.5365), // Beta Lac
        end: CelestialCoordinate(ra: 22.4082, dec: 43.1233), // 4 Lac
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.4082, dec: 43.1233), // 4 Lac
        end: CelestialCoordinate(ra: 22.4920, dec: 39.6477), // 5 Lac
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.4920, dec: 39.6477), // 5 Lac
        end: CelestialCoordinate(ra: 22.3502, dec: 37.7489), // 1 Lac
      ),
    ],
  ),

  // Eridanus
  ConstellationData(
    abbreviation: 'Eri',
    name: 'Eridanus',
    center: CelestialCoordinate(ra: 3.3, dec: -29),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.6286, dec: -57.2367), // Achernar
        end: CelestialCoordinate(ra: 2.9710, dec: -40.3047), // Acamar
        startStarName: 'Achernar',
        endStarName: 'Acamar',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 2.9710, dec: -40.3047), // Acamar
        end: CelestialCoordinate(ra: 3.5490, dec: -21.6328), // Zaurak
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 3.5490, dec: -21.6328), // Zaurak
        end: CelestialCoordinate(
          ra: 3.7210,
          dec: -12.1019,
        ), // Epsilon Eri (Ran)
        endStarName: 'Ran',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 3.7210, dec: -12.1019), // Ran
        end: CelestialCoordinate(ra: 4.7580, dec: -3.2543), // Delta Eri
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 4.7580, dec: -3.2543), // Delta Eri
        end: CelestialCoordinate(ra: 5.1308, dec: -5.0863), // Cursa
        endStarName: 'Cursa',
      ),
    ],
  ),

  // Fornax
  ConstellationData(
    abbreviation: 'For',
    name: 'Fornax',
    center: CelestialCoordinate(ra: 2.8, dec: -30),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(
          ra: 3.2013,
          dec: -28.9877,
        ), // Alpha For (Dalim)
        end: CelestialCoordinate(ra: 2.8182, dec: -32.4059), // Beta For
        startStarName: 'Dalim',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 2.8182, dec: -32.4059), // Beta For
        end: CelestialCoordinate(ra: 2.0747, dec: -29.2967), // Nu For
      ),
    ],
  ),

  // Sculptor
  ConstellationData(
    abbreviation: 'Scl',
    name: 'Sculptor',
    center: CelestialCoordinate(ra: 0.5, dec: -32),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.9764, dec: -29.3572), // Alpha Scl
        end: CelestialCoordinate(ra: 23.5497, dec: -28.1302), // Beta Scl
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.5497, dec: -28.1302), // Beta Scl
        end: CelestialCoordinate(ra: 23.3145, dec: -32.5320), // Gamma Scl
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.3145, dec: -32.5320), // Gamma Scl
        end: CelestialCoordinate(ra: 23.8153, dec: -28.1302), // Delta Scl
      ),
    ],
  ),

  // Cetus
  ConstellationData(
    abbreviation: 'Cet',
    name: 'Cetus',
    center: CelestialCoordinate(ra: 1.7, dec: -10),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.7265, dec: -17.9866), // Deneb Kaitos
        end: CelestialCoordinate(ra: 1.1432, dec: -10.1822), // Iota Cet
        startStarName: 'Deneb Kaitos',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.1432, dec: -10.1822), // Iota Cet
        end: CelestialCoordinate(ra: 1.7340, dec: -15.9376), // Eta Cet
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.7340, dec: -15.9376), // Eta Cet
        end: CelestialCoordinate(ra: 0.7265, dec: -17.9866), // Deneb Kaitos
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.1432, dec: -10.1822), // Iota Cet
        end: CelestialCoordinate(ra: 2.3222, dec: -2.9776), // Mira
        endStarName: 'Mira',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 2.3222, dec: -2.9776), // Mira
        end: CelestialCoordinate(ra: 3.0382, dec: 4.0897), // Menkar
        endStarName: 'Menkar',
      ),
    ],
  ),

  // Phoenix
  ConstellationData(
    abbreviation: 'Phe',
    name: 'Phoenix',
    center: CelestialCoordinate(ra: 0.9, dec: -48),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.4382, dec: -42.3061), // Ankaa
        end: CelestialCoordinate(ra: 1.1013, dec: -46.7185), // Beta Phe
        startStarName: 'Ankaa',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.1013, dec: -46.7185), // Beta Phe
        end: CelestialCoordinate(ra: 1.4728, dec: -43.3186), // Gamma Phe
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.4728, dec: -43.3186), // Gamma Phe
        end: CelestialCoordinate(ra: 0.4382, dec: -42.3061), // Ankaa
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.1013, dec: -46.7185), // Beta Phe
        end: CelestialCoordinate(ra: 1.5207, dec: -49.0728), // Epsilon Phe
      ),
    ],
  ),

  // Grus
  ConstellationData(
    abbreviation: 'Gru',
    name: 'Grus',
    center: CelestialCoordinate(ra: 22.5, dec: -45),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.1372, dec: -46.9609), // Alnair
        end: CelestialCoordinate(ra: 22.4877, dec: -43.4956), // Beta Gru
        startStarName: 'Alnair',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.4877, dec: -43.4956), // Beta Gru
        end: CelestialCoordinate(ra: 22.7111, dec: -46.8847), // Delta1 Gru
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.7111, dec: -46.8847), // Delta1 Gru
        end: CelestialCoordinate(ra: 22.1372, dec: -46.9609), // Alnair
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.4877, dec: -43.4956), // Beta Gru
        end: CelestialCoordinate(ra: 23.0146, dec: -45.2464), // Epsilon Gru
      ),
    ],
  ),

  // Pavo
  ConstellationData(
    abbreviation: 'Pav',
    name: 'Pavo',
    center: CelestialCoordinate(ra: 19.6, dec: -63),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.4275, dec: -56.7351), // Peacock
        end: CelestialCoordinate(ra: 20.0093, dec: -66.2031), // Beta Pav
        startStarName: 'Peacock',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.0093, dec: -66.2031), // Beta Pav
        end: CelestialCoordinate(ra: 18.7170, dec: -71.4280), // Delta Pav
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.7170, dec: -71.4280), // Delta Pav
        end: CelestialCoordinate(ra: 17.7628, dec: -64.7235), // Eta Pav
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.7628, dec: -64.7235), // Eta Pav
        end: CelestialCoordinate(ra: 20.4275, dec: -56.7351), // Peacock
      ),
    ],
  ),

  // Tucana
  ConstellationData(
    abbreviation: 'Tuc',
    name: 'Tucana',
    center: CelestialCoordinate(ra: 23.8, dec: -65),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.3085, dec: -60.2596), // Alpha Tuc
        end: CelestialCoordinate(ra: 23.2905, dec: -58.2358), // Gamma Tuc
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.2905, dec: -58.2358), // Gamma Tuc
        end: CelestialCoordinate(ra: 0.5256, dec: -62.9581), // Beta1 Tuc
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.5256, dec: -62.9581), // Beta1 Tuc
        end: CelestialCoordinate(ra: 22.3085, dec: -60.2596), // Alpha Tuc
      ),
    ],
  ),

  // Indus
  ConstellationData(
    abbreviation: 'Ind',
    name: 'Indus',
    center: CelestialCoordinate(ra: 21.5, dec: -55),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.6263, dec: -47.2915), // Alpha Ind
        end: CelestialCoordinate(ra: 20.9131, dec: -58.4542), // Beta Ind
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.9131, dec: -58.4542), // Beta Ind
        end: CelestialCoordinate(ra: 21.3312, dec: -53.4493), // Theta Ind
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 21.3312, dec: -53.4493), // Theta Ind
        end: CelestialCoordinate(ra: 20.6263, dec: -47.2915), // Alpha Ind
      ),
    ],
  ),

  // Microscopium
  ConstellationData(
    abbreviation: 'Mic',
    name: 'Microscopium',
    center: CelestialCoordinate(ra: 21.0, dec: -36),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.8329, dec: -33.7797), // Gamma Mic
        end: CelestialCoordinate(ra: 21.2990, dec: -32.1726), // Epsilon Mic
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 21.2990, dec: -32.1726), // Epsilon Mic
        end: CelestialCoordinate(ra: 21.0210, dec: -41.3869), // Alpha Mic
      ),
    ],
  ),

  // Piscis Austrinus
  ConstellationData(
    abbreviation: 'PsA',
    name: 'Piscis Austrinus',
    center: CelestialCoordinate(ra: 22.3, dec: -31),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.9607, dec: -29.6222), // Fomalhaut
        end: CelestialCoordinate(ra: 22.5254, dec: -32.3460), // Epsilon PsA
        startStarName: 'Fomalhaut',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.5254, dec: -32.3460), // Epsilon PsA
        end: CelestialCoordinate(ra: 22.1407, dec: -32.9884), // Delta PsA
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.1407, dec: -32.9884), // Delta PsA
        end: CelestialCoordinate(ra: 22.6779, dec: -27.0435), // Gamma PsA
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.6779, dec: -27.0435), // Gamma PsA
        end: CelestialCoordinate(ra: 22.9607, dec: -29.6222), // Fomalhaut
      ),
    ],
  ),

  // Ara
  ConstellationData(
    abbreviation: 'Ara',
    name: 'Ara',
    center: CelestialCoordinate(ra: 17.3, dec: -53),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.5307, dec: -49.8761), // Alpha Ara
        end: CelestialCoordinate(ra: 17.4216, dec: -55.5299), // Beta Ara
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.4216, dec: -55.5299), // Beta Ara
        end: CelestialCoordinate(ra: 17.2526, dec: -56.3776), // Gamma Ara
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.2526, dec: -56.3776), // Gamma Ara
        end: CelestialCoordinate(ra: 17.5181, dec: -60.6836), // Delta Ara
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.5307, dec: -49.8761), // Alpha Ara
        end: CelestialCoordinate(ra: 16.9776, dec: -55.9901), // Zeta Ara
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.9776, dec: -55.9901), // Zeta Ara
        end: CelestialCoordinate(ra: 17.2526, dec: -56.3776), // Gamma Ara
      ),
    ],
  ),

  // Corona Australis
  ConstellationData(
    abbreviation: 'CrA',
    name: 'Corona Australis',
    center: CelestialCoordinate(ra: 18.6, dec: -40),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(
          ra: 19.1579,
          dec: -37.9044,
        ), // Alpha CrA (Meridiana)
        end: CelestialCoordinate(ra: 19.1670, dec: -39.3407), // Beta CrA
        startStarName: 'Meridiana',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.1670, dec: -39.3407), // Beta CrA
        end: CelestialCoordinate(ra: 18.8125, dec: -43.6805), // Delta CrA
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.1579, dec: -37.9044), // Meridiana
        end: CelestialCoordinate(ra: 19.1068, dec: -37.0635), // Gamma CrA
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.1068, dec: -37.0635), // Gamma CrA
        end: CelestialCoordinate(ra: 18.9780, dec: -37.1071), // Epsilon CrA
      ),
    ],
  ),

  // Telescopium
  ConstellationData(
    abbreviation: 'Tel',
    name: 'Telescopium',
    center: CelestialCoordinate(ra: 18.3, dec: -50),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.4494, dec: -45.9685), // Alpha Tel
        end: CelestialCoordinate(ra: 18.4806, dec: -49.0704), // Zeta Tel
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.4806, dec: -49.0704), // Zeta Tel
        end: CelestialCoordinate(ra: 18.1870, dec: -45.9546), // Epsilon Tel
      ),
    ],
  ),

  // Norma
  ConstellationData(
    abbreviation: 'Nor',
    name: 'Norma',
    center: CelestialCoordinate(ra: 16.0, dec: -50),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.3297, dec: -50.1555), // Gamma2 Nor
        end: CelestialCoordinate(ra: 16.4536, dec: -47.5548), // Epsilon Nor
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.4536, dec: -47.5548), // Epsilon Nor
        end: CelestialCoordinate(ra: 16.1099, dec: -45.1731), // Eta Nor
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.1099, dec: -45.1731), // Eta Nor
        end: CelestialCoordinate(ra: 16.3297, dec: -50.1555), // Gamma2 Nor
      ),
    ],
  ),
];
