import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as path;

import '../../database/database.dart' show TransientDetectionRow;
import 'transient_candidate.dart' show TransientKind;
import '../../utils/skotiq_data_directory.dart';

/// Which discovery network a [TransientReportService] report targets. Each has a
/// distinct, real submission format.
enum TransientReportFormat {
  /// AAVSO Extended File Format (variable-star / brightening photometry),
  /// ingested by WebObs.
  aavso,

  /// Minor Planet Center ADES PSV optical astrometry (moving objects).
  mpc,

  /// IAU Transient Name Server bulk-report JSON (new transients).
  tns,
}

/// Non-secret TNS bot identifiers + reporter, resolved from science settings
/// at submission time. The secret bot API key is NOT here — it lives in the
/// keyring (`SecretField.tnsApiKey`) and is read by the submission service.
class TnsCredentials {
  /// `tns_id` in the mandatory `tns_marker` User-Agent header.
  final int botId;

  /// `name` in the `tns_marker` User-Agent header.
  final String botName;

  /// `reporting_group_id` in the at_report JSON.
  final int reportingGroupId;

  /// `discovery_data_source_id` in the at_report JSON.
  final int dataSourceId;

  /// Free-text reporter name(s) for the `reporter` field.
  final String reporterName;

  /// The secret bot API key (read from the keyring by the caller, never
  /// persisted in settings/backup). Empty until the user enters it.
  final String apiKey;

  /// Submit against the sandbox base URL rather than production.
  final bool useSandbox;

  const TnsCredentials({
    required this.botId,
    required this.botName,
    required this.reportingGroupId,
    required this.dataSourceId,
    required this.reporterName,
    required this.apiKey,
    this.useSandbox = false,
  });

  /// All required identifiers present (non-secret + the secret api key). The
  /// reporter name falls back to the observer name upstream, so it is not
  /// gated here beyond non-empty.
  bool get isComplete =>
      botId > 0 &&
      botName.trim().isNotEmpty &&
      reportingGroupId > 0 &&
      dataSourceId > 0 &&
      reporterName.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty;
}

/// Generates standards-compliant, INGESTIBLE discovery reports for a confirmed
/// transient detection.
///
/// Pure string/JSON builders — no I/O except [writeReport]. The network
/// submission seam (real TNS bot-API upload) lives in
/// `TransientSubmissionService`; this class only produces the payloads.
///
/// Honest field availability (see `transient_detections.dart`): we have a
/// J2000 position, a UTC timestamp, an SNR-derived magnitude uncertainty, a
/// shape class, and (template-backed) an *instrumental* Δmag. We do NOT have an
/// absolute calibrated magnitude, a named comparison star, a VSX designation,
/// or an astrometric uncertainty. The generators below degrade honestly into
/// those gaps rather than stuffing `na` into required fields.
class TransientReportService {
  // ── AAVSO Extended File Format ─────────────────────────────────────────────

  /// True when an ingestible AAVSO row can be built for [detection].
  ///
  /// AAVSO's WebObs rejects a `DIF` row whose comparison star is `na`, and we
  /// have no differential ensemble photometry. The only honest path is the
  /// `STD` (standardized) magnitude type, which requires an absolute magnitude
  /// — i.e. a photometric zeropoint ([magZeroPoint]) joined onto the frame and
  /// a real template-backed instrumental Δmag. Without both, AAVSO is disabled.
  bool aavsoAvailable(TransientDetectionRow detection, {double? magZeroPoint}) {
    final dm = detection.deltaMag;
    return magZeroPoint != null &&
        magZeroPoint.isFinite &&
        dm != null &&
        dm.isFinite;
  }

  /// Human-readable reason AAVSO is unavailable, or null when it is available.
  ///
  /// Reports EVERY blocker that applies, leading with the calibrated magnitude.
  /// AAVSO needs both a photometric zeropoint for the detection's frame and an
  /// observer code, and on a fresh profile with an uncalibrated frame both are
  /// missing. Returning the observer-code sentence alone told the operator that
  /// one settings field was all that stood in the way; they would set it, come
  /// back, and find AAVSO still disabled behind a blocker no setting can clear.
  /// The un-fixable one is stated first precisely because Settings cannot
  /// resolve it — the report panel and the headless
  /// `/api/firstlight/<id>/export/aavso` 400 body both render this string.
  String? aavsoDisabledReason(
    TransientDetectionRow detection, {
    required String observerCode,
    double? magZeroPoint,
  }) {
    final needsZeroPoint = !aavsoAvailable(
      detection,
      magZeroPoint: magZeroPoint,
    );
    final needsObserverCode = observerCode.trim().isEmpty;
    if (!needsZeroPoint && !needsObserverCode) return null;

    return [
      if (needsZeroPoint)
        'AAVSO needs a calibrated magnitude (a photometric zeropoint for '
            'this frame) — not available for this detection.',
      if (needsObserverCode)
        needsZeroPoint
            // Not "first": it is not the only thing in the way, and saying so
            // is what sent the operator on the dead-end trip to Settings.
            ? 'Your AAVSO observer code is also unset (Settings > Science).'
            : 'Set your AAVSO observer code in Settings > Science first.',
    ].join(' ');
  }

