// The post-session, finishing, mosaic, calibration-master and recovery
// decoders read the replies the native side writes: each sample in
// test_fixtures/ffi_replies/ is serialized by a Rust test from the reply type
// itself, with every field set. A decoder must read every key of its sample
// (or name it here as one it leaves to another reader) and decode the value
// the sample holds, so a key renamed in Rust fails here instead of decoding
// as a default.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

import '../harness/reply_fixture.dart';

/// Keys under [prefix] the decoder hands on whole instead of reading.
Set<String> _under(Set<String> keys, String prefix) =>
    keys.where((k) => k.startsWith(prefix)).toSet();

double _d(Object? v) => (v! as num).toDouble();

void main() {
  test('integrateSession decodes every field of the native reply', () {
    final reply = replyFixtureObject('integrate_session');
    final (result, unread) = decodeRecordingReads(
      reply,
      IntegrateSessionResult.fromJson,
    );
    // The calibration report is carried whole into stats_json.
    expect(unread.difference(_under(unread, 'calibration.')), isEmpty);
    expect(result.masterFitsPath, reply['masterFitsPath']);
    expect(result.previewPath, reply['previewPath']);
    expect(result.rejectionMapPath, reply['rejectionMapPath']);
    expect(result.rejectionMapPreviewPath, reply['rejectionMapPreviewPath']);
    expect(result.framesIntegrated, reply['framesIntegrated']);
    expect(result.framesRejected, reply['framesRejected']);
    expect(result.totalIntegrationSec, _d(reply['totalIntegrationSec']));
    expect(result.rmsResidual, _d(reply['rmsResidual']));
    expect(result.width, reply['width']);
    expect(result.height, reply['height']);
    expect(result.channels, reply['channels']);
    expect(result.calibration, reply['calibration']);
    final frames = (reply['perFrameStats'] as List)
        .cast<Map<String, dynamic>>();
    expect(result.perFrameStats, hasLength(frames.length));
    for (var i = 0; i < frames.length; i++) {
      // The record writes back the keys it read, with the values it read.
      final written = result.perFrameStats[i].toJson();
      for (final entry in frames[i].entries) {
        final value = entry.value;
        expect(
          written[entry.key],
          value is List ? [for (final v in value) _d(v)] : value,
          reason: 'perFrameStats[$i].${entry.key}',
        );
      }
    }
  });

  test('the native integration reply names no coverage map; the decoder reads '
      'none from it', () {
    final reply = replyFixtureObject('integrate_session');
    final result = IntegrateSessionResult.fromJson(reply);
    expect(reply.containsKey('coverageMapPath'), isFalse);
    expect(result.coverageMapPath, isNull);
    expect(result.coverageMapPreviewPath, isNull);
  });

  test('masterAccumulate decodes every field the app uses', () {
    final reply = replyFixtureObject('master_accumulate');
    final (result, unread) = decodeRecordingReads(
      reply,
      MasterAccumulateResult.fromJson,
    );
    // This fold's calibration report and log warning are written by the
    // native side into the master's calibration log; the app does not read
    // them from the reply.
    expect(
      unread.difference(_under(unread, 'calibration')),
      isEmpty,
      reason: '$unread',
    );
    expect(result.sidecarPath, reply['sidecarPath']);
    expect(result.masterPath, reply['masterPath']);
    expect(result.previewPath, reply['previewPath']);
    expect(result.frameCount, reply['frameCount']);
    expect(result.totalIntegrationSec, _d(reply['totalIntegrationSec']));
    expect(result.width, reply['width']);
    expect(result.height, reply['height']);
    expect(result.channels, reply['channels']);
    expect(result.framesAdded, reply['framesAdded']);
    expect(result.rejected, reply['rejected']);
    expect(result.frameWeights, [
      for (final w in reply['frameWeights'] as List) _d(w),
    ]);
  });

  test('buildMasterFlat decodes every field of the native reply', () {
    final reply = replyFixtureObject('build_master_flat');
    final (result, unread) = decodeRecordingReads(
      reply,
      BuildMasterFlatResult.fromJson,
    );
    // The exclusion reason is shown from the build log, not this reply.
    expect(unread, {'excluded[].reason'});
    expect(result.outputPath, reply['outputPath']);
    expect(result.frameCount, reply['frameCount']);
    expect(result.inputMean, _d(reply['inputMean']));
    expect(result.outputMean, _d(reply['outputMean']));
    expect(result.width, reply['width']);
    expect(result.height, reply['height']);
    expect(result.channels, reply['channels']);
    expect(result.outputBitDepth, reply['outputBitDepth']);
    expect(result.excluded, [
      for (final e in reply['excluded'] as List) (e as Map)['path'],
    ]);
  });

  test('saveFitsMaster decodes every field of the native reply', () {
    final reply = replyFixtureObject('save_fits_master');
    final (result, unread) = decodeRecordingReads(
      reply,
      SaveFitsMasterResult.fromJson,
    );
    expect(unread, isEmpty);
    expect(result.outputPath, reply['outputPath']);
    expect(result.width, reply['width']);
    expect(result.height, reply['height']);
    expect(result.channels, reply['channels']);
    expect(result.pixelType, reply['pixelType']);
  });

  test('buildCalibrationMaster decodes every field of the native reply', () {
    final reply = replyFixtureObject('build_calibration_master');
    final (result, unread) = decodeRecordingReads(
      reply,
      CalibrationMasterBuildResult.fromJson,
    );
    expect(unread, isEmpty);
    expect(result.outputPath, reply['outputPath']);
    expect(result.kind, reply['kind']);
    expect(result.width, reply['width']);
    expect(result.height, reply['height']);
    expect(result.frameCount, reply['frameCount']);
    expect(result.leakingFrames, reply['leakingFrames']);
    final levels = (reply['frameLevels'] as List).cast<Map<String, dynamic>>();
    expect(result.frameLevels.map((l) => l.path), [
      for (final l in levels) l['path'],
    ]);
    expect(result.frameLevels.map((l) => l.level), [
      for (final l in levels) _d(l['level']),
    ]);
    expect(result.frameLevels.map((l) => l.noise), [
      for (final l in levels) _d(l['noise']),
    ]);
    expect(result.leakBaseline, _d(reply['leakBaseline']));
    expect(result.leakThreshold, _d(reply['leakThreshold']));
    expect(result.masterMean, _d(reply['masterMean']));
    expect(result.rejectionFraction, _d(reply['rejectionFraction']));
    expect(result.exposureSecs, _d(reply['exposureSecs']));
    expect(result.gain, reply['gain']);
    expect(result.offset, reply['offset']);
    expect(result.binX, reply['binX']);
    expect(result.binY, reply['binY']);
    expect(result.ccdTempMean, _d(reply['ccdTempMean']));
    expect(result.setTemp, _d(reply['setTemp']));
  });

  test('analyzeNight decodes every field of the native reply', () {
    final reply = replyFixtureObject('analyze_night');
    final (curve, unread) = decodeRecordingReads(
      reply,
      IntegrationCurve.fromJson,
    );
    expect(unread, isEmpty);
    final points = (reply['curve'] as List).cast<Map<String, dynamic>>();
    expect(curve.points, hasLength(points.length));
    for (var i = 0; i < points.length; i++) {
      expect(curve.points[i].n, points[i]['n']);
      expect(curve.points[i].snr, _d(points[i]['snr']));
      expect(curve.points[i].fwhm, _d(points[i]['fwhm']));
      expect(
        curve.points[i].cumulativeIntegrationS,
        _d(points[i]['cumulativeIntegrationS']),
      );
    }
    final rec = reply['recommendation'] as Map<String, dynamic>;
    expect(curve.recommendation.keepN, rec['keepN']);
    expect(curve.recommendation.keptIndices, rec['keptIndices']);
    expect(
      curve.recommendation.predictedSnrGainPct,
      _d(rec['predictedSnrGainPct']),
    );
    expect(curve.recommendation.reason, rec['reason']);
  });

  test('detectStarsPhotometry decodes every field of the native reply', () {
    final reply = replyFixtureObject('detect_stars_photometry');
    final (result, unread) = decodeRecordingReads(
      reply,
      StarPhotometryResult.fromJson,
    );
    expect(unread, isEmpty);
    expect(result.width, reply['width']);
    expect(result.height, reply['height']);
    expect(result.channels, reply['channels']);
    final stars = (reply['stars'] as List).cast<Map<String, dynamic>>();
    expect(result.stars, hasLength(stars.length));
    final star = result.stars.single;
    final sample = stars.single;
    expect(star.x, _d(sample['x']));
    expect(star.y, _d(sample['y']));
    expect(star.flux, _d(sample['flux']));
    expect(star.snr, _d(sample['snr']));
    expect(star.hfr, _d(sample['hfr']));
    expect(star.fwhm, _d(sample['fwhm']));
    expect(star.eccentricity, _d(sample['eccentricity']));
    expect(star.peak, _d(sample['peak']));
    expect(star.channelFlux, [
      for (final f in sample['channelFlux'] as List) _d(f),
    ]);
  });

  test('colorCalibrate decodes every field of the native reply', () {
    final reply = replyFixtureObject('color_calibrate');
    final (result, unread) = decodeRecordingReads(
      reply,
      ColorCalibrationResult.fromJson,
    );
    expect(unread, isEmpty);
    expect(result.outputPath, reply['outputPath']);
    expect(result.channelScale, [
      for (final s in reply['channelScale'] as List) _d(s),
    ]);
    expect(result.matched, reply['matched']);
    expect(result.residual, _d(reply['residual']));
  });

  test('stitchMosaic decodes every field of the native reply', () {
    final reply = replyFixtureObject('stitch_mosaic');
    final (result, unread) = decodeRecordingReads(
      reply,
      MosaicStitchResult.fromJson,
    );
    expect(unread, isEmpty);
    expect(result.outputPath, reply['outputPath']);
    expect(result.coveragePath, reply['coveragePath']);
    expect(result.previewPath, reply['previewPngPath']);
    expect(result.outWidth, reply['outWidth']);
    expect(result.outHeight, reply['outHeight']);
    expect(result.overlapPairs, reply['overlapPairs']);
    expect(result.meanPanelGain, _d(reply['meanPanelGain']));
  });

  test('the enhance replies name the file they wrote', () {
    for (final name in [
      'extract_background',
      'deconvolve_preview',
      'reduce_stars_preview',
    ]) {
      final reply = replyFixtureObject(name);
      expect(postSessionOutputPath(reply), reply['outputPath'], reason: name);
    }
  });

  test('every recovery cause and phase the native side sends decodes', () {
    final history = (replyFixture('recovery_history')! as List)
        .cast<Map<String, dynamic>>();
    final kinds = <String>{};
    final phases = <RecoveryPhase>{};
    for (final entry in history) {
      final (status, unread) = decodeRecordingReads(
        entry,
        RecoveryStatus.fromJson,
      );
      expect(unread, isEmpty);
      expect(status.startedAt, DateTime.parse(entry['started_at'] as String));
      expect(
        status.lastAttemptAt,
        entry['last_attempt_at'] == null
            ? null
            : DateTime.parse(entry['last_attempt_at'] as String),
      );
      expect(status.attemptCount, entry['attempt_count']);
      expect(status.maxAttempts, entry['max_attempts']);
      expect(status.retryIntervalSecs, _d(entry['retry_interval_secs']));
      expect(status.maxDurationSecs, _d(entry['max_duration_secs']));
      expect(status.lastError, entry['last_error']);
      expect(status.cause.displayLabel, isNot(startsWith('Unknown')));
      kinds.add(status.cause.kind);
      phases.add(status.phase);
    }
    expect(phases, RecoveryPhase.values.toSet());
    expect(kinds, hasLength(9));
  });
}
