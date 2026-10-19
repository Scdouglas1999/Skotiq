import 'package:flutter/widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Identity for one arrow of the jog pad. The arrows carry an explicit key
/// rather than relying on their glyph or letter, which other controls share.
ValueKey<String> mountJogButtonKey(String direction) =>
    ValueKey<String>('mountJog.$direction');

/// Identity for the veil drawn over the pad when it cannot move the mount.
/// A dimmed icon colour alone is indistinguishable from the enabled state on
/// the dark theme, which is how a parked mount produced an arrow pad that
/// looked live and did nothing.
const ValueKey<String> mountJogDisabledVeilKey =
    ValueKey<String>('mountJog.disabledVeil');

/// The sidereal rate in degrees per second (15.041"/s). The jog speed ladder is
/// quoted as multiples of it because that is the language every mount handset,
/// NINA and SGP use ("4×", "64×"), not because the tracking rate is involved.
const double kSiderealDegPerSec = 0.00417807;

/// The speed ladder the jog pad offers, as multiples of sidereal: guide,
/// center, find, and two slew speeds.
const List<double> kMountJogMultiples = <double>[0.5, 4, 16, 64, 256];

/// The rate the pad starts on: a centering speed.
const String kMountJogDefaultLabel = '4×';

/// How long a single guide pulse lasts in the [MountJogMode.pulse] fallback.
const int kMountJogPulseMs = 500;

/// A held jog is stopped unconditionally after this long. A MoveAxis that never
/// receives its matching stop drives the mount into the pier, so a dropped
/// pointer-up (a crashed frame, a widget torn down mid-press) must not leave the
/// axis running.
const Duration kMountJogMaxHold = Duration(seconds: 30);

/// What the arrow pad will actually do, decided from what the driver says it
/// can do rather than assumed.
enum MountJogMode {
  /// The driver advertises MoveAxis: hold to slew at the selected rate, release
  /// to stop. This is what an arrow pad is supposed to do.
  slew,

  /// No MoveAxis, but the mount can pulse-guide. Holding repeats guide pulses,
  /// and the pad says so — a guide pulse is roughly four arcseconds, so a pad
  /// that silently fired one looked broken.
  pulse,

  /// Neither is available: the pad is disabled and explains why instead of
  /// accepting presses that go nowhere.
  unavailable,
}

/// One selectable jog speed.
class MountJogRate {
  /// Short label for the selector, e.g. `4×` or `Max`.
  final String label;

  /// The MoveAxis rate in degrees per second.
  final double degPerSec;

  const MountJogRate(this.label, this.degPerSec);

  @override
  bool operator ==(Object other) =>
      other is MountJogRate &&
      other.label == label &&
      other.degPerSec == degPerSec;

  @override
  int get hashCode => Object.hash(label, degPerSec);
}

/// Decide the pad's behaviour from the driver's advertised capabilities.
///
/// Unknown capabilities ([capabilities] null) resolve to [MountJogMode.pulse]
/// only when the connection itself is live and the mount state already says it
/// can guide; otherwise unknown fails closed to [MountJogMode.unavailable]. A
/// pad that sends MoveAxis to a driver that never claimed to support it just
/// produces a driver exception on every press.
MountJogMode mountJogModeFor(MountCapabilities? capabilities) {
  if (capabilities == null) return MountJogMode.unavailable;
  if (capabilities.canMoveAxis) return MountJogMode.slew;
  if (capabilities.canPulseGuide) return MountJogMode.pulse;
  return MountJogMode.unavailable;
}

/// The jog speeds offered for a driver whose advertised ceiling is
/// [maxSlewRateDegPerSec] (null when the driver does not report one).
///
/// Rates above a reported ceiling are DROPPED rather than sent and rejected,
/// and the ceiling itself is offered as `Max` so the fastest speed a mount can
/// actually do is always reachable.
List<MountJogRate> mountJogRates(double? maxSlewRateDegPerSec) {
  final ladder = [
    for (final multiple in kMountJogMultiples)
      MountJogRate(_multipleLabel(multiple), multiple * kSiderealDegPerSec),
  ];

  final ceiling = maxSlewRateDegPerSec;
  if (ceiling == null || ceiling <= 0) return ladder;

  final withinCeiling =
      ladder.where((rate) => rate.degPerSec < ceiling).toList(growable: true);
  withinCeiling.add(MountJogRate('Max', ceiling));
  return withinCeiling;
}

/// `0.5×`, `4×`.
String _multipleLabel(double multiple) => multiple == multiple.roundToDouble()
    ? '${multiple.toInt()}×'
    : '$multiple×';

/// The rate the pad starts on: the centering speed ([kMountJogDefaultLabel])
/// when it is offered, otherwise the fastest rate that is.
MountJogRate defaultMountJogRate(List<MountJogRate> rates) {
  return rates.firstWhere(
    (rate) => rate.label == kMountJogDefaultLabel,
    orElse: () => rates.last,
  );
}

/// Map a compass direction and speed onto the ASCOM MoveAxis pair.
///
/// axis 0 is the primary (RA / azimuth) axis and axis 1 the secondary (Dec /
/// altitude); a positive rate moves north or east and a negative one south or
/// west, matching `DeviceBackend.mountMoveAxis` and the INDI direction mapping
/// the native bridge does for non-ASCOM mounts.
({int axis, double rate}) mountJogAxis(String direction, double degPerSec) {
  final magnitude = degPerSec.abs();
  return switch (direction.toLowerCase()) {
    'east' => (axis: 0, rate: magnitude),
    'west' => (axis: 0, rate: -magnitude),
    'north' => (axis: 1, rate: magnitude),
    'south' => (axis: 1, rate: -magnitude),
    _ => throw ArgumentError.value(
        direction,
        'direction',
        'must be north, south, east or west',
      ),
  };
}
