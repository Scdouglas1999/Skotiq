part of '../../constellation_data.dart';

const _lineFigureSet02 = <ConstellationData>[
  // Draco
  ConstellationData(
    abbreviation: 'Dra',
    name: 'Draco',
    center: CelestialCoordinate(ra: 15.0, dec: 65),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.5074, dec: 52.3014), // Eltanin
        end: CelestialCoordinate(ra: 17.5073, dec: 51.4890), // Rastaban
        startStarName: 'Eltanin',
        endStarName: 'Rastaban',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.5073, dec: 51.4890), // Rastaban
        end: CelestialCoordinate(ra: 17.1465, dec: 54.4689), // Grumium
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.1465, dec: 54.4689), // Grumium
        end: CelestialCoordinate(ra: 16.4010, dec: 61.5142), // Nu Dra
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.4010, dec: 61.5142), // Nu Dra
        end: CelestialCoordinate(ra: 15.4155, dec: 58.9660), // Chi Dra
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.4155, dec: 58.9660), // Chi Dra
        end: CelestialCoordinate(ra: 14.0732, dec: 64.3758), // Thuban
        endStarName: 'Thuban',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.0732, dec: 64.3758), // Thuban
        end: CelestialCoordinate(ra: 12.5580, dec: 69.7882), // Kappa Dra
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.5580, dec: 69.7882), // Kappa Dra
        end: CelestialCoordinate(ra: 11.5233, dec: 69.3311), // Alpha Dra
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.5074, dec: 52.3014), // Eltanin
        end: CelestialCoordinate(ra: 17.1465, dec: 54.4689), // Grumium
      ),
    ],
  ),

  // Cepheus
  ConstellationData(
    abbreviation: 'Cep',
    name: 'Cepheus',
    center: CelestialCoordinate(ra: 22.0, dec: 65),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 21.3097, dec: 62.5856), // Alderamin
        end: CelestialCoordinate(ra: 23.6557, dec: 77.6323), // Errai
        startStarName: 'Alderamin',
        endStarName: 'Errai',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.6557, dec: 77.6323), // Errai
        end: CelestialCoordinate(ra: 23.1888, dec: 75.3875), // Iota Cep
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.1888, dec: 75.3875), // Iota Cep
        end: CelestialCoordinate(ra: 22.4868, dec: 58.2012), // Zeta Cep
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.4868, dec: 58.2012), // Zeta Cep
        end: CelestialCoordinate(ra: 21.3097, dec: 62.5856), // Alderamin
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.4868, dec: 58.2012), // Zeta Cep
        end: CelestialCoordinate(ra: 22.8282, dec: 66.2007), // Delta Cep
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.8282, dec: 66.2007), // Delta Cep
        end: CelestialCoordinate(ra: 23.1888, dec: 75.3875), // Iota Cep
      ),
    ],
  ),

  // Sagittarius
  ConstellationData(
    abbreviation: 'Sgr',
    name: 'Sagittarius',
    center: CelestialCoordinate(ra: 19.0, dec: -28),
    lines: [
      // Teapot body
      ConstellationLine(
        start: CelestialCoordinate(
          ra: 18.4029,
          dec: -34.3844,
        ), // Kaus Australis
        end: CelestialCoordinate(ra: 18.3498, dec: -29.8282), // Kaus Media
        startStarName: 'Kaus Australis',
        endStarName: 'Kaus Media',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.3498, dec: -29.8282), // Kaus Media
        end: CelestialCoordinate(ra: 18.2296, dec: -25.4217), // Kaus Borealis
        endStarName: 'Kaus Borealis',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.2296, dec: -25.4217), // Kaus Borealis
        end: CelestialCoordinate(ra: 18.9210, dec: -26.2967), // Nunki
        endStarName: 'Nunki',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.9210, dec: -26.2967), // Nunki
        end: CelestialCoordinate(ra: 19.1632, dec: -27.6698), // Tau Sgr
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.1632, dec: -27.6698), // Tau Sgr
        end: CelestialCoordinate(ra: 19.0434, dec: -29.8801), // Ascella
        endStarName: 'Ascella',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 19.0434, dec: -29.8801), // Ascella
        end: CelestialCoordinate(ra: 18.4029, dec: -34.3844), // Kaus Australis
      ),
      // Lid
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.2296, dec: -25.4217), // Kaus Borealis
        end: CelestialCoordinate(ra: 18.7608, dec: -26.9907), // Phi Sgr
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.7608, dec: -26.9907), // Phi Sgr
        end: CelestialCoordinate(ra: 18.9210, dec: -26.2967), // Nunki
      ),
      // Handle (spout)
      ConstellationLine(
        start: CelestialCoordinate(
          ra: 18.4029,
          dec: -34.3844,
        ), // Kaus Australis
        end: CelestialCoordinate(ra: 18.2965, dec: -36.7615), // Eta Sgr
      ),
    ],
  ),

  // Capricornus
  ConstellationData(
    abbreviation: 'Cap',
    name: 'Capricornus',
    center: CelestialCoordinate(ra: 21.0, dec: -18),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.2940, dec: -12.5082), // Algedi
        end: CelestialCoordinate(ra: 20.3502, dec: -14.7815), // Dabih
        startStarName: 'Algedi',
        endStarName: 'Dabih',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.3502, dec: -14.7815), // Dabih
        end: CelestialCoordinate(ra: 21.0991, dec: -17.2327), // Psi Cap
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 21.0991, dec: -17.2327), // Psi Cap
        end: CelestialCoordinate(ra: 21.3716, dec: -16.8344), // Deneb Algedi
        endStarName: 'Deneb Algedi',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 21.3716, dec: -16.8344), // Deneb Algedi
        end: CelestialCoordinate(ra: 21.6180, dec: -16.6617), // Nashira
        endStarName: 'Nashira',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 21.6180, dec: -16.6617), // Nashira
        end: CelestialCoordinate(ra: 21.4444, dec: -22.4115), // Zeta Cap
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 21.4444, dec: -22.4115), // Zeta Cap
        end: CelestialCoordinate(ra: 20.7680, dec: -25.2710), // Omega Cap
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 20.7680, dec: -25.2710), // Omega Cap
        end: CelestialCoordinate(ra: 20.2940, dec: -12.5082), // Algedi
      ),
    ],
  ),

  // Aquarius
  ConstellationData(
    abbreviation: 'Aqr',
    name: 'Aquarius',
    center: CelestialCoordinate(ra: 22.3, dec: -10),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.0965, dec: -0.3197), // Sadalsuud
        end: CelestialCoordinate(ra: 22.3614, dec: -1.3875), // Sadalmelik
        startStarName: 'Sadalsuud',
        endStarName: 'Sadalmelik',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.3614, dec: -1.3875), // Sadalmelik
        end: CelestialCoordinate(ra: 22.4806, dec: -0.0198), // Eta Aqr
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.4806, dec: -0.0198), // Eta Aqr
        end: CelestialCoordinate(ra: 22.8770, dec: -7.5799), // Lambda Aqr
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.8770, dec: -7.5799), // Lambda Aqr
        end: CelestialCoordinate(ra: 22.5906, dec: -13.5925), // Tau2 Aqr
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.5906, dec: -13.5925), // Tau2 Aqr
        end: CelestialCoordinate(
          ra: 22.8264,
          dec: -13.5924,
        ), // Delta Aqr (Skat)
        endStarName: 'Skat',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 22.8770, dec: -7.5799), // Lambda Aqr
        end: CelestialCoordinate(ra: 22.8264, dec: -13.5924), // Skat
      ),
    ],
  ),

  // Pisces
  ConstellationData(
    abbreviation: 'Psc',
    name: 'Pisces',
    center: CelestialCoordinate(ra: 0.5, dec: 12),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 2.0340, dec: 2.7636), // Eta Psc
        end: CelestialCoordinate(ra: 1.5247, dec: 15.3458), // Omicron Psc
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.5247, dec: 15.3458), // Omicron Psc
        end: CelestialCoordinate(
          ra: 1.6905,
          dec: 19.2934,
        ), // Alpha Psc (Alrescha)
        endStarName: 'Alrescha',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.6905, dec: 19.2934), // Alrescha
        end: CelestialCoordinate(ra: 1.0496, dec: 21.4716), // Nu Psc
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.0496, dec: 21.4716), // Nu Psc
        end: CelestialCoordinate(ra: 0.8114, dec: 7.5853), // Delta Psc
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 0.8114, dec: 7.5853), // Delta Psc
        end: CelestialCoordinate(ra: 23.6659, dec: 5.6262), // Omega Psc
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.6659, dec: 5.6262), // Omega Psc
        end: CelestialCoordinate(ra: 23.4487, dec: 6.3790), // Iota Psc
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.4487, dec: 6.3790), // Iota Psc
        end: CelestialCoordinate(ra: 23.2860, dec: 3.2821), // Gamma Psc
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 23.2860, dec: 3.2821), // Gamma Psc
        end: CelestialCoordinate(ra: 23.4487, dec: 6.3790), // Iota Psc
      ),
    ],
  ),

  // Aries
  ConstellationData(
    abbreviation: 'Ari',
    name: 'Aries',
    center: CelestialCoordinate(ra: 2.5, dec: 22),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 2.1195, dec: 23.4624), // Hamal
        end: CelestialCoordinate(ra: 1.9106, dec: 20.8081), // Sheratan
        startStarName: 'Hamal',
        endStarName: 'Sheratan',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 1.9106, dec: 20.8081), // Sheratan
        end: CelestialCoordinate(ra: 1.8920, dec: 19.2940), // Mesarthim
        endStarName: 'Mesarthim',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 2.1195, dec: 23.4624), // Hamal
        end: CelestialCoordinate(ra: 2.8332, dec: 27.2607), // 41 Ari
      ),
    ],
  ),

  // Cancer
  ConstellationData(
    abbreviation: 'Cnc',
    name: 'Cancer',
    center: CelestialCoordinate(ra: 8.7, dec: 20),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 8.7447, dec: 18.1542), // Acubens
        end: CelestialCoordinate(ra: 8.7213, dec: 21.4686), // Delta Cnc
        startStarName: 'Acubens',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 8.7213, dec: 21.4686), // Delta Cnc
        end: CelestialCoordinate(ra: 8.2752, dec: 9.1857), // Iota Cnc
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 8.7213, dec: 21.4686), // Delta Cnc
        end: CelestialCoordinate(
          ra: 9.1843,
          dec: 22.0431,
        ), // Gamma Cnc (Asellus Borealis)
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 8.7447, dec: 18.1542), // Acubens
        end: CelestialCoordinate(ra: 8.9778, dec: 11.8577), // Beta Cnc (Tarf)
        endStarName: 'Tarf',
      ),
    ],
  ),

  // Libra
  ConstellationData(
    abbreviation: 'Lib',
    name: 'Libra',
    center: CelestialCoordinate(ra: 15.2, dec: -16),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.8461, dec: -16.0418), // Zubenelgenubi
        end: CelestialCoordinate(ra: 15.2832, dec: -9.3829), // Zubeneschamali
        startStarName: 'Zubenelgenubi',
        endStarName: 'Zubeneschamali',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.2832, dec: -9.3829), // Zubeneschamali
        end: CelestialCoordinate(ra: 15.5921, dec: -14.7894), // Gamma Lib
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.5921, dec: -14.7894), // Gamma Lib
        end: CelestialCoordinate(ra: 14.8461, dec: -16.0418), // Zubenelgenubi
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.5921, dec: -14.7894), // Gamma Lib
        end: CelestialCoordinate(ra: 15.0681, dec: -25.2819), // Sigma Lib
      ),
    ],
  ),

  // Ophiuchus
  ConstellationData(
    abbreviation: 'Oph',
    name: 'Ophiuchus',
    center: CelestialCoordinate(ra: 17.3, dec: -4),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.5822, dec: 12.5600), // Rasalhague
        end: CelestialCoordinate(ra: 17.7243, dec: 4.5674), // Cebalrai
        startStarName: 'Rasalhague',
        endStarName: 'Cebalrai',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.7243, dec: 4.5674), // Cebalrai
        end: CelestialCoordinate(ra: 17.1726, dec: -15.7249), // Eta Oph
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.1726, dec: -15.7249), // Eta Oph
        end: CelestialCoordinate(ra: 16.6190, dec: -10.5671), // Zeta Oph
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.6190, dec: -10.5671), // Zeta Oph
        end: CelestialCoordinate(
          ra: 16.3052,
          dec: -4.6925,
        ), // Delta Oph (Yed Prior)
        endStarName: 'Yed Prior',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.3052, dec: -4.6925), // Yed Prior
        end: CelestialCoordinate(ra: 17.5822, dec: 12.5600), // Rasalhague
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.1726, dec: -15.7249), // Eta Oph
        end: CelestialCoordinate(ra: 17.7981, dec: -24.9996), // Theta Oph
      ),
    ],
  ),

  // Serpens (Caput + Cauda as one)
  ConstellationData(
    abbreviation: 'Ser',
    name: 'Serpens',
    center: CelestialCoordinate(ra: 16.0, dec: 6),
    lines: [
      // Serpens Caput (head)
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.7378, dec: 6.4254), // Unukalhai
        end: CelestialCoordinate(ra: 15.8120, dec: 15.4218), // Beta Ser
        startStarName: 'Unukalhai',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.8120, dec: 15.4218), // Beta Ser
        end: CelestialCoordinate(ra: 15.5802, dec: 15.6618), // Gamma Ser
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.7378, dec: 6.4254), // Unukalhai
        end: CelestialCoordinate(ra: 15.9423, dec: 3.4335), // Delta Ser
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 15.9423, dec: 3.4335), // Delta Ser
        end: CelestialCoordinate(ra: 15.8470, dec: 4.4776), // Epsilon Ser
      ),
      // Serpens Cauda (tail)
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.3553, dec: -2.8987), // Eta Ser
        end: CelestialCoordinate(ra: 18.9367, dec: 4.2037), // Theta1 Ser
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 18.9367, dec: 4.2037), // Theta1 Ser
        end: CelestialCoordinate(ra: 18.3553, dec: -2.8987), // Eta Ser
      ),
    ],
  ),

  // Hercules
  ConstellationData(
    abbreviation: 'Her',
    name: 'Hercules',
    center: CelestialCoordinate(ra: 17.4, dec: 27),
    lines: [
      // Keystone
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.5034, dec: 21.4897), // Zeta Her
        end: CelestialCoordinate(ra: 16.3649, dec: 19.1530), // Eta Her
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.3649, dec: 19.1530), // Eta Her
        end: CelestialCoordinate(ra: 17.2508, dec: 24.8392), // Pi Her
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.2508, dec: 24.8392), // Pi Her
        end: CelestialCoordinate(ra: 16.6880, dec: 31.6028), // Epsilon Her
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.6880, dec: 31.6028), // Epsilon Her
        end: CelestialCoordinate(ra: 16.5034, dec: 21.4897), // Zeta Her
      ),
      // Arms and legs
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.5034, dec: 21.4897), // Zeta Her
        end: CelestialCoordinate(
          ra: 16.1464,
          dec: 14.0333,
        ), // Beta Her (Kornephoros)
        endStarName: 'Kornephoros',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.3649, dec: 19.1530), // Eta Her
        end: CelestialCoordinate(ra: 17.2442, dec: 14.3902), // Sarin
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 17.2508, dec: 24.8392), // Pi Her
        end: CelestialCoordinate(
          ra: 17.5822,
          dec: 12.5600,
        ), // Rasalhague (shared with Oph)
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 16.6880, dec: 31.6028), // Epsilon Her
        end: CelestialCoordinate(
          ra: 17.3941,
          dec: 37.1459,
        ), // Alpha Her (Rasalgethi)
        endStarName: 'Rasalgethi',
      ),
    ],
  ),

  // Auriga
  ConstellationData(
    abbreviation: 'Aur',
    name: 'Auriga',
    center: CelestialCoordinate(ra: 6.0, dec: 42),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.2783, dec: 45.9981), // Capella
        end: CelestialCoordinate(ra: 5.9953, dec: 44.9474), // Menkalinan
        startStarName: 'Capella',
        endStarName: 'Menkalinan',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.9953, dec: 44.9474), // Menkalinan
        end: CelestialCoordinate(ra: 5.9920, dec: 37.2126), // Theta Aur
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.9920, dec: 37.2126), // Theta Aur
        end: CelestialCoordinate(
          ra: 5.4382,
          dec: 28.6074,
        ), // Elnath (shared w/ Tau)
        endStarName: 'Elnath',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.4382, dec: 28.6074), // Elnath
        end: CelestialCoordinate(ra: 5.0331, dec: 33.1661), // Iota Aur
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.0331, dec: 33.1661), // Iota Aur
        end: CelestialCoordinate(
          ra: 5.1089,
          dec: 41.2346,
        ), // Epsilon Aur (Almaaz)
        endStarName: 'Almaaz',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 5.1089, dec: 41.2346), // Almaaz
        end: CelestialCoordinate(ra: 5.2783, dec: 45.9981), // Capella
      ),
    ],
  ),

  // Canis Minor
  ConstellationData(
    abbreviation: 'CMi',
    name: 'Canis Minor',
    center: CelestialCoordinate(ra: 7.6, dec: 6),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 7.6553, dec: 5.2250), // Procyon
        end: CelestialCoordinate(ra: 7.4527, dec: 8.2893), // Gomeisa
        startStarName: 'Procyon',
        endStarName: 'Gomeisa',
      ),
    ],
  ),

  // Corvus
  ConstellationData(
    abbreviation: 'Crv',
    name: 'Corvus',
    center: CelestialCoordinate(ra: 12.3, dec: -18),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.4977, dec: -23.3968), // Gienah
        end: CelestialCoordinate(ra: 12.5735, dec: -16.5159), // Gamma Crv
        startStarName: 'Gienah',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.5735, dec: -16.5159), // Gamma Crv
        end: CelestialCoordinate(ra: 12.1685, dec: -22.6197), // Beta Crv (Kraz)
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.1685, dec: -22.6197), // Kraz
        end: CelestialCoordinate(ra: 12.4977, dec: -23.3968), // Gienah
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.1685, dec: -22.6197), // Kraz
        end: CelestialCoordinate(ra: 12.1398, dec: -24.7289), // Epsilon Crv
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.4977, dec: -23.3968), // Gienah
        end: CelestialCoordinate(ra: 12.1398, dec: -24.7289), // Epsilon Crv
      ),
    ],
  ),

  // Crater
  ConstellationData(
    abbreviation: 'Crt',
    name: 'Crater',
    center: CelestialCoordinate(ra: 11.3, dec: -15),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(
          ra: 10.9965,
          dec: -18.2989,
        ), // Alpha Crt (Alkes)
        end: CelestialCoordinate(ra: 11.1943, dec: -22.8264), // Beta Crt
        startStarName: 'Alkes',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 11.1943, dec: -22.8264), // Beta Crt
        end: CelestialCoordinate(ra: 11.4148, dec: -17.6840), // Gamma Crt
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 11.4148, dec: -17.6840), // Gamma Crt
        end: CelestialCoordinate(ra: 11.3225, dec: -14.7785), // Delta Crt
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 11.3225, dec: -14.7785), // Delta Crt
        end: CelestialCoordinate(ra: 10.9965, dec: -18.2989), // Alkes
      ),
    ],
  ),

  // Centaurus
  ConstellationData(
    abbreviation: 'Cen',
    name: 'Centaurus',
    center: CelestialCoordinate(ra: 13.5, dec: -47),
    lines: [
      ConstellationLine(
        start: CelestialCoordinate(
          ra: 14.6599,
          dec: -60.8353,
        ), // Alpha Cen (Rigil Kentaurus)
        end: CelestialCoordinate(
          ra: 14.0637,
          dec: -60.3730,
        ), // Beta Cen (Hadar)
        startStarName: 'Rigil Kentaurus',
        endStarName: 'Hadar',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 14.0637, dec: -60.3730), // Hadar
        end: CelestialCoordinate(ra: 13.6648, dec: -53.4664), // Epsilon Cen
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 13.6648, dec: -53.4664), // Epsilon Cen
        end: CelestialCoordinate(ra: 12.6917, dec: -48.9597), // Gamma Cen
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 12.6917, dec: -48.9597), // Gamma Cen
        end: CelestialCoordinate(
          ra: 14.1114,
          dec: -36.3700,
        ), // Theta Cen (Menkent)
        endStarName: 'Menkent',
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 13.6648, dec: -53.4664), // Epsilon Cen
        end: CelestialCoordinate(ra: 13.9253, dec: -47.2884), // Zeta Cen
      ),
      ConstellationLine(
        start: CelestialCoordinate(ra: 13.9253, dec: -47.2884), // Zeta Cen
        end: CelestialCoordinate(ra: 14.1114, dec: -36.3700), // Menkent
      ),
    ],
  ),
];