  /// Build an AAVSO Extended File Format report (Option A — STD magnitude).
  ///
  /// Requires [magZeroPoint] (the frame's photometric zeropoint, e.g. FITS
  /// MAGZP). The standardized magnitude is the instrumental magnitude
  /// (`-2.5*log10(residualFlux)`) plus the zeropoint; MTYPE=STD does NOT
  /// require a named comparison star, so CNAME/CMAG are `na` legitimately.
  ///
  /// Throws if no calibrated magnitude is available — callers must gate on
  /// [aavsoAvailable] (the UI disables the AAVSO format otherwise; it never
  /// emits a `na`-filled DIF row).
  String generateAavsoReport({
    required TransientDetectionRow detection,
    required String observerCode,
    required double magZeroPoint,
    String? starName,
    String? standardBand,
    String? checkStarName,
    double? checkStarMag,
    String chartId = 'na',
  }) {
    if (observerCode.trim().isEmpty) {
      throw ArgumentError('AAVSO observer code is required');
    }
    if (!aavsoAvailable(detection, magZeroPoint: magZeroPoint)) {
      throw ArgumentError(
        'AAVSO needs a calibrated magnitude; gate on aavsoAvailable() first',
      );
    }

    final jd = _toJulianDate(detection.detectedAt);
    final name = (starName?.trim().isNotEmpty == true)
        ? starName!.trim()
        : (detection.catalogMatch ?? _positionName(detection));

    // Standardized magnitude: instrumental mag + zeropoint. residualFlux is the
    // signed template-subtracted flux; the absolute scale comes from the
    // zeropoint, so this is a real standard-system magnitude, not a Δmag.
    final flux = detection.residualFlux.abs();
    final instrumentalMag = flux > 0 ? -2.5 * (_log10(flux)) : 99.999;
    final stdMag = (instrumentalMag + magZeroPoint).clamp(-30.0, 30.0);
    final magStr = stdMag.toStringAsFixed(3);
    final uncertainty = _magUncertainty(detection.snr).toStringAsFixed(3);
    // The band must be the actual standard band the zeropoint standardizes to,
    // not an unsupported 'CV'. Default to TG (clear -> green/V system) only if
    // the caller did not supply a real band.
    final filt = (standardBand?.trim().isNotEmpty == true)
        ? standardBand!.trim()
        : 'TG';
    final kName = (checkStarName?.trim().isNotEmpty == true)
        ? checkStarName!.trim()
        : 'na';
    final kMag = (checkStarMag != null && checkStarMag.isFinite)
        ? checkStarMag.toStringAsFixed(3)
        : 'na';

    final buffer = StringBuffer()
      ..writeln('#TYPE=EXTENDED')
      ..writeln('#OBSCODE=$observerCode')
      ..writeln('#SOFTWARE=Skotiq First Light')
      ..writeln('#DELIM=,')
      ..writeln('#DATE=JD')
      ..writeln('#OBSTYPE=CCD')
      // NAME,DATE,MAGNITUDE,MAGERR,FILT,TRANS,MTYPE,CNAME,CMAG,KNAME,KMAG,
      // AMASS,GROUP,CHART,NOTES
      ..writeln(
        '$name,'
        '${jd.toStringAsFixed(5)},'
        '$magStr,'
        '$uncertainty,'
        '$filt,'
        'NO,' // TRANSFORMED? no
        'STD,' // standardized magnitude — no named comparison star required
        'na,na,' // CNAME,CMAG — ensemble/zeropoint standardized
        '$kName,$kMag,'
        'na,' // AMASS — not stored
        'na,' // GROUP
        '$chartId,'
        'Skotiq difference-image detection vs deep atlas template; '
        'standardized via frame zeropoint; SNR '
        '${detection.snr.toStringAsFixed(1)}',
      );
    return buffer.toString();
  }

  // ── MPC ADES (PSV) ─────────────────────────────────────────────────────────

  /// True when an ADES astrometry report can be built: a 3-char observatory
  /// code is set. ADES astrometry needs only position + time + station +
  /// astCat, all of which we have (astCat defaults to UNK and is flagged).
  bool mpcAdesAvailable({required String observatoryCode}) =>
      observatoryCode.trim().length == 3;

