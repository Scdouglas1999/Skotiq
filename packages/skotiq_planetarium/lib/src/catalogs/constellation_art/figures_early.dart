// Orion through Lyra constellation-art payloads and the aggregate list.
part of '../constellation_art.dart';

final List<ConstellationArtData> _figures = [
  ..._earlyConstellationArtFigures,
  ..._lateConstellationArtFigures,
];

final List<ConstellationArtData> _earlyConstellationArtFigures = [
  // ORION — The Hunter
  // Anchor stars: Betelgeuse (5.92, 7.41), Bellatrix (5.42, 6.35),
  //   Mintaka (5.53, -0.30), Alnilam (5.60, -1.20), Alnitak (5.68, -1.94),
  //   Rigel (5.24, -8.20), Saiph (5.80, -9.67)
  // Figure: upright human figure — head, shoulders, belt, legs, raised arm
  ConstellationArtData(
    abbreviation: 'Ori',
    segments: [
      // Head (small circle approximated by quad arcs above shoulders)
      ArtMoveTo(ConstellationArt._c(5.67, 10.5)),
      ArtQuadTo(
        ConstellationArt._c(5.85, 11.5),
        ConstellationArt._c(5.67, 12.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(5.50, 11.5),
        ConstellationArt._c(5.67, 10.5),
      ),
      const ArtClose(),
      // Torso: shoulders → belt → hips
      ArtMoveTo(ConstellationArt._c(5.42, 6.35)), // Bellatrix (left shoulder)
      ArtLineTo(ConstellationArt._c(5.92, 7.41)), // Betelgeuse (right shoulder)
      ArtLineTo(ConstellationArt._c(5.92, 5.0)), // right armpit
      ArtLineTo(ConstellationArt._c(5.68, -1.94)), // Alnitak (right belt)
      ArtLineTo(ConstellationArt._c(5.80, -4.5)), // right hip
      ArtLineTo(ConstellationArt._c(5.48, -4.5)), // left hip
      ArtLineTo(ConstellationArt._c(5.53, -0.30)), // Mintaka (left belt)
      ArtLineTo(ConstellationArt._c(5.42, 5.0)), // left armpit
      const ArtClose(),
      // Left leg (Mintaka side → Rigel)
      ArtMoveTo(ConstellationArt._c(5.48, -4.5)),
      ArtLineTo(ConstellationArt._c(5.30, -5.5)),
      ArtLineTo(ConstellationArt._c(5.24, -8.20)), // Rigel
      ArtLineTo(ConstellationArt._c(5.15, -8.50)),
      ArtLineTo(ConstellationArt._c(5.20, -5.2)),
      ArtLineTo(ConstellationArt._c(5.38, -4.5)),
      const ArtClose(),
      // Right leg (Alnitak side → Saiph)
      ArtMoveTo(ConstellationArt._c(5.80, -4.5)),
      ArtLineTo(ConstellationArt._c(5.88, -5.5)),
      ArtLineTo(ConstellationArt._c(5.80, -9.67)), // Saiph
      ArtLineTo(ConstellationArt._c(5.72, -9.97)),
      ArtLineTo(ConstellationArt._c(5.75, -5.2)),
      ArtLineTo(ConstellationArt._c(5.68, -4.5)),
      const ArtClose(),
      // Raised arm (club, from Betelgeuse up and right)
      ArtMoveTo(ConstellationArt._c(5.92, 7.41)), // Betelgeuse
      ArtLineTo(ConstellationArt._c(6.05, 9.0)),
      ArtLineTo(ConstellationArt._c(6.20, 14.0)),
      ArtLineTo(ConstellationArt._c(6.30, 16.0)),
      ArtLineTo(ConstellationArt._c(6.15, 16.5)),
      ArtLineTo(ConstellationArt._c(6.05, 14.5)),
      ArtLineTo(ConstellationArt._c(5.92, 9.5)),
      ArtLineTo(ConstellationArt._c(5.85, 7.8)),
      const ArtClose(),
      // Shield arm (from Bellatrix outward)
      ArtMoveTo(ConstellationArt._c(5.42, 6.35)), // Bellatrix
      ArtLineTo(ConstellationArt._c(5.20, 7.0)),
      ArtLineTo(ConstellationArt._c(5.05, 5.0)),
      ArtLineTo(ConstellationArt._c(4.95, 2.0)),
      ArtLineTo(ConstellationArt._c(4.90, -1.0)),
      ArtLineTo(ConstellationArt._c(5.05, -1.5)),
      ArtLineTo(ConstellationArt._c(5.10, 2.0)),
      ArtLineTo(ConstellationArt._c(5.18, 5.0)),
      ArtLineTo(ConstellationArt._c(5.32, 6.0)),
      const ArtClose(),
    ],
  ),

  // URSA MAJOR — The Great Bear
  // Anchor stars: Dubhe (11.06, 61.75), Merak (11.03, 56.38),
  //   Phecda (11.90, 53.69), Megrez (12.26, 57.03), Alioth (12.90, 55.96),
  //   Mizar (13.40, 54.93), Alkaid (13.79, 49.31)
  // Figure: bear body with long tail (the dipper handle)
  ConstellationArtData(
    abbreviation: 'UMa',
    segments: [
      // Bear body encompassing the bowl stars
      ArtMoveTo(ConstellationArt._c(10.50, 63.0)), // above Dubhe (head)
      ArtQuadTo(
        ConstellationArt._c(10.20, 60.0),
        ConstellationArt._c(10.30, 57.0),
      ), // snout
      ArtLineTo(ConstellationArt._c(10.50, 55.0)),
      ArtLineTo(ConstellationArt._c(10.80, 53.0)),
      ArtLineTo(ConstellationArt._c(11.50, 51.5)), // belly bottom
      ArtLineTo(ConstellationArt._c(12.20, 52.0)),
      ArtLineTo(ConstellationArt._c(12.50, 53.5)), // near Phecda
      // Tail starts — follows handle stars
      ArtLineTo(ConstellationArt._c(12.90, 54.5)), // near Alioth
      ArtLineTo(ConstellationArt._c(13.40, 53.5)), // near Mizar
      ArtLineTo(ConstellationArt._c(13.79, 49.31)), // Alkaid (tail tip)
      ArtLineTo(ConstellationArt._c(13.95, 49.0)), // tail tip outer edge
      ArtLineTo(ConstellationArt._c(13.55, 55.5)), // return along outer tail
      ArtLineTo(ConstellationArt._c(13.05, 56.5)),
      ArtLineTo(ConstellationArt._c(12.50, 58.0)), // back top
      ArtLineTo(ConstellationArt._c(12.26, 58.5)), // above Megrez
      ArtLineTo(ConstellationArt._c(11.40, 62.5)), // back to top of body
      ArtLineTo(ConstellationArt._c(11.06, 63.0)), // near Dubhe
      const ArtClose(),
      // Front legs
      ArtMoveTo(ConstellationArt._c(10.80, 53.0)),
      ArtLineTo(ConstellationArt._c(10.60, 50.0)),
      ArtLineTo(ConstellationArt._c(10.40, 48.5)),
      ArtLineTo(ConstellationArt._c(10.60, 48.0)),
      ArtLineTo(ConstellationArt._c(10.80, 50.5)),
      ArtLineTo(ConstellationArt._c(11.00, 52.0)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(11.20, 52.0)),
      ArtLineTo(ConstellationArt._c(11.10, 49.5)),
      ArtLineTo(ConstellationArt._c(10.90, 48.0)),
      ArtLineTo(ConstellationArt._c(11.10, 47.5)),
      ArtLineTo(ConstellationArt._c(11.30, 50.0)),
      ArtLineTo(ConstellationArt._c(11.50, 51.5)),
      const ArtClose(),
      // Hind legs
      ArtMoveTo(ConstellationArt._c(12.00, 52.5)),
      ArtLineTo(ConstellationArt._c(11.90, 49.5)),
      ArtLineTo(ConstellationArt._c(11.70, 48.0)),
      ArtLineTo(ConstellationArt._c(11.90, 47.5)),
      ArtLineTo(ConstellationArt._c(12.10, 50.0)),
      ArtLineTo(ConstellationArt._c(12.20, 52.0)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(12.40, 53.0)),
      ArtLineTo(ConstellationArt._c(12.40, 50.0)),
      ArtLineTo(ConstellationArt._c(12.20, 48.5)),
      ArtLineTo(ConstellationArt._c(12.40, 48.0)),
      ArtLineTo(ConstellationArt._c(12.60, 50.5)),
      ArtLineTo(ConstellationArt._c(12.60, 53.0)),
      const ArtClose(),
      // Ear
      ArtMoveTo(ConstellationArt._c(10.50, 63.0)),
      ArtLineTo(ConstellationArt._c(10.35, 64.0)),
      ArtLineTo(ConstellationArt._c(10.55, 63.8)),
      const ArtClose(),
    ],
  ),

  // CASSIOPEIA — The Queen (seated on throne)
  // Anchor stars: Caph (0.15, 59.15), Schedar (0.68, 56.54),
  //   Navi (0.95, 60.72), Ruchbah (1.43, 60.24), Segin (1.91, 63.67)
  // Figure: seated woman with arms raised, W-shape suggests throne back
  ConstellationArtData(
    abbreviation: 'Cas',
    segments: [
      // Torso (seated figure)
      ArtMoveTo(ConstellationArt._c(0.68, 58.0)), // above Schedar (chest)
      ArtLineTo(ConstellationArt._c(0.95, 62.0)), // near Navi (head area)
      ArtLineTo(ConstellationArt._c(1.10, 61.5)),
      ArtLineTo(ConstellationArt._c(0.85, 58.0)),
      ArtLineTo(ConstellationArt._c(0.85, 55.5)), // waist
      ArtLineTo(ConstellationArt._c(0.68, 55.0)),
      const ArtClose(),
      // Head
      ArtMoveTo(ConstellationArt._c(0.92, 62.5)),
      ArtQuadTo(
        ConstellationArt._c(1.05, 63.5),
        ConstellationArt._c(0.95, 64.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(0.82, 63.5),
        ConstellationArt._c(0.92, 62.5),
      ),
      const ArtClose(),
      // Left arm (toward Caph, raised)
      ArtMoveTo(ConstellationArt._c(0.68, 58.0)),
      ArtLineTo(ConstellationArt._c(0.40, 59.0)),
      ArtLineTo(ConstellationArt._c(0.15, 59.15)), // Caph
      ArtLineTo(ConstellationArt._c(0.10, 60.0)),
      ArtLineTo(ConstellationArt._c(0.35, 59.7)),
      ArtLineTo(ConstellationArt._c(0.60, 58.5)),
      const ArtClose(),
      // Right arm (toward Ruchbah/Segin, raised)
      ArtMoveTo(ConstellationArt._c(1.10, 61.5)),
      ArtLineTo(ConstellationArt._c(1.43, 60.24)), // Ruchbah
      ArtLineTo(ConstellationArt._c(1.91, 63.67)), // Segin
      ArtLineTo(ConstellationArt._c(2.00, 64.0)),
      ArtLineTo(ConstellationArt._c(1.50, 61.0)),
      ArtLineTo(ConstellationArt._c(1.15, 62.0)),
      const ArtClose(),
      // Throne seat (below Schedar)
      ArtMoveTo(ConstellationArt._c(0.50, 55.0)),
      ArtLineTo(ConstellationArt._c(0.50, 54.0)),
      ArtLineTo(ConstellationArt._c(1.10, 54.0)),
      ArtLineTo(ConstellationArt._c(1.10, 55.0)),
      const ArtClose(),
      // Legs
      ArtMoveTo(ConstellationArt._c(0.68, 55.0)),
      ArtLineTo(ConstellationArt._c(0.55, 53.5)),
      ArtLineTo(ConstellationArt._c(0.50, 52.0)),
      ArtLineTo(ConstellationArt._c(0.60, 51.8)),
      ArtLineTo(ConstellationArt._c(0.68, 53.5)),
      ArtLineTo(ConstellationArt._c(0.75, 55.0)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(0.85, 55.0)),
      ArtLineTo(ConstellationArt._c(0.90, 53.5)),
      ArtLineTo(ConstellationArt._c(0.95, 52.0)),
      ArtLineTo(ConstellationArt._c(1.05, 51.8)),
      ArtLineTo(ConstellationArt._c(1.00, 53.5)),
      ArtLineTo(ConstellationArt._c(0.92, 55.0)),
      const ArtClose(),
    ],
  ),

  // LEO — The Lion
  // Anchor stars: Regulus (10.14, 11.97), Algieba (10.12, 23.77),
  //   Zosma (10.28, 26.01), Denebola (11.82, 14.57), Chertan (11.24, 20.52)
  // Figure: crouching lion facing right, sickle = mane
  ConstellationArtData(
    abbreviation: 'Leo',
    segments: [
      // Head/mane (follows the sickle)
      ArtMoveTo(ConstellationArt._c(10.14, 11.97)), // Regulus
      ArtQuadTo(
        ConstellationArt._c(9.90, 14.0),
        ConstellationArt._c(9.80, 18.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(9.75, 22.0),
        ConstellationArt._c(10.12, 23.77),
      ), // Algieba
      ArtLineTo(ConstellationArt._c(10.28, 26.01)), // Zosma (top of mane)
      ArtQuadTo(
        ConstellationArt._c(10.50, 27.0),
        ConstellationArt._c(10.70, 26.0),
      ),
      ArtLineTo(ConstellationArt._c(10.50, 22.0)),
      ArtQuadTo(
        ConstellationArt._c(10.30, 17.0),
        ConstellationArt._c(10.40, 13.0),
      ),
      ArtLineTo(ConstellationArt._c(10.14, 11.97)), // back to Regulus
      const ArtClose(),
      // Body (from mane to Denebola)
      ArtMoveTo(ConstellationArt._c(10.28, 26.01)), // Zosma (start of back)
      ArtLineTo(ConstellationArt._c(10.70, 26.0)), // inner mane edge
      ArtQuadTo(
        ConstellationArt._c(11.00, 24.0),
        ConstellationArt._c(11.24, 20.52),
      ), // Chertan (mid-back)
      ArtLineTo(ConstellationArt._c(11.82, 14.57)), // Denebola (tail)
      ArtLineTo(ConstellationArt._c(12.00, 14.0)), // tail tip
      ArtLineTo(ConstellationArt._c(11.90, 13.0)),
      ArtLineTo(ConstellationArt._c(11.50, 12.5)), // belly
      ArtLineTo(ConstellationArt._c(11.00, 12.0)),
      ArtLineTo(ConstellationArt._c(10.50, 11.5)),
      ArtLineTo(ConstellationArt._c(10.14, 11.97)), // Regulus
      const ArtClose(),
      // Front legs
      ArtMoveTo(ConstellationArt._c(10.30, 12.5)),
      ArtLineTo(ConstellationArt._c(10.20, 9.5)),
      ArtLineTo(ConstellationArt._c(10.05, 8.0)),
      ArtLineTo(ConstellationArt._c(10.20, 7.8)),
      ArtLineTo(ConstellationArt._c(10.35, 9.5)),
      ArtLineTo(ConstellationArt._c(10.45, 11.5)),
      const ArtClose(),
      // Hind legs
      ArtMoveTo(ConstellationArt._c(11.20, 12.5)),
      ArtLineTo(ConstellationArt._c(11.15, 9.5)),
      ArtLineTo(ConstellationArt._c(11.00, 8.0)),
      ArtLineTo(ConstellationArt._c(11.15, 7.8)),
      ArtLineTo(ConstellationArt._c(11.30, 9.5)),
      ArtLineTo(ConstellationArt._c(11.40, 12.0)),
      const ArtClose(),
      // Tail tuft
      ArtMoveTo(ConstellationArt._c(11.82, 14.57)),
      ArtQuadTo(
        ConstellationArt._c(12.10, 15.5),
        ConstellationArt._c(12.20, 15.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(12.15, 14.0),
        ConstellationArt._c(12.00, 14.0),
      ),
      const ArtClose(),
    ],
  ),

  // SCORPIUS — The Scorpion
  // Anchor stars: Dschubba (16.01, -22.62), Antares (16.49, -26.43),
  //   Shaula (17.56, -37.10), Lesath (17.71, -39.03)
  // Figure: scorpion with pincers, body, and curving tail with stinger
  ConstellationArtData(
    abbreviation: 'Sco',
    segments: [
      // Left pincer
      ArtMoveTo(ConstellationArt._c(15.90, -20.0)),
      ArtQuadTo(
        ConstellationArt._c(15.70, -18.0),
        ConstellationArt._c(15.50, -19.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(15.65, -21.0),
        ConstellationArt._c(15.90, -20.0),
      ),
      const ArtClose(),
      // Right pincer
      ArtMoveTo(ConstellationArt._c(16.15, -20.0)),
      ArtQuadTo(
        ConstellationArt._c(16.35, -18.0),
        ConstellationArt._c(16.55, -19.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(16.40, -21.0),
        ConstellationArt._c(16.15, -20.0),
      ),
      const ArtClose(),
      // Head (connects pincers)
      ArtMoveTo(ConstellationArt._c(15.90, -21.5)),
      ArtLineTo(ConstellationArt._c(16.01, -22.62)), // Dschubba
      ArtLineTo(ConstellationArt._c(16.15, -21.5)),
      ArtLineTo(ConstellationArt._c(16.15, -20.0)),
      ArtLineTo(ConstellationArt._c(15.90, -20.0)),
      const ArtClose(),
      // Body (Dschubba to Antares to tail)
      ArtMoveTo(ConstellationArt._c(15.90, -22.5)),
      ArtLineTo(ConstellationArt._c(16.01, -22.62)), // Dschubba
      ArtLineTo(ConstellationArt._c(16.20, -23.0)),
      ArtLineTo(ConstellationArt._c(16.49, -26.43)), // Antares
      ArtLineTo(ConstellationArt._c(16.84, -34.29)), // Tau Sco
      ArtLineTo(ConstellationArt._c(17.20, -37.30)), // Epsilon Sco
      ArtQuadTo(
        ConstellationArt._c(17.40, -38.0),
        ConstellationArt._c(17.56, -37.10),
      ), // Shaula
      ArtQuadTo(
        ConstellationArt._c(17.65, -38.5),
        ConstellationArt._c(17.71, -39.03),
      ), // Lesath
      // Stinger curves back
      ArtLineTo(ConstellationArt._c(17.80, -38.0)),
      ArtLineTo(ConstellationArt._c(17.85, -37.0)),
      // Return path (other side of body)
      ArtQuadTo(
        ConstellationArt._c(17.70, -37.5),
        ConstellationArt._c(17.62, -37.50),
      ),
      ArtLineTo(ConstellationArt._c(17.30, -37.60)),
      ArtLineTo(ConstellationArt._c(16.95, -34.60)),
      ArtLineTo(ConstellationArt._c(16.60, -27.0)),
      ArtLineTo(ConstellationArt._c(16.30, -23.5)),
      ArtLineTo(ConstellationArt._c(16.10, -22.8)),
      ArtLineTo(ConstellationArt._c(15.90, -22.5)),
      const ArtClose(),
      // Legs (3 pairs along body)
      ArtMoveTo(ConstellationArt._c(16.30, -24.5)),
      ArtLineTo(ConstellationArt._c(16.05, -25.5)),
      ArtLineTo(ConstellationArt._c(16.10, -26.0)),
      ArtLineTo(ConstellationArt._c(16.35, -25.0)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(16.50, -27.5)),
      ArtLineTo(ConstellationArt._c(16.25, -28.5)),
      ArtLineTo(ConstellationArt._c(16.30, -29.0)),
      ArtLineTo(ConstellationArt._c(16.55, -28.0)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(16.70, -30.5)),
      ArtLineTo(ConstellationArt._c(16.45, -31.5)),
      ArtLineTo(ConstellationArt._c(16.50, -32.0)),
      ArtLineTo(ConstellationArt._c(16.75, -31.0)),
      const ArtClose(),
      // Right-side legs
      ArtMoveTo(ConstellationArt._c(16.40, -24.0)),
      ArtLineTo(ConstellationArt._c(16.65, -25.0)),
      ArtLineTo(ConstellationArt._c(16.60, -25.5)),
      ArtLineTo(ConstellationArt._c(16.35, -24.5)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(16.60, -27.0)),
      ArtLineTo(ConstellationArt._c(16.85, -28.0)),
      ArtLineTo(ConstellationArt._c(16.80, -28.5)),
      ArtLineTo(ConstellationArt._c(16.55, -27.5)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(16.80, -30.0)),
      ArtLineTo(ConstellationArt._c(17.05, -31.0)),
      ArtLineTo(ConstellationArt._c(17.00, -31.5)),
      ArtLineTo(ConstellationArt._c(16.75, -30.5)),
      const ArtClose(),
    ],
  ),

  // CYGNUS — The Swan
  // Anchor stars: Deneb (20.69, 45.28), Albireo (19.51, 27.96),
  //   Sadr (20.37, 40.26), Gienah Cygni (19.75, 45.13)
  // Figure: swan with outstretched wings, long neck
  ConstellationArtData(
    abbreviation: 'Cyg',
    segments: [
      // Body (elongated along Deneb-Albireo axis)
      ArtMoveTo(ConstellationArt._c(20.69, 45.28)), // Deneb (tail)
      ArtQuadTo(
        ConstellationArt._c(20.55, 43.5),
        ConstellationArt._c(20.37, 40.26),
      ), // Sadr (body center)
      ArtQuadTo(
        ConstellationArt._c(20.10, 36.0),
        ConstellationArt._c(19.80, 31.0),
      ),
      ArtLineTo(ConstellationArt._c(19.51, 27.96)), // Albireo (head/beak)
      ArtLineTo(ConstellationArt._c(19.45, 27.5)),
      ArtQuadTo(
        ConstellationArt._c(19.75, 31.0),
        ConstellationArt._c(20.05, 36.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(20.30, 40.0),
        ConstellationArt._c(20.60, 45.0),
      ),
      const ArtClose(),
      // Left wing (toward Gienah Cygni)
      ArtMoveTo(ConstellationArt._c(20.37, 41.0)), // above Sadr
      ArtQuadTo(
        ConstellationArt._c(20.00, 43.0),
        ConstellationArt._c(19.75, 45.13),
      ), // Gienah Cygni
      ArtLineTo(ConstellationArt._c(19.40, 46.0)), // wing tip
      ArtLineTo(ConstellationArt._c(19.30, 45.5)),
      ArtQuadTo(
        ConstellationArt._c(19.60, 44.0),
        ConstellationArt._c(20.00, 41.5),
      ),
      ArtLineTo(ConstellationArt._c(20.25, 40.0)),
      const ArtClose(),
      // Right wing (toward Fawaris / delta Cyg)
      ArtMoveTo(ConstellationArt._c(20.50, 41.0)),
      ArtQuadTo(
        ConstellationArt._c(20.80, 37.0),
        ConstellationArt._c(21.22, 30.23),
      ), // Fawaris
      ArtLineTo(ConstellationArt._c(21.50, 28.0)), // wing tip
      ArtLineTo(ConstellationArt._c(21.55, 28.8)),
      ArtQuadTo(
        ConstellationArt._c(21.00, 33.0),
        ConstellationArt._c(20.70, 38.0),
      ),
      ArtLineTo(ConstellationArt._c(20.50, 40.0)),
      const ArtClose(),
      // Tail fan (around Deneb)
      ArtMoveTo(ConstellationArt._c(20.55, 45.5)),
      ArtQuadTo(
        ConstellationArt._c(20.60, 47.0),
        ConstellationArt._c(20.69, 47.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(20.80, 47.0),
        ConstellationArt._c(20.75, 45.5),
      ),
      const ArtClose(),
    ],
  ),

  // GEMINI — The Twins
  // Anchor stars: Castor (7.58, 31.89), Pollux (7.76, 28.03),
  //   Alhena (6.63, 16.40), Mebsuta (7.07, 20.57), Wasat (7.19, 16.54)
  // Figure: two standing figures side by side
  ConstellationArtData(
    abbreviation: 'Gem',
    segments: [
      // Castor figure (left twin)
      // Head
      ArtMoveTo(ConstellationArt._c(7.52, 33.0)),
      ArtQuadTo(
        ConstellationArt._c(7.65, 34.0),
        ConstellationArt._c(7.58, 34.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(7.50, 34.0),
        ConstellationArt._c(7.52, 33.0),
      ),
      const ArtClose(),
      // Torso
      ArtMoveTo(ConstellationArt._c(7.50, 32.5)),
      ArtLineTo(ConstellationArt._c(7.65, 32.5)),
      ArtLineTo(ConstellationArt._c(7.60, 25.0)),
      ArtLineTo(ConstellationArt._c(7.07, 20.57)), // Mebsuta (mid-body)
      ArtLineTo(ConstellationArt._c(6.63, 16.40)), // Alhena (foot)
      ArtLineTo(ConstellationArt._c(6.55, 16.2)),
      ArtLineTo(ConstellationArt._c(7.00, 20.3)),
      ArtLineTo(ConstellationArt._c(7.45, 25.0)),
      ArtLineTo(ConstellationArt._c(7.50, 32.5)),
      const ArtClose(),
      // Pollux figure (right twin)
      // Head
      ArtMoveTo(ConstellationArt._c(7.70, 29.0)),
      ArtQuadTo(
        ConstellationArt._c(7.82, 30.0),
        ConstellationArt._c(7.76, 30.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(7.68, 30.0),
        ConstellationArt._c(7.70, 29.0),
      ),
      const ArtClose(),
      // Torso
      ArtMoveTo(ConstellationArt._c(7.68, 28.5)),
      ArtLineTo(ConstellationArt._c(7.83, 28.5)),
      ArtLineTo(ConstellationArt._c(7.60, 22.0)),
      ArtLineTo(ConstellationArt._c(7.19, 16.54)), // Wasat (mid-body)
      ArtLineTo(ConstellationArt._c(6.73, 12.90)), // Mekbuda (foot)
      ArtLineTo(ConstellationArt._c(6.65, 12.7)),
      ArtLineTo(ConstellationArt._c(7.12, 16.3)),
      ArtLineTo(ConstellationArt._c(7.45, 22.0)),
      ArtLineTo(ConstellationArt._c(7.68, 28.5)),
      const ArtClose(),
      // Joined hands (between twins at shoulder height)
      ArtMoveTo(ConstellationArt._c(7.60, 28.0)),
      ArtLineTo(ConstellationArt._c(7.68, 28.0)),
      ArtLineTo(ConstellationArt._c(7.68, 28.5)),
      ArtLineTo(ConstellationArt._c(7.60, 28.5)),
      const ArtClose(),
    ],
  ),

  // SAGITTARIUS — The Archer (Teapot)
  // Anchor stars: Kaus Australis (18.40, -34.38), Kaus Media (18.35, -29.83),
  //   Kaus Borealis (18.23, -25.42), Nunki (18.92, -26.30), Ascella (19.04, -29.88)
  // Figure: centaur archer drawing a bow
  ConstellationArtData(
    abbreviation: 'Sgr',
    segments: [
      // Human torso (upper body, above Kaus Borealis)
      ArtMoveTo(ConstellationArt._c(18.35, -24.0)),
      ArtLineTo(ConstellationArt._c(18.50, -23.0)), // chest
      ArtLineTo(ConstellationArt._c(18.45, -21.0)), // neck
      // Head
      ArtQuadTo(
        ConstellationArt._c(18.50, -19.5),
        ConstellationArt._c(18.40, -19.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(18.30, -19.5),
        ConstellationArt._c(18.35, -21.0),
      ),
      // Shoulders back down
      ArtLineTo(ConstellationArt._c(18.20, -23.0)),
      ArtLineTo(ConstellationArt._c(18.23, -25.42)), // Kaus Borealis
      const ArtClose(),
      // Bow arm (extended left)
      ArtMoveTo(ConstellationArt._c(18.20, -23.0)),
      ArtLineTo(ConstellationArt._c(17.80, -22.0)),
      ArtLineTo(ConstellationArt._c(17.50, -21.0)), // bow grip
      ArtLineTo(ConstellationArt._c(17.45, -21.5)),
      ArtLineTo(ConstellationArt._c(17.75, -22.5)),
      ArtLineTo(ConstellationArt._c(18.15, -23.5)),
      const ArtClose(),
      // Bow arc
      ArtMoveTo(ConstellationArt._c(17.50, -21.0)),
      ArtQuadTo(
        ConstellationArt._c(17.30, -24.0),
        ConstellationArt._c(17.50, -27.0),
      ),
      ArtLineTo(ConstellationArt._c(17.55, -27.0)),
      ArtQuadTo(
        ConstellationArt._c(17.35, -24.0),
        ConstellationArt._c(17.55, -21.0),
      ),
      const ArtClose(),
      // Horse body (lower, following teapot outline)
      ArtMoveTo(ConstellationArt._c(18.23, -25.42)), // Kaus Borealis
      ArtLineTo(ConstellationArt._c(18.35, -29.83)), // Kaus Media
      ArtLineTo(ConstellationArt._c(18.40, -34.38)), // Kaus Australis
      ArtLineTo(ConstellationArt._c(19.04, -29.88)), // Ascella
      ArtLineTo(ConstellationArt._c(18.92, -26.30)), // Nunki
      ArtLineTo(ConstellationArt._c(18.70, -25.5)),
      const ArtClose(),
      // Hind legs
      ArtMoveTo(ConstellationArt._c(18.90, -30.0)),
      ArtLineTo(ConstellationArt._c(19.10, -33.0)),
      ArtLineTo(ConstellationArt._c(19.20, -35.0)),
      ArtLineTo(ConstellationArt._c(19.30, -35.2)),
      ArtLineTo(ConstellationArt._c(19.20, -33.0)),
      ArtLineTo(ConstellationArt._c(19.00, -30.5)),
      const ArtClose(),
      // Front legs
      ArtMoveTo(ConstellationArt._c(18.40, -34.38)),
      ArtLineTo(ConstellationArt._c(18.30, -36.5)),
      ArtLineTo(ConstellationArt._c(18.20, -38.0)),
      ArtLineTo(ConstellationArt._c(18.30, -38.2)),
      ArtLineTo(ConstellationArt._c(18.40, -36.5)),
      ArtLineTo(ConstellationArt._c(18.50, -34.5)),
      const ArtClose(),
    ],
  ),

  // TAURUS — The Bull
  // Anchor stars: Aldebaran (4.60, 16.51), Elnath (5.44, 28.61),
  //   Zeta Tau (5.63, 21.14)
  // Figure: bull head and shoulders with horns
  ConstellationArtData(
    abbreviation: 'Tau',
    segments: [
      // Bull face (V-shape of Hyades)
      ArtMoveTo(ConstellationArt._c(4.00, 12.5)),
      ArtQuadTo(
        ConstellationArt._c(4.20, 14.0),
        ConstellationArt._c(4.60, 16.51),
      ), // Aldebaran (eye)
      ArtLineTo(ConstellationArt._c(4.80, 17.0)),
      ArtLineTo(ConstellationArt._c(4.60, 14.0)),
      ArtLineTo(ConstellationArt._c(4.33, 15.63)),
      ArtLineTo(ConstellationArt._c(4.00, 12.5)),
      const ArtClose(),
      // Broad head
      ArtMoveTo(ConstellationArt._c(4.00, 12.0)),
      ArtLineTo(ConstellationArt._c(4.80, 17.5)),
      ArtLineTo(ConstellationArt._c(5.00, 19.0)),
      ArtLineTo(ConstellationArt._c(4.80, 19.5)),
      ArtLineTo(ConstellationArt._c(3.80, 13.0)),
      const ArtClose(),
      // Left horn (to Elnath)
      ArtMoveTo(ConstellationArt._c(4.80, 19.5)),
      ArtQuadTo(
        ConstellationArt._c(5.10, 24.0),
        ConstellationArt._c(5.44, 28.61),
      ), // Elnath
      ArtLineTo(ConstellationArt._c(5.50, 29.0)),
      ArtQuadTo(
        ConstellationArt._c(5.15, 24.5),
        ConstellationArt._c(4.90, 19.5),
      ),
      const ArtClose(),
      // Right horn (to Zeta Tau)
      ArtMoveTo(ConstellationArt._c(5.00, 19.0)),
      ArtQuadTo(
        ConstellationArt._c(5.30, 20.0),
        ConstellationArt._c(5.63, 21.14),
      ), // Zeta Tau
      ArtLineTo(ConstellationArt._c(5.70, 21.5)),
      ArtQuadTo(
        ConstellationArt._c(5.35, 20.5),
        ConstellationArt._c(5.10, 19.0),
      ),
      const ArtClose(),
      // Neck/shoulder (trails off to the right)
      ArtMoveTo(ConstellationArt._c(3.80, 13.0)),
      ArtLineTo(ConstellationArt._c(3.50, 11.0)),
      ArtQuadTo(ConstellationArt._c(3.40, 9.0), ConstellationArt._c(3.50, 8.0)),
      ArtLineTo(ConstellationArt._c(3.70, 8.0)),
      ArtQuadTo(
        ConstellationArt._c(3.60, 9.5),
        ConstellationArt._c(3.70, 11.5),
      ),
      ArtLineTo(ConstellationArt._c(4.00, 12.0)),
      const ArtClose(),
    ],
  ),

  // CANIS MAJOR — The Great Dog
  // Anchor stars: Sirius (6.75, -16.72), Mirzam (6.38, -17.96),
  //   Wezen (7.14, -26.39), Adhara (6.98, -28.97), Furud (6.61, -32.51)
  // Figure: sitting dog facing left
  ConstellationArtData(
    abbreviation: 'CMa',
    segments: [
      // Head (around Sirius)
      ArtMoveTo(ConstellationArt._c(6.65, -14.5)),
      ArtQuadTo(
        ConstellationArt._c(6.55, -13.5),
        ConstellationArt._c(6.65, -12.5),
      ), // top of head
      ArtQuadTo(
        ConstellationArt._c(6.85, -13.0),
        ConstellationArt._c(6.90, -14.5),
      ),
      ArtLineTo(ConstellationArt._c(6.85, -16.0)),
      ArtLineTo(ConstellationArt._c(6.65, -16.0)),
      const ArtClose(),
      // Ear
      ArtMoveTo(ConstellationArt._c(6.60, -13.0)),
      ArtLineTo(ConstellationArt._c(6.50, -11.5)),
      ArtLineTo(ConstellationArt._c(6.55, -12.0)),
      const ArtClose(),
      // Body
      ArtMoveTo(ConstellationArt._c(6.65, -16.0)),
      ArtLineTo(ConstellationArt._c(6.38, -17.96)), // Mirzam (chest)
      ArtLineTo(ConstellationArt._c(6.40, -21.0)),
      ArtLineTo(ConstellationArt._c(6.61, -25.0)),
      ArtLineTo(ConstellationArt._c(6.98, -28.97)), // Adhara
      ArtLineTo(ConstellationArt._c(7.14, -26.39)), // Wezen (back)
      ArtLineTo(ConstellationArt._c(7.00, -22.0)),
      ArtLineTo(ConstellationArt._c(6.85, -18.0)),
      ArtLineTo(ConstellationArt._c(6.85, -16.0)),
      const ArtClose(),
      // Front legs
      ArtMoveTo(ConstellationArt._c(6.40, -21.0)),
      ArtLineTo(ConstellationArt._c(6.25, -24.0)),
      ArtLineTo(ConstellationArt._c(6.20, -26.0)),
      ArtLineTo(ConstellationArt._c(6.30, -26.2)),
      ArtLineTo(ConstellationArt._c(6.35, -24.0)),
      ArtLineTo(ConstellationArt._c(6.50, -21.5)),
      const ArtClose(),
      // Hind leg
      ArtMoveTo(ConstellationArt._c(6.98, -28.97)),
      ArtLineTo(ConstellationArt._c(6.80, -31.0)),
      ArtLineTo(ConstellationArt._c(6.61, -32.51)), // Furud
      ArtLineTo(ConstellationArt._c(6.55, -32.8)),
      ArtLineTo(ConstellationArt._c(6.75, -31.0)),
      ArtLineTo(ConstellationArt._c(6.90, -29.5)),
      const ArtClose(),
      // Tail (upward from Wezen)
      ArtMoveTo(ConstellationArt._c(7.14, -26.39)),
      ArtQuadTo(
        ConstellationArt._c(7.30, -24.0),
        ConstellationArt._c(7.40, -22.5),
      ),
      ArtLineTo(ConstellationArt._c(7.35, -22.0)),
      ArtQuadTo(
        ConstellationArt._c(7.25, -23.5),
        ConstellationArt._c(7.10, -25.5),
      ),
      const ArtClose(),
    ],
  ),

  // LYRA — The Lyre (harp)
  // Anchor stars: Vega (18.62, 38.78), Sheliak (18.83, 33.36),
  //   Sulafat (18.91, 33.36)
  // Figure: small harp/lyre shape
  ConstellationArtData(
    abbreviation: 'Lyr',
    segments: [
      // Frame of the lyre (trapezoidal)
      ArtMoveTo(ConstellationArt._c(18.62, 38.78)), // Vega (top)
      ArtLineTo(ConstellationArt._c(18.50, 37.5)),
      ArtLineTo(ConstellationArt._c(18.45, 35.0)),
      ArtQuadTo(
        ConstellationArt._c(18.50, 32.0),
        ConstellationArt._c(18.83, 33.36),
      ), // Sheliak
      ArtLineTo(ConstellationArt._c(18.91, 33.36)), // Sulafat
      ArtQuadTo(
        ConstellationArt._c(19.10, 32.0),
        ConstellationArt._c(19.10, 35.0),
      ),
      ArtLineTo(ConstellationArt._c(19.00, 37.5)),
      ArtLineTo(ConstellationArt._c(18.62, 38.78)), // back to Vega
      const ArtClose(),
      // Left string
      ArtMoveTo(ConstellationArt._c(18.55, 37.0)),
      ArtLineTo(ConstellationArt._c(18.60, 33.5)),
      ArtLineTo(ConstellationArt._c(18.62, 33.5)),
      ArtLineTo(ConstellationArt._c(18.57, 37.0)),
      const ArtClose(),
      // Center string
      ArtMoveTo(ConstellationArt._c(18.75, 37.5)),
      ArtLineTo(ConstellationArt._c(18.80, 33.0)),
      ArtLineTo(ConstellationArt._c(18.82, 33.0)),
      ArtLineTo(ConstellationArt._c(18.77, 37.5)),
      const ArtClose(),
      // Right string
      ArtMoveTo(ConstellationArt._c(18.95, 37.0)),
      ArtLineTo(ConstellationArt._c(18.93, 33.5)),
      ArtLineTo(ConstellationArt._c(18.95, 33.5)),
      ArtLineTo(ConstellationArt._c(18.97, 37.0)),
      const ArtClose(),
      // Crossbar
      ArtMoveTo(ConstellationArt._c(18.50, 35.5)),
      ArtLineTo(ConstellationArt._c(19.05, 35.5)),
      ArtLineTo(ConstellationArt._c(19.05, 35.8)),
      ArtLineTo(ConstellationArt._c(18.50, 35.8)),
      const ArtClose(),
    ],
  ),
];
