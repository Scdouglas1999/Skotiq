// ScienceReportExporter — markdown shape and content guard.
//
// An in-memory database is seeded with a session of light frames, a few
// calibration rows and a transparency sample, and the markdown output is
// asserted to contain the section headers and the headline numbers. Any drift —
// a typo in a section title, a unit swap, a missing field — fails the test.

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

SkotiqDatabase _openInMemory() {
  return SkotiqDatabase.forTesting(NativeDatabase.memory());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ScienceReportExporter exporter;

  setUp(() async {
    db = _openInMemory();
    exporter = ScienceReportExporter(
      imagesDao: ImagesDao(db),
      scienceDao: ScienceDao(db),
      sessionsDao: SessionsDao(db),
      targetsDao: TargetsDao(db),
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedTargetAndSession() async {
    final targetId = await db.targetsDao.createTarget(
      TargetsCompanion.insert(
        name: 'NGC 7000',
        ra: 312.5,
        dec: 44.3,
        constellation: const drift.Value('Cygnus'),
      ),
    );
    final sessionId = await db.sessionsDao.startSession(
      targetId: targetId,
      name: 'Test session',
    );
    return sessionId;
  }

  test('markdown includes every expected section, even when empty', () async {
    final sessionId = await seedTargetAndSession();
    final md = await exporter.buildMarkdown(sessionId);
    for (final heading in [
      '# Skotiq Science Report',
      '## Session',
      '## Frames',
      '## Light curve',
      '## Period analysis',
      '## Photometric calibration',
      '## Transparency',
      '## Field quality',
      '## Filter breakdown',
      '## Moving objects',
    ]) {
      expect(md, contains(heading), reason: 'missing section "$heading"');
    }
    expect(md, contains('NGC 7000'));
    expect(md, contains('No photometric calibration produced this session.'));
    expect(md, contains('No photometry measurements were recorded'));
    expect(md, contains('Not run for this session.'));
    expect(md, contains('No transparency samples produced.'));
  });

  test('markdown reports photometric snapshot when data exists', () async {
    final sessionId = await seedTargetAndSession();
    final dao = db.scienceDao;
    final ts = DateTime.parse('2025-01-01T22:00:00.000Z');

    for (var i = 0; i < 6; i++) {
      await dao.insertFrameCalibration(
        FramePhotometricCalibrationCompanion.insert(
          sessionId: drift.Value(sessionId),
          isCalibrated: const drift.Value(true),
          zeroPoint: drift.Value(24.1 + i * 0.05),
          calibrationRms: const drift.Value(0.04),
          matchedStarCount: const drift.Value(28),
          limitingMag5Sigma: drift.Value(20.8 + i * 0.02),
          catalogSource: const drift.Value('localGaia'),
          timestamp: drift.Value(ts.add(Duration(minutes: i * 5))),
        ),
      );
    }

    await dao.insertTransparencySample(
      TransparencySamplesCompanion.insert(
        sessionId: drift.Value(sessionId),
        transparencyPercent: 87.0,
        extinctionCoefficient: const drift.Value(0.21),
        qualityBucket: const drift.Value('good'),
        confidence: const drift.Value(0.78),
        timestamp: drift.Value(ts),
      ),
    );

    final md = await exporter.buildMarkdown(sessionId);
    expect(md, contains('Latest zero point'));
    // The latest ZP is the 6th value (24.10 + 5*0.05 = 24.35) so we expect
    // exactly "24.35".
    expect(md, contains('24.35'));
    expect(md, contains('Median ZP across 6 frames'));
    expect(md, contains('- **Catalog source:** localGaia'));
    expect(md, contains('87% (good)'));
  });

  // Audit 2026-08-03: "Export report" produced a Science Report with no light
  // curve at all for a session holding 80 photometry measurements — the
  // exporter never read photometry_measurements — and the only
  // photometry-shaped heading said "No photometric calibration produced this
  // session", which reads as "you have no photometry".
  test('markdown reports the light curve when measurements exist', () async {
    final sessionId = await seedTargetAndSession();
    final ts = DateTime.parse('2025-01-01T22:00:00.000Z');

    await db.scienceDao.insertPhotometryMeasurements([
      for (var i = 0; i < 8; i++)
        PhotometryMeasurementsCompanion.insert(
          sessionId: drift.Value(sessionId),
          objectId: 'V0376 Per',
          role: const drift.Value('target'),
          x: 100.0,
          y: 100.0,
          flux: 12000.0 + i,
          differentialMagnitude: drift.Value(-0.5 + i * 0.01),
          uncertainty: const drift.Value(0.004),
          timestamp: drift.Value(ts.add(Duration(minutes: i))),
        ),
      PhotometryMeasurementsCompanion.insert(
        sessionId: drift.Value(sessionId),
        objectId: 'COMP-1',
        role: const drift.Value('comparison'),
        x: 300.0,
        y: 220.0,
        flux: 9000.0,
        timestamp: drift.Value(ts),
      ),
    ]);

    final md = await exporter.buildMarkdown(sessionId);
    expect(md, contains('## Light curve'));
    expect(md, contains('**Points:** 8'));
    expect(md, contains('V0376 Per'));
    expect(md, contains('COMP-1'));
    expect(md, contains('2025-01-01T22:00:00.000Z'));
    expect(md, contains('2025-01-01T22:07:00.000Z'));
    expect(md, contains('Differential magnitude:'));
    expect(md, isNot(contains('No photometry measurements were recorded')));
  });

  test('markdown reports the period search when one was run', () async {
    final sessionId = await seedTargetAndSession();
    const period = PeriodAnalysisResult(
      lombScargle: LombScargleResult(
        frequencies: [1.0],
        powers: [0.9],
        bestFrequency: 2.5,
        bestPeriod: 0.4,
        peakPower: 0.91,
        falseAlarmProbability: 1.2e-5,
        timeBaseline: 3.2,
        searchedMinPeriod: 0.05,
        searchedMaxPeriod: 1.6,
      ),
      bls: BlsResult(
        bestPeriod: 0.4001,
        transitDurationFraction: 0.05,
        transitDuration: 0.02,
        transitDepth: 0.031,
        signalResidueStatistic: 0.4,
        signalDetectionEfficiency: 9.4,
        transitMidPhase: 0.5,
        trialPeriods: [0.4],
        srSpectrum: [0.4],
      ),
    );

    final md = await exporter.buildMarkdown(sessionId, period: period);
    expect(md, contains('## Period analysis'));
    expect(md, contains('Lomb-Scargle best period:** 0.400000 d'));
    expect(md, contains('FAP 1.20e-5'));
    expect(md, contains('Searched range:** 0.0500 – 1.6000 d'));
    expect(md, contains('BLS best period:** 0.400100 d'));
    expect(md, contains('SDE 9.40'));
    expect(md, isNot(contains('Not run for this session.')));
  });

  // A report is shared: it goes to the AAVSO, the MPC, a forum thread. Drift
  // hands session times back as LOCAL DateTimes, and printing one raw gives an
  // ISO-8601-SHAPED string with no offset and no Z, a few lines above a
  // light-curve block explicitly labelled UTC — ambiguous by up to a day to
  // whoever reads it. Asserted structurally (label + exact UTC instant) so the
  // test is decisive on a machine whose local zone happens to be UTC too.
  test('session start/end are printed as labelled UTC instants', () async {
    final sessionId = await seedTargetAndSession();
    await db.sessionsDao.endSession(sessionId);
    final session = await db.sessionsDao.getSessionById(sessionId);
    final md = await exporter.buildMarkdown(sessionId);

    expect(
      md,
      contains(
        '- **Started (UTC):** ${session!.startTime.toUtc().toIso8601String()}',
      ),
    );
    expect(
      md,
      contains(
        '- **Ended (UTC):** ${session.endTime!.toUtc().toIso8601String()}',
      ),
    );
    // The unlabelled forms must not appear: a bare local time is ambiguous.
    expect(md, isNot(contains('- **Started:**')));
    expect(md, isNot(contains('- **Ended:**')));
  });
}