  /// Build an MPC ADES PSV (pipe-separated values) astrometry report.
  ///
  /// Replaces the legacy 80-column format (deprecated for new submissions).
  /// One detection = one optical CCD astrometric observation of an unnumbered,
  /// undesignated object: identified only by a `trkSub` tracklet id, with
  /// magnitude columns omitted cleanly (we have no calibrated mag).
  ///
  /// [astrometricCatalog] is the solver's reference catalog (ADES `astCat`,
  /// e.g. "Gaia2"); empty -> "UNK" (allowed but flagged in a comment).
  /// [observerName] / [submitterName] populate the required header blocks.
  String generateMpcAdesPsv({
    required TransientDetectionRow detection,
    required String observatoryCode,
    required String observerName,
    String? submitterName,
    String? astrometricCatalog,
    String? telescope,
  }) {
    final stn = observatoryCode.trim();
    if (stn.length != 3) {
      throw ArgumentError(
        'MPC observatory code must be exactly 3 characters, got "$stn"',
      );
    }
    final observer = observerName.trim().isNotEmpty
        ? observerName.trim()
        : 'Skotiq observer';
    final submitter = (submitterName?.trim().isNotEmpty == true)
        ? submitterName!.trim()
        : observer;
    final astCat = (astrometricCatalog?.trim().isNotEmpty == true)
        ? astrometricCatalog!.trim()
        : 'UNK';

    // trkSub: 1-8 chars; we have no permID/provID (MPC-assigned for a new
    // object), so permID/provID are omitted and trkSub identifies the tracklet.
    final trkSub = 'NS${detection.id.toString().padLeft(4, '0')}'
        .padRight(8)
        .substring(0, 8)
        .trim();

    final obsTime = _adesObsTime(detection.detectedAt);
    final ra = _normalizeRaDeg(detection.raDeg).toStringAsFixed(6);
    final dec = detection.decDeg.toStringAsFixed(6);

    final header = StringBuffer()
      ..writeln('# version 2022')
      ..writeln('# observatory')
      ..writeln('! mpcCode $stn')
      ..writeln('# submitter')
      ..writeln('! name $submitter')
      ..writeln('# observers')
      ..writeln('! name $observer')
      ..writeln('# measurers')
      ..writeln('! name $observer');
    if (telescope != null && telescope.trim().isNotEmpty) {
      header
        ..writeln('# telescope')
        ..writeln('! design ${telescope.trim()}');
    }
    if (astCat == 'UNK') {
      header.writeln(
        '# comment astCat UNK — solver reference catalog not threaded; '
        'replace before submitting to the MPC',
      );
    }
    header.writeln(
      '# comment Skotiq First Light difference-image astrometry; '
      'SNR ${detection.snr.toStringAsFixed(1)}; kind ${_kind(detection).wire}',
    );

    // Astrometry-only columns (no mag/band/photCat — ADES accepts this).
    const cols = 'trkSub|mode|stn|obsTime|ra|dec|astCat';
    final row = '$trkSub|CCD|$stn|$obsTime|$ra|$dec|$astCat';

    return '${header.toString()}$cols\n$row\n';
  }

  // ── TNS bulk-report JSON ───────────────────────────────────────────────────

  /// Build the TNS `set/bulk-report` JSON payload (the `data` field) for one
  /// detection: `{"at_report": {"0": { ... }}}`.
  ///
  /// Photometry is OMITTED (we have no calibrated discovery magnitude — sending
  /// the instrumental Δmag as a calibrated flux would be a fabrication). The
  /// non_detection block is OMITTED (the atlas template is an implicit prior but
  /// we have no calibrated limiting magnitude). Position errors map from the
  /// SNR-derived uncertainty; required identifiers come from [creds].
  Map<String, dynamic> buildTnsReportJson({
    required TransientDetectionRow detection,
    required TnsCredentials creds,
  }) {
    final report = <String, dynamic>{
      'ra': {
        'value': _normalizeRaDeg(detection.raDeg).toStringAsFixed(6),
        'error': _astrometricErrorArcsec(detection).toStringAsFixed(2),
        'units': 'arcsec',
      },
      'dec': {
        'value': detection.decDeg.toStringAsFixed(6),
        'error': _astrometricErrorArcsec(detection).toStringAsFixed(2),
        'units': 'arcsec',
      },
      'reporting_group_id': creds.reportingGroupId,
      'discovery_data_source_id': creds.dataSourceId,
      'reporter': creds.reporterName.trim(),
      'discovery_datetime': _tnsDateTime(detection.detectedAt),
      'at_type': _tnsAtType(detection),
      'internal_name': 'NS${detection.id}',
      'remarks':
          'Skotiq difference-image detection vs deep personal-atlas '
          'template; kind=${_kind(detection).wire}; '
          'SNR=${detection.snr.toStringAsFixed(1)}; '
          'eccentricity=${detection.eccentricity.toStringAsFixed(2)}',
    };
    return {
      'at_report': {'0': report},
    };
  }

