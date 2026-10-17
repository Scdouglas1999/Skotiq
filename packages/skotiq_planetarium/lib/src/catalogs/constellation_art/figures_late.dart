// Aquila through Corona Borealis constellation-art payloads.
part of '../constellation_art.dart';

final List<ConstellationArtData> _lateConstellationArtFigures = [
  // AQUILA — The Eagle
  // Anchor stars: Altair (19.85, 8.87), Tarazed (19.77, 10.61),
  //   Alshain (19.92, 6.41)
  // Figure: eagle with outstretched wings
  ConstellationArtData(
    abbreviation: 'Aql',
    segments: [
      // Body
      ArtMoveTo(ConstellationArt._c(19.77, 10.61)), // Tarazed (upper body)
      ArtLineTo(ConstellationArt._c(19.85, 8.87)), // Altair (center)
      ArtLineTo(ConstellationArt._c(19.92, 6.41)), // Alshain (lower body)
      ArtLineTo(ConstellationArt._c(20.00, 5.0)), // tail
      ArtLineTo(ConstellationArt._c(19.85, 5.0)),
      ArtLineTo(ConstellationArt._c(19.70, 6.5)),
      ArtLineTo(ConstellationArt._c(19.65, 8.5)),
      ArtLineTo(ConstellationArt._c(19.70, 10.5)),
      const ArtClose(),
      // Head
      ArtMoveTo(ConstellationArt._c(19.77, 10.61)),
      ArtQuadTo(
        ConstellationArt._c(19.82, 12.0),
        ConstellationArt._c(19.80, 12.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(19.72, 12.0),
        ConstellationArt._c(19.70, 10.5),
      ),
      const ArtClose(),
      // Left wing (toward Delta Aql)
      ArtMoveTo(ConstellationArt._c(19.70, 9.5)),
      ArtQuadTo(
        ConstellationArt._c(19.40, 11.0),
        ConstellationArt._c(19.10, 13.86),
      ), // Delta Aql
      ArtLineTo(ConstellationArt._c(18.80, 15.0)),
      ArtLineTo(ConstellationArt._c(18.75, 14.5)),
      ArtQuadTo(
        ConstellationArt._c(19.05, 13.0),
        ConstellationArt._c(19.55, 9.5),
      ),
      const ArtClose(),
      // Right wing (toward Theta Aql)
      ArtMoveTo(ConstellationArt._c(20.00, 7.0)),
      ArtQuadTo(
        ConstellationArt._c(20.10, 4.0),
        ConstellationArt._c(20.19, -0.82),
      ), // Theta Aql
      ArtLineTo(ConstellationArt._c(20.40, -2.0)),
      ArtLineTo(ConstellationArt._c(20.45, -1.5)),
      ArtQuadTo(
        ConstellationArt._c(20.25, 2.0),
        ConstellationArt._c(20.10, 6.5),
      ),
      const ArtClose(),
      // Tail feathers
      ArtMoveTo(ConstellationArt._c(19.90, 5.0)),
      ArtLineTo(ConstellationArt._c(20.05, 3.5)),
      ArtLineTo(ConstellationArt._c(20.10, 4.0)),
      ArtLineTo(ConstellationArt._c(19.95, 5.0)),
      const ArtClose(),
    ],
  ),

  // PEGASUS — The Winged Horse (Great Square + neck/head)
  // Anchor stars: Alpheratz (0.14, 29.09), Scheat (23.06, 28.08),
  //   Markab (23.08, 15.21), Algenib (0.22, 15.18), Enif (21.74, 9.87)
  // Figure: horse body from the Great Square with neck to Enif
  ConstellationArtData(
    abbreviation: 'Peg',
    segments: [
      // Body (the Great Square)
      ArtMoveTo(ConstellationArt._c(0.14, 29.09)), // Alpheratz
      ArtLineTo(ConstellationArt._c(23.06, 28.08)), // Scheat
      ArtLineTo(ConstellationArt._c(23.08, 15.21)), // Markab
      ArtLineTo(ConstellationArt._c(0.22, 15.18)), // Algenib
      const ArtClose(),
      // Neck (from Scheat toward Enif)
      ArtMoveTo(ConstellationArt._c(23.06, 28.08)), // Scheat
      ArtLineTo(ConstellationArt._c(22.80, 27.0)),
      ArtLineTo(ConstellationArt._c(22.12, 25.35)), // Matar
      ArtQuadTo(
        ConstellationArt._c(21.90, 20.0),
        ConstellationArt._c(21.74, 9.87),
      ), // Enif (head)
      // Head
      ArtQuadTo(
        ConstellationArt._c(21.60, 8.0),
        ConstellationArt._c(21.50, 9.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(21.65, 12.0),
        ConstellationArt._c(21.74, 12.0),
      ),
      // Return along neck
      ArtQuadTo(
        ConstellationArt._c(21.85, 19.0),
        ConstellationArt._c(22.00, 25.0),
      ),
      ArtLineTo(ConstellationArt._c(22.70, 27.0)),
      ArtLineTo(ConstellationArt._c(22.95, 28.0)),
      const ArtClose(),
      // Wing (above square, from Scheat-Alpheratz edge)
      ArtMoveTo(ConstellationArt._c(23.50, 28.5)),
      ArtQuadTo(
        ConstellationArt._c(23.80, 33.0),
        ConstellationArt._c(0.00, 35.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(0.10, 33.0),
        ConstellationArt._c(23.60, 29.0),
      ),
      const ArtClose(),
      // Front legs (below Markab)
      ArtMoveTo(ConstellationArt._c(23.08, 15.21)),
      ArtLineTo(ConstellationArt._c(23.15, 12.0)),
      ArtLineTo(ConstellationArt._c(23.20, 10.0)),
      ArtLineTo(ConstellationArt._c(23.30, 10.0)),
      ArtLineTo(ConstellationArt._c(23.25, 12.0)),
      ArtLineTo(ConstellationArt._c(23.20, 15.0)),
      const ArtClose(),
      // Hind legs (below Algenib)
      ArtMoveTo(ConstellationArt._c(0.22, 15.18)),
      ArtLineTo(ConstellationArt._c(0.28, 12.0)),
      ArtLineTo(ConstellationArt._c(0.32, 10.0)),
      ArtLineTo(ConstellationArt._c(0.42, 10.0)),
      ArtLineTo(ConstellationArt._c(0.38, 12.0)),
      ArtLineTo(ConstellationArt._c(0.32, 15.0)),
      const ArtClose(),
    ],
  ),

  // ANDROMEDA — The Chained Princess
  // Anchor stars: Alpheratz (0.14, 29.09), Mirach (1.16, 35.62),
  //   Almach (2.07, 42.33)
  // Figure: woman with arms stretched out (chained)
  ConstellationArtData(
    abbreviation: 'And',
    segments: [
      // Body (along the main line of stars)
      ArtMoveTo(ConstellationArt._c(0.14, 30.5)), // above Alpheratz
      ArtLineTo(ConstellationArt._c(0.14, 28.0)), // below
      ArtLineTo(ConstellationArt._c(1.16, 34.5)), // below Mirach
      ArtLineTo(ConstellationArt._c(2.07, 41.0)), // below Almach
      ArtLineTo(ConstellationArt._c(2.07, 43.5)), // above Almach
      ArtLineTo(ConstellationArt._c(1.16, 36.8)), // above Mirach
      const ArtClose(),
      // Head (near Almach)
      ArtMoveTo(ConstellationArt._c(2.00, 43.5)),
      ArtQuadTo(
        ConstellationArt._c(2.15, 44.5),
        ConstellationArt._c(2.07, 45.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(1.95, 44.5),
        ConstellationArt._c(2.00, 43.5),
      ),
      const ArtClose(),
      // Left arm (from near Mirach, stretched out)
      ArtMoveTo(ConstellationArt._c(1.05, 36.5)),
      ArtLineTo(ConstellationArt._c(0.80, 38.0)),
      ArtLineTo(ConstellationArt._c(0.50, 39.5)),
      ArtLineTo(ConstellationArt._c(0.45, 39.0)),
      ArtLineTo(ConstellationArt._c(0.75, 37.5)),
      ArtLineTo(ConstellationArt._c(1.00, 35.8)),
      const ArtClose(),
      // Right arm (from near Almach, stretched out)
      ArtMoveTo(ConstellationArt._c(2.00, 43.0)),
      ArtLineTo(ConstellationArt._c(2.30, 44.5)),
      ArtLineTo(ConstellationArt._c(2.60, 45.5)),
      ArtLineTo(ConstellationArt._c(2.65, 45.0)),
      ArtLineTo(ConstellationArt._c(2.35, 44.0)),
      ArtLineTo(ConstellationArt._c(2.07, 42.5)),
      const ArtClose(),
      // Skirt/legs (flowing down from Alpheratz area)
      ArtMoveTo(ConstellationArt._c(0.14, 28.0)),
      ArtLineTo(ConstellationArt._c(0.00, 26.0)),
      ArtLineTo(ConstellationArt._c(-0.05, 24.5)),
      ArtLineTo(ConstellationArt._c(0.05, 24.5)),
      ArtLineTo(ConstellationArt._c(0.14, 26.5)),
      ArtLineTo(ConstellationArt._c(0.25, 24.5)),
      ArtLineTo(ConstellationArt._c(0.35, 24.5)),
      ArtLineTo(ConstellationArt._c(0.30, 26.0)),
      ArtLineTo(ConstellationArt._c(0.14, 28.0)),
      const ArtClose(),
    ],
  ),

  // PERSEUS — The Hero
  // Anchor stars: Mirfak (3.41, 49.86), Algol (3.14, 40.96),
  //   Gamma Per (3.72, 47.79)
  // Figure: man holding sword and head of Medusa (Algol)
  ConstellationArtData(
    abbreviation: 'Per',
    segments: [
      // Torso
      ArtMoveTo(ConstellationArt._c(3.30, 50.0)),
      ArtLineTo(ConstellationArt._c(3.50, 50.0)), // shoulders
      ArtLineTo(ConstellationArt._c(3.72, 47.79)), // Gamma Per (arm)
      ArtLineTo(ConstellationArt._c(3.55, 46.0)),
      ArtLineTo(ConstellationArt._c(3.45, 43.0)),
      ArtLineTo(ConstellationArt._c(3.35, 43.0)),
      ArtLineTo(ConstellationArt._c(3.25, 46.0)),
      ArtLineTo(ConstellationArt._c(3.08, 47.5)), // left arm
      ArtLineTo(ConstellationArt._c(3.30, 50.0)),
      const ArtClose(),
      // Head
      ArtMoveTo(ConstellationArt._c(3.35, 50.5)),
      ArtQuadTo(
        ConstellationArt._c(3.48, 51.5),
        ConstellationArt._c(3.41, 52.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(3.32, 51.5),
        ConstellationArt._c(3.35, 50.5),
      ),
      const ArtClose(),
      // Arm holding Medusa head (toward Algol)
      ArtMoveTo(ConstellationArt._c(3.25, 46.0)),
      ArtLineTo(ConstellationArt._c(3.14, 43.0)),
      ArtLineTo(ConstellationArt._c(3.14, 40.96)), // Algol (Medusa's head)
      ArtLineTo(ConstellationArt._c(3.05, 40.5)),
      ArtLineTo(ConstellationArt._c(3.05, 43.0)),
      ArtLineTo(ConstellationArt._c(3.15, 46.0)),
      const ArtClose(),
      // Medusa head (circle around Algol)
      ArtMoveTo(ConstellationArt._c(3.05, 41.0)),
      ArtQuadTo(
        ConstellationArt._c(2.95, 40.0),
        ConstellationArt._c(3.14, 39.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(3.30, 40.0),
        ConstellationArt._c(3.20, 41.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(3.15, 41.5),
        ConstellationArt._c(3.05, 41.0),
      ),
      const ArtClose(),
      // Sword arm (from Gamma Per outward)
      ArtMoveTo(ConstellationArt._c(3.72, 47.79)),
      ArtLineTo(ConstellationArt._c(3.90, 48.5)),
      ArtLineTo(ConstellationArt._c(4.10, 49.0)), // sword tip
      ArtLineTo(ConstellationArt._c(4.12, 48.5)),
      ArtLineTo(ConstellationArt._c(3.92, 48.0)),
      ArtLineTo(ConstellationArt._c(3.75, 47.5)),
      const ArtClose(),
      // Legs
      ArtMoveTo(ConstellationArt._c(3.35, 43.0)),
      ArtLineTo(ConstellationArt._c(3.25, 40.0)),
      ArtLineTo(ConstellationArt._c(3.15, 38.0)),
      ArtLineTo(ConstellationArt._c(3.25, 37.8)),
      ArtLineTo(ConstellationArt._c(3.35, 40.0)),
      ArtLineTo(ConstellationArt._c(3.45, 43.0)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(3.45, 43.0)),
      ArtLineTo(ConstellationArt._c(3.55, 40.0)),
      ArtLineTo(ConstellationArt._c(3.65, 38.0)),
      ArtLineTo(ConstellationArt._c(3.75, 37.8)),
      ArtLineTo(ConstellationArt._c(3.65, 40.0)),
      ArtLineTo(ConstellationArt._c(3.55, 43.0)),
      const ArtClose(),
    ],
  ),

  // BOOTES — The Herdsman (kite shape)
  // Anchor stars: Arcturus (14.26, 19.18), Izar (14.53, 30.37),
  //   Nekkar (15.03, 40.39)
  // Figure: man with staff, kite-shaped body
  ConstellationArtData(
    abbreviation: 'Boo',
    segments: [
      // Body (kite shape)
      ArtMoveTo(ConstellationArt._c(14.26, 19.18)), // Arcturus (base)
      ArtLineTo(ConstellationArt._c(13.91, 18.40)), // Eta Boo (left)
      ArtLineTo(ConstellationArt._c(14.53, 30.37)), // Izar (left-top)
      ArtLineTo(ConstellationArt._c(15.03, 40.39)), // Nekkar (top/head)
      ArtLineTo(ConstellationArt._c(14.75, 27.07)), // Delta Boo (right-top)
      ArtLineTo(ConstellationArt._c(14.26, 19.18)), // back to Arcturus
      const ArtClose(),
      // Head
      ArtMoveTo(ConstellationArt._c(14.95, 40.5)),
      ArtQuadTo(
        ConstellationArt._c(15.10, 42.0),
        ConstellationArt._c(15.03, 42.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(14.95, 42.0),
        ConstellationArt._c(14.95, 40.5),
      ),
      const ArtClose(),
      // Staff (from left hand downward)
      ArtMoveTo(ConstellationArt._c(13.85, 18.0)),
      ArtLineTo(ConstellationArt._c(13.70, 15.0)),
      ArtLineTo(ConstellationArt._c(13.60, 12.0)),
      ArtLineTo(ConstellationArt._c(13.65, 11.8)),
      ArtLineTo(ConstellationArt._c(13.75, 15.0)),
      ArtLineTo(ConstellationArt._c(13.91, 18.0)),
      const ArtClose(),
      // Left arm
      ArtMoveTo(ConstellationArt._c(14.10, 27.0)),
      ArtLineTo(ConstellationArt._c(13.70, 28.0)),
      ArtLineTo(ConstellationArt._c(13.50, 28.0)),
      ArtLineTo(ConstellationArt._c(13.65, 27.5)),
      ArtLineTo(ConstellationArt._c(14.00, 26.5)),
      const ArtClose(),
      // Right arm
      ArtMoveTo(ConstellationArt._c(14.70, 28.0)),
      ArtLineTo(ConstellationArt._c(15.10, 29.0)),
      ArtLineTo(ConstellationArt._c(15.30, 29.0)),
      ArtLineTo(ConstellationArt._c(15.15, 28.5)),
      ArtLineTo(ConstellationArt._c(14.80, 27.5)),
      const ArtClose(),
    ],
  ),

  // VIRGO — The Maiden
  // Anchor stars: Spica (13.42, -11.16), Porrima (12.69, -1.45),
  //   Vindemiatrix (12.93, 3.40)
  // Figure: woman holding a sheaf of wheat (Spica)
  ConstellationArtData(
    abbreviation: 'Vir',
    segments: [
      // Body
      ArtMoveTo(ConstellationArt._c(12.80, 5.0)), // head area
      ArtLineTo(ConstellationArt._c(12.93, 3.40)), // Vindemiatrix (shoulder)
      ArtLineTo(ConstellationArt._c(12.69, -1.45)), // Porrima (waist)
      ArtLineTo(ConstellationArt._c(13.00, -5.0)), // hip
      ArtLineTo(ConstellationArt._c(12.50, -5.0)), // other hip
      ArtLineTo(ConstellationArt._c(12.55, -1.0)),
      ArtLineTo(ConstellationArt._c(12.70, 3.0)),
      const ArtClose(),
      // Head
      ArtMoveTo(ConstellationArt._c(12.75, 5.5)),
      ArtQuadTo(
        ConstellationArt._c(12.90, 6.5),
        ConstellationArt._c(12.80, 7.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(12.70, 6.5),
        ConstellationArt._c(12.75, 5.5),
      ),
      const ArtClose(),
      // Arm holding wheat (toward Spica)
      ArtMoveTo(ConstellationArt._c(12.80, 0.0)),
      ArtLineTo(ConstellationArt._c(13.10, -4.0)),
      ArtLineTo(ConstellationArt._c(13.42, -11.16)), // Spica (wheat)
      ArtLineTo(ConstellationArt._c(13.50, -11.50)),
      ArtLineTo(ConstellationArt._c(13.52, -11.0)),
      ArtLineTo(ConstellationArt._c(13.20, -4.0)),
      ArtLineTo(ConstellationArt._c(12.90, 0.0)),
      const ArtClose(),
      // Wheat sheaf (rays around Spica)
      ArtMoveTo(ConstellationArt._c(13.42, -11.16)),
      ArtLineTo(ConstellationArt._c(13.30, -12.5)),
      ArtLineTo(ConstellationArt._c(13.35, -12.8)),
      ArtLineTo(ConstellationArt._c(13.42, -11.16)),
      ArtLineTo(ConstellationArt._c(13.55, -12.5)),
      ArtLineTo(ConstellationArt._c(13.50, -12.8)),
      ArtLineTo(ConstellationArt._c(13.42, -11.16)),
      const ArtClose(),
      // Flowing skirt (legs)
      ArtMoveTo(ConstellationArt._c(12.50, -5.0)),
      ArtLineTo(ConstellationArt._c(12.30, -8.0)),
      ArtLineTo(ConstellationArt._c(12.20, -10.0)),
      ArtLineTo(ConstellationArt._c(12.30, -10.2)),
      ArtLineTo(ConstellationArt._c(12.45, -8.0)),
      ArtLineTo(ConstellationArt._c(12.65, -5.0)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(13.00, -5.0)),
      ArtLineTo(ConstellationArt._c(13.10, -8.0)),
      ArtLineTo(ConstellationArt._c(13.20, -10.0)),
      ArtLineTo(ConstellationArt._c(13.10, -10.2)),
      ArtLineTo(ConstellationArt._c(13.00, -8.0)),
      ArtLineTo(ConstellationArt._c(12.85, -5.0)),
      const ArtClose(),
    ],
  ),

  // URSA MINOR — The Little Bear
  // Anchor stars: Polaris (2.53, 89.26), Kochab (14.85, 74.16),
  //   Pherkad (15.35, 71.83)
  // Figure: small bear with tail at Polaris
  ConstellationArtData(
    abbreviation: 'UMi',
    segments: [
      // Body (bowl of Little Dipper)
      ArtMoveTo(ConstellationArt._c(14.50, 75.0)),
      ArtLineTo(ConstellationArt._c(14.85, 74.16)), // Kochab
      ArtLineTo(ConstellationArt._c(15.35, 71.83)), // Pherkad
      ArtLineTo(ConstellationArt._c(16.29, 75.76)), // Epsilon UMi
      ArtLineTo(ConstellationArt._c(15.73, 77.79)), // Zeta UMi
      ArtLineTo(ConstellationArt._c(14.85, 75.5)),
      const ArtClose(),
      // Tail (handle to Polaris)
      ArtMoveTo(ConstellationArt._c(16.29, 76.5)),
      ArtLineTo(ConstellationArt._c(17.54, 86.59)), // Yildun
      ArtQuadTo(
        ConstellationArt._c(5.0, 88.0),
        ConstellationArt._c(2.53, 89.26),
      ), // Polaris
      ArtQuadTo(
        ConstellationArt._c(5.0, 89.0),
        ConstellationArt._c(17.54, 87.5),
      ),
      ArtLineTo(ConstellationArt._c(16.29, 77.0)),
      const ArtClose(),
      // Ear
      ArtMoveTo(ConstellationArt._c(14.50, 75.0)),
      ArtLineTo(ConstellationArt._c(14.30, 76.0)),
      ArtLineTo(ConstellationArt._c(14.50, 75.8)),
      const ArtClose(),
      // Front legs
      ArtMoveTo(ConstellationArt._c(14.85, 74.16)),
      ArtLineTo(ConstellationArt._c(14.70, 72.5)),
      ArtLineTo(ConstellationArt._c(14.60, 71.5)),
      ArtLineTo(ConstellationArt._c(14.75, 71.3)),
      ArtLineTo(ConstellationArt._c(14.85, 72.5)),
      ArtLineTo(ConstellationArt._c(15.00, 73.5)),
      const ArtClose(),
      // Hind legs
      ArtMoveTo(ConstellationArt._c(15.80, 72.5)),
      ArtLineTo(ConstellationArt._c(15.90, 71.0)),
      ArtLineTo(ConstellationArt._c(16.00, 70.0)),
      ArtLineTo(ConstellationArt._c(16.15, 69.8)),
      ArtLineTo(ConstellationArt._c(16.05, 71.0)),
      ArtLineTo(ConstellationArt._c(15.95, 72.5)),
      const ArtClose(),
    ],
  ),

  // DRACO — The Dragon
  // Anchor stars: Eltanin (17.51, 52.30), Rastaban (17.51, 51.49),
  //   Thuban (14.07, 64.38)
  // Figure: serpentine dragon winding between the bears
  ConstellationArtData(
    abbreviation: 'Dra',
    segments: [
      // Head (angular, around Eltanin/Rastaban)
      ArtMoveTo(ConstellationArt._c(17.35, 53.5)),
      ArtLineTo(ConstellationArt._c(17.51, 52.30)), // Eltanin
      ArtLineTo(ConstellationArt._c(17.70, 52.0)),
      ArtLineTo(ConstellationArt._c(17.65, 51.0)),
      ArtLineTo(ConstellationArt._c(17.51, 51.49)), // Rastaban
      ArtLineTo(ConstellationArt._c(17.30, 52.0)),
      const ArtClose(),
      // Body (sinuous path through constellation)
      ArtMoveTo(ConstellationArt._c(17.35, 53.5)),
      ArtQuadTo(
        ConstellationArt._c(17.20, 54.5),
        ConstellationArt._c(17.15, 54.47),
      ),
      ArtQuadTo(
        ConstellationArt._c(16.80, 58.0),
        ConstellationArt._c(16.40, 61.51),
      ),
      ArtQuadTo(
        ConstellationArt._c(15.80, 59.0),
        ConstellationArt._c(15.42, 58.97),
      ),
      ArtQuadTo(
        ConstellationArt._c(14.50, 62.0),
        ConstellationArt._c(14.07, 64.38),
      ), // Thuban
      ArtQuadTo(
        ConstellationArt._c(13.30, 67.0),
        ConstellationArt._c(12.56, 69.79),
      ),
      ArtQuadTo(
        ConstellationArt._c(12.00, 69.5),
        ConstellationArt._c(11.52, 69.33),
      ), // Alpha Dra
      // Tail tip
      ArtLineTo(ConstellationArt._c(11.40, 69.8)),
      // Return path (other side of body, slightly offset)
      ArtQuadTo(
        ConstellationArt._c(12.10, 70.5),
        ConstellationArt._c(12.70, 70.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(13.40, 68.0),
        ConstellationArt._c(14.20, 65.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(14.60, 63.0),
        ConstellationArt._c(15.50, 59.8),
      ),
      ArtQuadTo(
        ConstellationArt._c(16.00, 60.5),
        ConstellationArt._c(16.50, 62.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(16.90, 59.0),
        ConstellationArt._c(17.25, 55.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(17.30, 54.0),
        ConstellationArt._c(17.45, 53.5),
      ),
      ArtLineTo(ConstellationArt._c(17.35, 53.5)),
      const ArtClose(),
    ],
  ),

  // HERCULES — The Strongman
  // Anchor stars: Kornephoros (16.15, 14.03), Rasalgethi (17.39, 37.15)
  // Keystone: Zeta (16.50, 21.49), Eta (16.36, 19.15),
  //   Pi (17.25, 24.84), Epsilon (16.69, 31.60)
  // Figure: man with club, upside-down in sky
  ConstellationArtData(
    abbreviation: 'Her',
    segments: [
      // Keystone body (torso)
      ArtMoveTo(ConstellationArt._c(16.50, 21.49)), // Zeta Her
      ArtLineTo(ConstellationArt._c(16.36, 19.15)), // Eta Her
      ArtLineTo(ConstellationArt._c(17.25, 24.84)), // Pi Her
      ArtLineTo(ConstellationArt._c(16.69, 31.60)), // Epsilon Her
      const ArtClose(),
      // Head (below keystone since Hercules is upside-down)
      ArtMoveTo(ConstellationArt._c(16.10, 14.5)),
      ArtQuadTo(
        ConstellationArt._c(16.25, 13.0),
        ConstellationArt._c(16.15, 12.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(16.05, 13.0),
        ConstellationArt._c(16.10, 14.5),
      ),
      const ArtClose(),
      // Leg down to Kornephoros
      ArtMoveTo(ConstellationArt._c(16.50, 21.49)),
      ArtLineTo(ConstellationArt._c(16.35, 18.0)),
      ArtLineTo(ConstellationArt._c(16.15, 14.03)), // Kornephoros
      ArtLineTo(ConstellationArt._c(16.05, 14.0)),
      ArtLineTo(ConstellationArt._c(16.25, 18.0)),
      ArtLineTo(ConstellationArt._c(16.36, 19.15)),
      const ArtClose(),
      // Other leg (from Eta Her)
      ArtMoveTo(ConstellationArt._c(16.36, 19.15)),
      ArtLineTo(ConstellationArt._c(17.24, 14.39)), // Sarin
      ArtLineTo(ConstellationArt._c(17.30, 14.5)),
      ArtLineTo(ConstellationArt._c(16.50, 19.5)),
      const ArtClose(),
      // Arm to Rasalgethi
      ArtMoveTo(ConstellationArt._c(16.69, 31.60)),
      ArtLineTo(ConstellationArt._c(17.00, 34.0)),
      ArtLineTo(ConstellationArt._c(17.39, 37.15)), // Rasalgethi
      ArtLineTo(ConstellationArt._c(17.45, 37.5)),
      ArtLineTo(ConstellationArt._c(17.05, 34.5)),
      ArtLineTo(ConstellationArt._c(16.75, 31.8)),
      const ArtClose(),
      // Arm from Pi Her (with club)
      ArtMoveTo(ConstellationArt._c(17.25, 24.84)),
      ArtLineTo(ConstellationArt._c(17.58, 12.56)), // toward Rasalhague
      ArtLineTo(ConstellationArt._c(17.65, 12.5)),
      ArtLineTo(ConstellationArt._c(17.35, 25.0)),
      const ArtClose(),
    ],
  ),

  // AURIGA — The Charioteer
  // Anchor stars: Capella (5.28, 46.00), Menkalinan (6.00, 44.95),
  //   Elnath (5.44, 28.61), Almaaz (5.11, 41.23)
  // Figure: pentagon with charioteer holding reins
  ConstellationArtData(
    abbreviation: 'Aur',
    segments: [
      // Pentagon body
      ArtMoveTo(ConstellationArt._c(5.28, 46.00)), // Capella
      ArtLineTo(ConstellationArt._c(6.00, 44.95)), // Menkalinan
      ArtLineTo(ConstellationArt._c(5.99, 37.21)), // Theta Aur
      ArtLineTo(ConstellationArt._c(5.44, 28.61)), // Elnath
      ArtLineTo(ConstellationArt._c(5.03, 33.17)), // Iota Aur
      ArtLineTo(ConstellationArt._c(5.11, 41.23)), // Almaaz
      const ArtClose(),
      // Head (above Capella)
      ArtMoveTo(ConstellationArt._c(5.22, 47.0)),
      ArtQuadTo(
        ConstellationArt._c(5.35, 48.5),
        ConstellationArt._c(5.28, 49.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(5.18, 48.5),
        ConstellationArt._c(5.22, 47.0),
      ),
      const ArtClose(),
      // Goat kids (small figure near Almaaz — the charioteer traditionally holds baby goats)
      ArtMoveTo(ConstellationArt._c(5.00, 42.0)),
      ArtQuadTo(
        ConstellationArt._c(4.85, 42.5),
        ConstellationArt._c(4.85, 43.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(4.95, 43.5),
        ConstellationArt._c(5.05, 43.0),
      ),
      ArtQuadTo(
        ConstellationArt._c(5.05, 42.5),
        ConstellationArt._c(5.00, 42.0),
      ),
      const ArtClose(),
    ],
  ),

  // CRUX — The Southern Cross
  // Anchor stars: Acrux (12.44, -63.10), Gacrux (12.52, -57.11),
  //   Mimosa (12.80, -59.69), Imai (12.25, -58.75)
  // Figure: ornate cross
  ConstellationArtData(
    abbreviation: 'Cru',
    segments: [
      // Vertical beam
      ArtMoveTo(ConstellationArt._c(12.44, -63.10)), // Acrux (bottom)
      ArtLineTo(ConstellationArt._c(12.38, -62.5)),
      ArtLineTo(ConstellationArt._c(12.46, -60.5)), // center
      ArtLineTo(ConstellationArt._c(12.52, -57.11)), // Gacrux (top)
      ArtLineTo(ConstellationArt._c(12.58, -57.5)),
      ArtLineTo(ConstellationArt._c(12.52, -60.5)), // center
      ArtLineTo(ConstellationArt._c(12.50, -62.5)),
      const ArtClose(),
      // Horizontal beam
      ArtMoveTo(ConstellationArt._c(12.25, -58.75)), // Imai (left)
      ArtLineTo(ConstellationArt._c(12.30, -59.3)),
      ArtLineTo(ConstellationArt._c(12.46, -59.8)), // center
      ArtLineTo(ConstellationArt._c(12.80, -59.69)), // Mimosa (right)
      ArtLineTo(ConstellationArt._c(12.75, -60.2)),
      ArtLineTo(ConstellationArt._c(12.52, -60.2)), // center
      ArtLineTo(ConstellationArt._c(12.30, -59.8)),
      const ArtClose(),
      // Flared tips (top)
      ArtMoveTo(ConstellationArt._c(12.45, -57.3)),
      ArtLineTo(ConstellationArt._c(12.40, -56.5)),
      ArtLineTo(ConstellationArt._c(12.52, -57.11)),
      ArtLineTo(ConstellationArt._c(12.65, -56.5)),
      ArtLineTo(ConstellationArt._c(12.58, -57.3)),
      const ArtClose(),
      // Flared tips (bottom)
      ArtMoveTo(ConstellationArt._c(12.38, -62.8)),
      ArtLineTo(ConstellationArt._c(12.35, -63.5)),
      ArtLineTo(ConstellationArt._c(12.44, -63.10)),
      ArtLineTo(ConstellationArt._c(12.55, -63.5)),
      ArtLineTo(ConstellationArt._c(12.50, -62.8)),
      const ArtClose(),
      // Flared tips (left)
      ArtMoveTo(ConstellationArt._c(12.28, -59.0)),
      ArtLineTo(ConstellationArt._c(12.15, -58.5)),
      ArtLineTo(ConstellationArt._c(12.25, -58.75)),
      ArtLineTo(ConstellationArt._c(12.15, -59.3)),
      ArtLineTo(ConstellationArt._c(12.28, -59.6)),
      const ArtClose(),
      // Flared tips (right)
      ArtMoveTo(ConstellationArt._c(12.77, -59.4)),
      ArtLineTo(ConstellationArt._c(12.90, -59.0)),
      ArtLineTo(ConstellationArt._c(12.80, -59.69)),
      ArtLineTo(ConstellationArt._c(12.90, -60.2)),
      ArtLineTo(ConstellationArt._c(12.77, -60.0)),
      const ArtClose(),
    ],
  ),

  // CEPHEUS — The King
  // Anchor stars: Alderamin (21.31, 62.59), Errai (23.66, 77.63)
  // Figure: house/pentagon shaped king on throne
  ConstellationArtData(
    abbreviation: 'Cep',
    segments: [
      // Body (pentagon of main stars)
      ArtMoveTo(ConstellationArt._c(21.31, 62.59)), // Alderamin
      ArtLineTo(ConstellationArt._c(22.49, 58.20)), // Zeta Cep
      ArtLineTo(ConstellationArt._c(22.83, 66.20)), // Delta Cep
      ArtLineTo(ConstellationArt._c(23.19, 75.39)), // Iota Cep
      ArtLineTo(ConstellationArt._c(23.66, 77.63)), // Errai
      const ArtClose(),
      // Crown (above Errai)
      ArtMoveTo(ConstellationArt._c(23.50, 78.0)),
      ArtLineTo(ConstellationArt._c(23.45, 79.5)),
      ArtLineTo(ConstellationArt._c(23.55, 80.0)),
      ArtLineTo(ConstellationArt._c(23.66, 79.5)),
      ArtLineTo(ConstellationArt._c(23.75, 80.0)),
      ArtLineTo(ConstellationArt._c(23.85, 79.5)),
      ArtLineTo(ConstellationArt._c(23.80, 78.0)),
      const ArtClose(),
      // Scepter (from Alderamin outward)
      ArtMoveTo(ConstellationArt._c(21.31, 62.59)),
      ArtLineTo(ConstellationArt._c(21.00, 61.0)),
      ArtLineTo(ConstellationArt._c(20.80, 60.0)),
      ArtLineTo(ConstellationArt._c(20.85, 59.5)),
      ArtLineTo(ConstellationArt._c(21.05, 60.5)),
      ArtLineTo(ConstellationArt._c(21.25, 62.0)),
      const ArtClose(),
    ],
  ),

  // CORONA BOREALIS — The Northern Crown
  // Anchor stars: Alphecca (15.58, 26.71), Nusakan (15.46, 29.11)
  // Figure: semicircular crown/diadem
  ConstellationArtData(
    abbreviation: 'CrB',
    segments: [
      // Crown arc (follows the arc of stars)
      ArtMoveTo(ConstellationArt._c(15.58, 26.71)), // Alphecca
      ArtQuadTo(
        ConstellationArt._c(15.45, 28.0),
        ConstellationArt._c(15.46, 29.11),
      ), // Nusakan
      ArtQuadTo(
        ConstellationArt._c(15.60, 30.5),
        ConstellationArt._c(15.71, 31.36),
      ), // Theta CrB
      ArtQuadTo(
        ConstellationArt._c(15.85, 31.0),
        ConstellationArt._c(15.96, 30.29),
      ), // Epsilon CrB
      ArtQuadTo(
        ConstellationArt._c(16.00, 30.0),
        ConstellationArt._c(16.02, 29.85),
      ), // Delta CrB
      ArtQuadTo(
        ConstellationArt._c(16.00, 28.0),
        ConstellationArt._c(15.99, 26.88),
      ), // Gamma CrB
      ArtLineTo(ConstellationArt._c(15.58, 26.71)), // back to Alphecca
      const ArtClose(),
      // Inner arc (thinner, to give crown depth)
      ArtMoveTo(ConstellationArt._c(15.63, 27.5)),
      ArtQuadTo(
        ConstellationArt._c(15.55, 28.5),
        ConstellationArt._c(15.55, 29.5),
      ),
      ArtQuadTo(
        ConstellationArt._c(15.65, 30.5),
        ConstellationArt._c(15.75, 30.8),
      ),
      ArtQuadTo(
        ConstellationArt._c(15.85, 30.5),
        ConstellationArt._c(15.90, 29.8),
      ),
      ArtQuadTo(
        ConstellationArt._c(15.92, 28.5),
        ConstellationArt._c(15.90, 27.5),
      ),
      ArtLineTo(ConstellationArt._c(15.63, 27.5)),
      const ArtClose(),
      // Jewel points (three small triangles on top)
      ArtMoveTo(ConstellationArt._c(15.55, 29.5)),
      ArtLineTo(ConstellationArt._c(15.50, 30.5)),
      ArtLineTo(ConstellationArt._c(15.58, 30.0)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(15.75, 30.8)),
      ArtLineTo(ConstellationArt._c(15.75, 31.8)),
      ArtLineTo(ConstellationArt._c(15.80, 31.2)),
      const ArtClose(),
      ArtMoveTo(ConstellationArt._c(15.90, 29.8)),
      ArtLineTo(ConstellationArt._c(15.95, 30.8)),
      ArtLineTo(ConstellationArt._c(15.98, 30.2)),
      const ArtClose(),
    ],
  ),
];
