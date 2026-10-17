import '../../database/database.dart' show TransientDetectionRow;
import '../../models/alerts/transient_alert.dart';
import 'transient_candidate.dart';

/// Bridges a Pillar B ("First Light") [TransientDetectionRow] into the shared
/// [TransientAlert] model so a self-discovered transient flows through the same
/// alert surfaces (badge, dropdown, transients screen) as AAVSO / TNS alerts.
///
/// The detection's residual shape-class maps onto the alert taxonomy: a moving
/// streak → asteroid, a clean unnamed point source → supernova-like (the most
/// urgent "go look now" tier), a named brightening → variable star / nova. The
/// alert id is namespaced (`firstlight:<rowId>`) so its acknowledged/dismissed
/// state persists distinctly from external alerts and never collides with them.
TransientAlert transientAlertFromDetection(TransientDetectionRow detection) {
  final kind = TransientKind.fromWire(detection.kind);
  final type = _typeForKind(kind, hasMatch: detection.catalogMatch != null);
  final raHours = (detection.raDeg % 360.0) / 15.0;

  final name = detection.catalogMatch ?? _provisionalName(detection);

  // `TransientAlert.magnitude` is an APPARENT magnitude: the card buckets it
  // NAKED EYE / BINOCULAR / SMALL SCOPE, the feed filters on
  // `magnitudeThreshold`, `shouldNotify` auto-queues anything at or under
  // `autoQueueMagnitude`, and `addAlertToTargets` copies it into the target
  // library. A First Light detection has no apparent magnitude at all — the
  // difference-image pipeline measures only `delta_mag`, a brightness CHANGE
  // against the atlas template, and there is no photometric zero point behind
  // it. Since a difference larger than ~6 mag is essentially impossible, using
  // it as an apparent magnitude announced EVERY self-discovery as a naked-eye
  // or binocular object. Leave it null (every consumer already guards on null)
  // and carry the change itself in the classification line instead.
  final deltaMag = detection.deltaMag;
  final deltaLabel = deltaMag != null && deltaMag.isFinite && deltaMag != 0
      ? 'Δ${deltaMag.abs().toStringAsFixed(2)} mag '
            '${deltaMag < 0 ? 'brighter' : 'fainter'} than template'
      : null;

  final baseClassification = detection.catalogMatch == null
      ? 'Unconfirmed — possible new transient'
      : 'Brightening of ${detection.catalogMatch}';

  return TransientAlert(
    id: 'firstlight:${detection.id}',
    name: name,
    type: type,
    raHours: raHours < 0 ? raHours + 24.0 : raHours,
    decDegrees: detection.decDeg,
    magnitude: null,
    discoveryTime: detection.detectedAt,
    lastUpdated: detection.detectedAt,
    source: TransientSource.manual,
    // Higher confidence → higher priority (lower number). Clamp to [1, 10].
    priority: (1 + ((1.0 - detection.confidence) * 9).round()).clamp(1, 10),
    classification: deltaLabel == null
        ? baseClassification
        : '$baseClassification · $deltaLabel',
    notes:
        'Skotiq First Light difference-image detection. '
        'Tile ${detection.tileId}, SNR ${detection.snr.toStringAsFixed(1)}, '
        'kind ${detection.kind}.'
        '${deltaLabel == null ? '' : ' $deltaLabel — this is a brightness '
                  'change, not an apparent magnitude; no photometric zero point '
                  'is available for this detection.'}',
    state: detection.dismissed
        ? TransientAlertState.dismissed
        : (detection.reviewed
              ? TransientAlertState.acknowledged
              : TransientAlertState.newAlert),
  );
}

TransientType _typeForKind(TransientKind kind, {required bool hasMatch}) {
  switch (kind) {
    case TransientKind.movingStreak:
      return TransientType.asteroid;
    case TransientKind.newSource:
      // A clean, unnamed newcomer is treated as the supernova-like top tier.
      return hasMatch ? TransientType.variableStar : TransientType.supernova;
    case TransientKind.pointBrightening:
      return hasMatch ? TransientType.variableStar : TransientType.nova;
    case TransientKind.dipole:
    case TransientKind.unknown:
      return TransientType.other;
  }
}

/// Provisional designation in IAU coordinate form: `NS JHHMMSS.ss±DDMMSS.s`.
///
/// This is shown to operators and carried into TNS, AAVSO, and MPC reports.
String _provisionalName(TransientDetectionRow detection) {
  final wrappedRa = detection.raDeg % 360.0;
  final raDeg = wrappedRa < 0 ? wrappedRa + 360.0 : wrappedRa;
  return 'NS J${_raHms(raDeg / 15.0)}${_decDms(detection.decDeg)}';
}

/// RA as `HHMMSS.ss`. Rounds at the printed precision and carries, so
/// 59.999 s becomes the next minute rather than `..5960.00`.
String _raHms(double hours) {
  const hundredthsPerDay = 24 * 3600 * 100;
  var hundredths = (hours * 3600 * 100).round() % hundredthsPerDay;
  if (hundredths < 0) hundredths += hundredthsPerDay;
  final h = hundredths ~/ (3600 * 100);
  final m = (hundredths % (3600 * 100)) ~/ (60 * 100);
  final s = (hundredths % (60 * 100)) / 100.0;
  return '${h.toString().padLeft(2, '0')}'
      '${m.toString().padLeft(2, '0')}'
      '${s.toStringAsFixed(2).padLeft(5, '0')}';
}

/// Declination as `±DDMMSS.s`, with the same round-then-carry rule.
String _decDms(double degrees) {
  final sign = degrees < 0 ? '-' : '+';
  final tenths = (degrees.abs() * 3600 * 10).round();
  final d = tenths ~/ 36000;
  final m = (tenths % 36000) ~/ 600;
  final s = (tenths % 600) / 10.0;
  return '$sign${d.toString().padLeft(2, '0')}'
      '${m.toString().padLeft(2, '0')}'
      '${s.toStringAsFixed(1).padLeft(4, '0')}';
}