  /// Write [content] to the exports directory under [fileName] and return the
  /// absolute path.
  Future<String> writeReport({
    required String content,
    required String fileName,
  }) async {
    final docsDir = await resolveSkotiqDocumentsDirectory();
    final exportDir = Directory(path.join(docsDir.path, 'Skotiq', 'exports'));
    if (!exportDir.existsSync()) {
      exportDir.createSync(recursive: true);
    }
    final filePath = path.join(exportDir.path, fileName);
    await File(filePath).writeAsString(content);
    return filePath;
  }

  // ── format helpers ─────────────────────────────────────────────────────────

  TransientKind _kind(TransientDetectionRow d) =>
      TransientKind.fromWire(d.kind);

  /// TNS at_type integer code. A new point source / brightening maps to 1
  /// ("PSN", possible SN). A moving streak is not a TNS target (still coded 1
  /// generically; the remarks carry the real shape class).
  int _tnsAtType(TransientDetectionRow detection) => 1;

  /// Rough magnitude uncertainty from SNR: σ_mag ≈ 1.0857 / SNR.
  double _magUncertainty(double snr) {
    if (snr <= 0) return 9.999;
    return (1.0857 / snr).clamp(0.001, 9.999).toDouble();
  }

  /// Crude astrometric position error (arcsec) — we store no rmsRA/rmsDec, so
  /// approximate from FWHM and SNR: σ_pos ≈ FWHM / (2.355 * SNR) in pixels,
  /// reported in arcsec assuming a typical 1.5"/px scale, floored at 0.1".
  double _astrometricErrorArcsec(TransientDetectionRow d) {
    final snr = d.snr <= 0 ? 1.0 : d.snr;
    final fwhmPx = d.fwhm <= 0 ? 3.0 : d.fwhm;
    final sigmaPx = fwhmPx / (2.355 * snr);
    return (sigmaPx * 1.5).clamp(0.1, 60.0).toDouble();
  }

  String _positionName(TransientDetectionRow d) =>
      'NS J${_decimalDegToSexagesimalRa(d.raDeg).replaceAll(':', '')}'
      '${_decimalDegToSexagesimalDec(d.decDeg).replaceAll(':', '')}';

  double _normalizeRaDeg(double raDeg) {
    var ra = raDeg % 360.0;
    if (ra < 0) ra += 360.0;
    return ra;
  }

  double _log10(double x) => math.log(x) / math.ln10;

  /// ADES `obsTime`: ISO-8601 UTC with Z and fractional seconds.
  String _adesObsTime(DateTime dt) {
    final utc = dt.toUtc();
    final iso = utc.toIso8601String();
    // Dart's toIso8601String yields e.g. 2026-06-21T08:14:33.210Z (millis) or
    // without Z if not UTC; toUtc() guarantees Z. Trim to 2 decimal seconds.
    return iso.endsWith('Z') ? iso : '${iso}Z';
  }

  /// TNS `discovery_datetime`: "YYYY-MM-DD HH:MM:SS.sss" UTC.
  String _tnsDateTime(DateTime dt) {
    final u = dt.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final ms = u.millisecond.toString().padLeft(3, '0');
    return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)} '
        '${two(u.hour)}:${two(u.minute)}:${two(u.second)}.$ms';
  }

  /// Convert a UTC [DateTime] to Julian Date.
  double _toJulianDate(DateTime dt) {
    final utc = dt.toUtc();
    final y = utc.month <= 2 ? utc.year - 1 : utc.year;
    final m = utc.month <= 2 ? utc.month + 12 : utc.month;
    final a = (y / 100).floor();
    final b = 2 - a + (a / 4).floor();
    final dayFraction =
        utc.hour / 24.0 +
        utc.minute / 1440.0 +
        utc.second / 86400.0 +
        utc.millisecond / 86400000.0;
    final jd =
        (365.25 * (y + 4716)).floor() +
        (30.6001 * (m + 1)).floor() +
        utc.day +
        dayFraction +
        b -
        1524.5;
    return jd;
  }

  String _decimalDegToSexagesimalRa(double raDeg) {
    var ra = raDeg % 360.0;
    if (ra < 0) ra += 360.0;
    final hours = ra / 15.0;
    final h = hours.floor();
    final mFull = (hours - h) * 60.0;
    final m = mFull.floor();
    final s = (mFull - m) * 60.0;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toStringAsFixed(2).padLeft(5, '0')}';
  }

  String _decimalDegToSexagesimalDec(double decDeg) {
    final sign = decDeg < 0 ? '-' : '+';
    final abs = decDeg.abs();
    final d = abs.floor();
    final mFull = (abs - d) * 60.0;
    final m = mFull.floor();
    final s = (mFull - m) * 60.0;
    return '$sign${d.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toStringAsFixed(1).padLeft(4, '0')}';
  }
}
