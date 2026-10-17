import 'package:skotiq_core/skotiq_core.dart';

/// A Target node is born at RA 0h / Dec +0° because [TargetHeaderNode] has no
/// nullable coordinate to mean "the user has not chosen a pointing yet".
/// Exactly (0h, +0°) is a real point in Pisces, so every builder surface used
/// to render that placeholder as a settled pointing: the tree card printed
/// `RA 00h 00m 00s`, and the Slew editor confirmed in green that it "Will use
/// target: M31" while carrying coordinates nobody entered. A run built that
/// way tracks a random patch of Pisces all night while the UI insists the
/// target is set.
///
/// Treat the exact origin as unset so those surfaces can say so instead of
/// asserting a sky position. The cost is that a deliberate 0h/+0° pointing
/// also reads as unset; nudging either value by a ten-thousandth of a unit
/// (the precision the editor already exposes) claims it back.
bool targetCoordinatesUnset(TargetHeaderNode node) =>
    node.raHours == 0 && node.decDegrees == 0;
