import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

TransientDetectionRow _detection({
  int id = 1,
  double raDeg = 187.7059,
  double decDeg = 12.3911,
  double? deltaMag,
  double snr = 18.0,
  String kind = 'newSource',
  String? catalogMatch,
  bool reviewed = true,
  bool dismissed = false,
}) {
  return TransientDetectionRow(
    id: id,
    tileId: 42,
    detectedAt: DateTime.utc(2026, 6, 20, 6, 30, 0),
    raDeg: raDeg,
    decDeg: decDeg,
    residualFlux: 5000.0,
    deltaMag: deltaMag,
    snr: snr,
    fwhm: 2.1,
    eccentricity: 0.1,
    positionAngleDeg: 0.0,
    kind: kind,
    catalogMatch: catalogMatch,
    confidence: 0.8,
    reviewed: reviewed,
    dismissed: dismissed,
  );
}

void main() {
  final service = TransientReportService();

  group('MPC ADES PSV report', () {
    test('emits a 2022 header block + trkSub-identified astrometry row', () {
      final report = service.generateMpcAdesPsv(
        detection: _detection(kind: 'movingStreak'),
        observatoryCode: 'G40',
        observerName: 'S. Douglas',
        astrometricCatalog: 'Gaia2',
      );
      final lines = report.trim().split('\n');
      // Header keys present.
      expect(report, contains('# version 2022'));
      expect(report, contains('! mpcCode G40'));
      expect(report, contains('! name S. Douglas'));
      // Column header + one data row.
      final colLine = lines.firstWhere((l) => l.startsWith('trkSub|'));
      final cols = colLine.split('|');
      final dataLine = lines.last;
      final row = dataLine.split('|');
      expect(cols.length, row.length);
      expect(cols, containsAllInOrder(['trkSub', 'mode', 'stn', 'obsTime']));
      // No permID/provID for a new object — trkSub identifies the tracklet.
      expect(row[0], startsWith('NS'));
      expect(row[1], 'CCD');
      expect(row[2], 'G40');
      // obsTime is ISO-8601 UTC with Z.
      expect(row[3], endsWith('Z'));
      // ra/dec are decimal degrees (not sexagesimal), J2000.
      expect(double.parse(row[4]), closeTo(187.7059, 1e-4));
      expect(double.parse(row[5]), closeTo(12.3911, 1e-4));
      // astCat threaded through, not fabricated.
      expect(row[6], 'Gaia2');
    });

    test('flags astCat UNK when the solver catalog is unknown', () {
      final report = service.generateMpcAdesPsv(
        detection: _detection(kind: 'movingStreak'),
        observatoryCode: 'G40',
        observerName: 'S. Douglas',
      );
      expect(report, contains('astCat UNK'));
      expect(report.trim().split('\n').last, endsWith('|UNK'));
    });

    test('rejects a non-3-char observatory code', () {
      expect(
        () => service.generateMpcAdesPsv(
          detection: _detection(),
          observatoryCode: 'XX',
          observerName: 'S. Douglas',
        ),
        throwsArgumentError,
      );
    });
  });

  group('AAVSO report (ingestible STD)', () {
    test('emits an STD row with no na-stuffed comparison star', () {
      final report = service.generateAavsoReport(
        detection: _detection(deltaMag: -0.7, catalogMatch: 'V0123 Cyg'),
        observerCode: 'ABC',
        magZeroPoint: 22.5,
        standardBand: 'V',
      );
      expect(report, contains('#TYPE=EXTENDED'));
      expect(report, contains('#OBSCODE=ABC'));
      expect(report, contains('#SOFTWARE=Skotiq First Light'));
      expect(report, contains('V0123 Cyg'));
      final dataLine = report.trim().split('\n').last;
      final fields = dataLine.split(',');
      // 15 Extended-format fields.
      expect(fields.length, 15);
      // MTYPE (index 6) is STD — does NOT require a named comparison star.
      expect(fields[6], 'STD');
      // FILT (index 4) is the real band, not the unsupported 'CV'.
      expect(fields[4], 'V');
    });

    test('aavsoAvailable is false without a photometric zeropoint', () {
      final d = _detection(deltaMag: -0.7);
      expect(service.aavsoAvailable(d, magZeroPoint: null), isFalse);
      expect(service.aavsoAvailable(d, magZeroPoint: 22.5), isTrue);
    });

    test('disabled reason explains the missing calibrated magnitude', () {
      final reason = service.aavsoDisabledReason(
        _detection(deltaMag: -0.7),
        observerCode: 'ABC',
        magZeroPoint: null,
      );
      expect(reason, isNotNull);
      expect(reason, contains('calibrated magnitude'));
    });

    test(
      'disabled reason names BOTH blockers on a fresh, uncalibrated frame',
      () {
        // The state a fresh profile is actually in. Reporting only the observer
        // code named the one blocker Settings can fix and hid the one it cannot,
        // so the operator set the field the app pointed at and came back to an
        // AAVSO that was still disabled for a different reason. This string is
        // rendered by the report panel AND returned as the headless
        // /api/firstlight/<id>/export/aavso 400 body.
        final reason = service.aavsoDisabledReason(
          _detection(deltaMag: -0.7),
          observerCode: '',
          magZeroPoint: null,
        );
        expect(reason, isNotNull);
        expect(reason, contains('photometric zeropoint'));
        expect(reason, contains('observer code'));
        expect(
          reason,
          isNot(contains('first')),
          reason: 'the observer code is not the only thing in the way',
        );
      },
    );

    test(
      'disabled reason is the observer code alone when that is the only gap',
      () {
        final reason = service.aavsoDisabledReason(
          _detection(deltaMag: -0.7),
          observerCode: '   ',
          magZeroPoint: 22.5,
        );
        expect(
          reason,
          'Set your AAVSO observer code in Settings > Science '
          'first.',
        );
      },
    );

    test('disabled reason is null once both requirements are met', () {
      expect(
        service.aavsoDisabledReason(
          _detection(deltaMag: -0.7),
          observerCode: 'ABC',
          magZeroPoint: 22.5,
        ),
        isNull,
      );
    });

    test(
      'throws when no calibrated magnitude is available (caller must gate)',
      () {
        expect(
          () => service.generateAavsoReport(
            detection: _detection(deltaMag: null),
            observerCode: 'ABC',
            magZeroPoint: 22.5,
          ),
          throwsArgumentError,
        );
      },
    );
  });

  group('TNS bulk-report JSON', () {
    const creds = TnsCredentials(
      botId: 12345,
      botName: 'SkotiqBot',
      reportingGroupId: 42,
      dataSourceId: 7,
      reporterName: 'S. Douglas',
      apiKey: 'secret',
    );

    test('builds the at_report.0 structure with required fields', () {
      final json = service.buildTnsReportJson(
        detection: _detection(),
        creds: creds,
      );
      expect(json.containsKey('at_report'), isTrue);
      final report = (json['at_report'] as Map)['0'] as Map<String, dynamic>;
      expect(report['reporting_group_id'], 42);
      expect(report['discovery_data_source_id'], 7);
      expect(report['reporter'], 'S. Douglas');
      expect(report['internal_name'], 'NS1');
      // ra/dec are nested {value,error,units} blocks.
      final ra = report['ra'] as Map<String, dynamic>;
      expect(double.parse(ra['value'] as String), closeTo(187.7059, 1e-4));
      expect(ra['units'], 'arcsec');
      // discovery_datetime is "YYYY-MM-DD HH:MM:SS.sss".
      expect(
        report['discovery_datetime'],
        matches(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$'),
      );
      // No fabricated photometry block (we have no calibrated mag).
      expect(report.containsKey('photometry'), isFalse);
      expect(report.containsKey('non_detection'), isFalse);
    });

    test('credentials completeness gate', () {
      expect(creds.isComplete, isTrue);
      const missingKey = TnsCredentials(
        botId: 12345,
        botName: 'SkotiqBot',
        reportingGroupId: 42,
        dataSourceId: 7,
        reporterName: 'S. Douglas',
        apiKey: '',
      );
      expect(missingKey.isComplete, isFalse);
    });
  });

  group('alert mapper', () {
    test('maps an unnamed new source to a supernova-class new alert', () {
      final alert = transientAlertFromDetection(_detection(reviewed: false));
      expect(alert.id, 'firstlight:1');
      expect(alert.type, TransientType.supernova);
      expect(alert.state, TransientAlertState.newAlert);
      expect(alert.source, TransientSource.manual);
    });

    test('maps a moving streak to an asteroid alert', () {
      final alert = transientAlertFromDetection(
        _detection(kind: 'movingStreak'),
      );
      expect(alert.type, TransientType.asteroid);
    });

    test('maps a named brightening to a variable-star alert', () {
      final alert = transientAlertFromDetection(
        _detection(
          kind: 'pointBrightening',
          deltaMag: -0.8,
          catalogMatch: 'V0123 Cyg',
        ),
      );
      expect(alert.type, TransientType.variableStar);
      expect(alert.name, 'V0123 Cyg');
      // `magnitude` is an APPARENT magnitude — the card buckets it NAKED EYE /
      // BINOCULAR and `shouldNotify` auto-queues on it. A difference-image
      // delta is not one, and there is no zero point behind these detections,
      // so it stays null and the change is reported as a change.
      expect(alert.magnitude, isNull);
      expect(alert.classification, contains('Δ0.80 mag brighter'));
    });

    test('a dismissed detection maps to a dismissed alert', () {
      final alert = transientAlertFromDetection(_detection(dismissed: true));
      expect(alert.state, TransientAlertState.dismissed);
    });
  });
}
