part of '../night_analysis_service.dart';

extension _NightAnalysisDetectors on NightAnalysisService {
  /// **Focus drift.** A slow, monotone rise in HFR over the night — usually
  /// thermal focus shift the autofocus didn't keep up with. Fires when the
  /// later-half median HFR is materially above the earlier-half median AND the
  /// HFR-vs-time correlation is strongly positive (so a single bad sub doesn't
  /// trip it). Reports the trend strength and ties it to focuser temperature
  /// drift when that signal is present.
  List<NightFinding> _detectFocusDrift(NightData data) {
    final pts = data.subs
        .where((s) => s.hfr != null)
        .map((s) => (sub: s, hfr: s.hfr!))
        .toList(growable: false);
    if (pts.length < 8) return const [];

    final times = [
      for (final p in pts) p.sub.capturedAt.millisecondsSinceEpoch.toDouble(),
    ];
    final hfrs = [for (final p in pts) p.hfr];
    final r = _pearson(times, hfrs);
    if (r == null || r < 0.6) return const [];

    final mid = pts.length ~/ 2;
    final early = _median([for (var i = 0; i < mid; i++) hfrs[i]]);
    final late = _median([for (var i = mid; i < hfrs.length; i++) hfrs[i]]);
    if (early == null || late == null) return const [];
    final rise = late - early;
    final relRise = early > 0 ? rise / early : 0.0;
    // Require a meaningful absolute and relative climb, not just a clean slope.
    if (rise < 0.3 || relRise < 0.12) return const [];

    final tempDrift = _focuserTempDrift(pts.map((p) => p.sub));
    final severity = relRise >= 0.30
        ? NightFindingSeverity.critical
        : NightFindingSeverity.warn;

    final firstWorse = pts.indexWhere((p) => p.hfr > early + rise * 0.5);
    final evidence = [
      for (var i = math.max(0, firstWorse); i < pts.length; i++) pts[i].sub.id,
    ];

    final tempClause = tempDrift != null
        ? ' Focuser temperature moved ${tempDrift.toStringAsFixed(1)} C over '
              'the same window, so this is almost certainly thermal.'
        : '';

    return [
      NightFinding(
        id: 'focus_drift',
        severity: severity,
        title: 'Focus drifted through the night',
        explanation:
            'Median HFR climbed from ${early.toStringAsFixed(2)} to '
            '${late.toStringAsFixed(2)} px (a '
            '${(relRise * 100).round()}% increase) with a steadily rising '
            'trend.$tempClause',
        advice: tempDrift != null
            ? 'Enable temperature-compensated autofocus, or trigger a refocus '
                  'every ~1 C of focuser temperature change.'
            : 'Refocus more often (e.g. every 30-45 min or after each filter '
                  'change) so HFR stays flat across the session.',
        evidenceSubIds: evidence.isEmpty
            ? pts.map((p) => p.sub.id).toList()
            : evidence,
        metricSeries: hfrs,
      ),
    ];
  }

  /// **Cloud / transparency loss.** A robust baseline (median + MAD) is built
  /// from the brightest-throughput signal available — background-corrected SNR
  /// when the science table is present, otherwise `starCount`. Subs that step
  /// well below baseline are clustered into consecutive *events*; each event of
  /// sufficient length becomes one finding. This is the only detector that
  /// groups consecutive bad subs rather than reasoning over the whole night.
  List<NightFinding> _detectCloudTransparencyLoss(NightData data) {
    // Choose one signal for the whole night up front. Science SNR is the better
    // throughput proxy, but only when it covers (essentially) the full session —
    // a defaulted-0.0 snr is already dropped at load, so `s.snr != null` here is
    // a real reading. Picking SNR mode on partial coverage would (a) drop every
    // sub the pipeline never reached, corrupting the baseline, and (b) fire on a
    // single 0-SNR row. So switch to SNR only with >=80% positive coverage and a
    // healthy absolute sample; otherwise use `starCount`, which is present for
    // essentially every sub. Both signals are never mixed into one baseline.
    final snrCount = data.subs.where((s) => s.snr != null).length;
    final useSnr = snrCount >= 8 && snrCount >= (data.subs.length * 0.8).ceil();

    final pts = <({NightSub sub, double value})>[];
    for (final s in data.subs) {
      final v = useSnr ? s.snr : s.starCount?.toDouble();
      if (v != null) pts.add((sub: s, value: v));
    }
    if (pts.length < 8) return const [];

    final values = [for (final p in pts) p.value];
    final baseline = _median(values);
    final mad = _mad(values, baseline);
    if (baseline == null || mad == null || baseline <= 0) return const [];
    // A sub is "bad" when it falls > 3 robust deviations below the night's
    // typical throughput. MAD*1.4826 ≈ sigma for a normal core. When the
    // baseline is very clean (a few sharp outliers leave MAD ≈ 0, which would
    // make the robust threshold degenerate) we fall back to a pure relative
    // floor: a sub at < 75% of baseline is a transparency dropout regardless of
    // spread. Either rule alone is enough to flag a sub.
    final sigma = mad * 1.4826;
    final robustThreshold = baseline - 3.0 * sigma;
    final robustUsable = sigma > baseline * 0.01;
    final relativeFloor = baseline * 0.75;

    final bad = [
      for (final p in pts)
        p.value < relativeFloor && (!robustUsable || p.value < robustThreshold),
    ];

    // Cluster bad subs into events, but treat two bad subs as part of the same
    // event only when they are also *temporally* adjacent — i.e. no good sub was
    // captured between them. `pts` is time-sorted (NightData sorts on capturedAt)
    // but may still skip subs that lack the chosen signal; walking raw `pts`
    // indices would let a coverage gap make two distant dropouts look
    // consecutive and over-escalate severity. Requiring no intervening *good*
    // sub keys the run on real capture-time adjacency.
    final findings = <NightFinding>[];
    var i = 0;
    while (i < bad.length) {
      if (!bad[i]) {
        i++;
        continue;
      }
      var j = i;
      while (j < bad.length && bad[j]) {
        j++;
      }
      final runLen = j - i;
      // A single dropout is noise; a cluster of >=2 consecutive bad subs is an
      // event worth surfacing.
      if (runLen >= 2) {
        final eventSubs = [for (var k = i; k < j; k++) pts[k].sub];
        final worst = [
          for (var k = i; k < j; k++) pts[k].value,
        ].reduce(math.min);
        final dropPct = ((baseline - worst) / baseline * 100).clamp(0, 100);
        final metric = useSnr ? 'SNR' : 'star count';
        final severity = runLen >= 4 || dropPct >= 60
            ? NightFindingSeverity.critical
            : NightFindingSeverity.warn;
        findings.add(
          NightFinding(
            id: 'cloud_transparency',
            severity: severity,
            title: 'Transparency dropped (likely clouds)',
            explanation:
                '$runLen consecutive subs show $metric falling up to '
                '${dropPct.round()}% below the night baseline — a transparency '
                'loss consistent with passing cloud.',
            advice:
                'Cull these subs from the integration. If clouds recur, add a '
                'sky-quality / cloud guard so the sequence pauses instead of '
                'wasting frames.',
            evidenceSubIds: eventSubs.map((s) => s.id).toList(),
            metricSeries: [for (var k = i; k < j; k++) pts[k].value],
          ),
        );
      }
      i = j;
    }
    return findings;
  }

  /// **Guiding correlation.** Subs whose per-sub guiding RMS spikes well above
  /// the night's typical RMS *and* show elongated stars (high eccentricity) are
  /// flagged — the elongation confirms the guiding error actually smeared the
  /// frame rather than being a harmless transient. Needs both
  /// `guidingRmsTotal` and `eccentricity`; silent if either is absent.
  List<NightFinding> _detectGuidingCorrelation(NightData data) {
    final pts = data.subs
        .where((s) => s.guidingRmsTotal != null && s.eccentricity != null)
        .toList(growable: false);
    if (pts.length < 6) return const [];

    final rms = [for (final s in pts) s.guidingRmsTotal!];
    final ecc = [for (final s in pts) s.eccentricity!];
    final baseRms = _median(rms);
    final madRms = _mad(rms, baseRms);
    final baseEcc = _median(ecc);
    if (baseRms == null || madRms == null || baseEcc == null) return const [];

    final rmsThreshold = baseRms + 3.0 * (madRms * 1.4826);
    // Elongation threshold: clearly rounder-than-typical fails; use an absolute
    // floor so a night of already-round stars doesn't trip on tiny wobble.
    final eccThreshold = math.max(baseEcc + 0.12, 0.55);

    final culprits = [
      for (final s in pts)
        if (s.guidingRmsTotal! > rmsThreshold && s.eccentricity! > eccThreshold)
          s,
    ];
    // Need a real correlation, not one coincidental sub.
    if (culprits.length < 2) return const [];

    final worstRms = culprits.map((s) => s.guidingRmsTotal!).reduce(math.max);
    final severity = worstRms > baseRms * 2.0
        ? NightFindingSeverity.critical
        : NightFindingSeverity.warn;

    return [
      NightFinding(
        id: 'guiding_correlation',
        severity: severity,
        title: 'Guiding spikes elongated your stars',
        explanation:
            '${culprits.length} subs show guiding RMS up to '
            '${worstRms.toStringAsFixed(2)}" (vs a '
            '${baseRms.toStringAsFixed(2)}" baseline) together with elongated '
            'stars — the guiding error directly cost frame sharpness.',
        advice:
            'Cull the affected subs. Investigate the cause (wind, cable snag, '
            'differential flexure, or aggressive guide settings) and consider '
            'dithering / lower guide aggressiveness.',
        evidenceSubIds: culprits.map((s) => s.id).toList(),
        metricSeries: rms,
      ),
    ];
  }

  /// **Dew / HFR collapse.** A *sharp, irreversible* HFR jump combined with star
  /// loss — the optics fogging over. Distinct from focus drift (which is slow
  /// and monotone): here HFR steps up at one point and never recovers, and the
  /// star count falls off a cliff. Fires on the first such collapse point.
  List<NightFinding> _detectDewHfrCollapse(NightData data) {
    final pts = data.subs.where((s) => s.hfr != null).toList(growable: false);
    if (pts.length < 6) return const [];

    final hfrs = [for (final s in pts) s.hfr!];
    // Scan for a step where HFR jumps sharply and stays high afterwards.
    for (var k = 2; k < pts.length - 1; k++) {
      final before = _median([for (var i = 0; i < k; i++) hfrs[i]]);
      final afterVals = [for (var i = k; i < hfrs.length; i++) hfrs[i]];
      final after = _median(afterVals);
      if (before == null || after == null || before <= 0) continue;

      final ratio = after / before;
      // Irreversible: the post-collapse minimum never returns near baseline.
      final afterMin = afterVals.reduce(math.min);
      final recovered = afterMin < before * 1.3;
      final stepUp = hfrs[k] / before;

      if (ratio >= 1.6 && stepUp >= 1.4 && !recovered) {
        // Confirm star loss across the same boundary when star counts exist.
        final starsBefore = _median(
          [
            for (var i = 0; i < k; i++) pts[i].starCount?.toDouble(),
          ].whereType<double>().toList(),
        );
        final starsAfter = _median(
          [
            for (var i = k; i < pts.length; i++) pts[i].starCount?.toDouble(),
          ].whereType<double>().toList(),
        );
        final starLoss =
            (starsBefore != null && starsAfter != null && starsBefore > 0)
            ? starsAfter < starsBefore * 0.6
            : true; // no star data → don't block on it (HFR step is enough)
        if (!starLoss) continue;

        final evidence = [for (var i = k; i < pts.length; i++) pts[i].id];
        return [
          NightFinding(
            id: 'dew_hfr_collapse',
            severity: NightFindingSeverity.critical,
            title: 'Optics likely dewed over',
            explanation:
                'HFR jumped sharply (${before.toStringAsFixed(2)} → '
                '${after.toStringAsFixed(2)} px) and never recovered'
                '${starsBefore != null && starsAfter != null ? ', with star '
                          'count collapsing from ${starsBefore.round()} to '
                          '${starsAfter.round()}' : ''} — the classic signature of '
                'dew or frost on the optics.',
            advice:
                'Fit and power a dew heater on the corrector/objective, and '
                'consider a dew shield. Everything after this point is likely '
                'unusable.',
            evidenceSubIds: evidence,
            metricSeries: hfrs,
          ),
        ];
      }
    }
    return const [];
  }

  /// **Moon-gradient onset.** A rising sky background that tracks the moon
  /// climbing in altitude — sky brightness from moonlight. Needs per-sub
  /// `background` and the mount pointing to compute moon separation/altitude;
  /// since `captured_images` carries no per-sub moon column we compute the moon
  /// altitude from `capturedAt` against an inferred observer site. When the
  /// observer location is unknown we fail-soft to a pure background-vs-time
  /// rise check only if it correlates with the lunar phase being bright.
  ///
  /// In this Dart-core layer we have no site lat/long on the session row, so the
  /// detector reduces to: background rises monotonically through the night while
  /// the moon is illuminated and climbing (computed from the timestamp). It is
  /// deliberately conservative — info severity — because without a site it can't
  /// fully separate moon from light-pollution gradient.
  List<NightFinding> _detectMoonGradientOnset(NightData data) {
    final pts = data.subs
        .where((s) => s.background != null)
        .map((s) => (sub: s, bg: s.background!))
        .toList(growable: false);
    if (pts.length < 8) return const [];

    final times = [
      for (final p in pts) p.sub.capturedAt.millisecondsSinceEpoch.toDouble(),
    ];
    final bgs = [for (final p in pts) p.bg];
    final r = _pearson(times, bgs);
    if (r == null || r < 0.6) return const [];

    final mid = pts.length ~/ 2;
    final early = _median([for (var i = 0; i < mid; i++) bgs[i]]);
    final late = _median([for (var i = mid; i < bgs.length; i++) bgs[i]]);
    if (early == null || late == null || early <= 0) return const [];
    final relRise = (late - early) / early;
    if (relRise < 0.2) return const [];

    // Cross-reference the moon: only call it a moon gradient when the moon is
    // both illuminated and rising across the window. Otherwise it's more likely
    // a target descending into light pollution — still worth noting, lower key.
    final moonStart = _MoonEphemeris.illuminationAndAltitudeTrend(
      pts.first.sub.capturedAt,
      pts.last.sub.capturedAt,
    );
    final moonDriven = moonStart.illumination > 0.4 && moonStart.altitudeRising;

    return [
      NightFinding(
        id: 'moon_gradient',
        severity: moonDriven
            ? NightFindingSeverity.warn
            : NightFindingSeverity.info,
        title: moonDriven
            ? 'Moon washed out the sky as it rose'
            : 'Sky background rose through the night',
        explanation: moonDriven
            ? 'Sky background climbed '
                  '${(relRise * 100).round()}% as the moon '
                  '(${(moonStart.illumination * 100).round()}% lit) rose — '
                  'moonlight gradient reducing contrast on faint signal.'
            : 'Sky background climbed ${(relRise * 100).round()}% through the '
                  'session, eroding contrast (light-pollution gradient or the '
                  'target sinking toward the horizon).',
        advice: moonDriven
            ? 'Schedule this target on darker, moon-free nights, or switch to '
                  'narrowband filters that reject moonlight.'
            : 'Image this target when it is higher / earlier, and apply gradient '
                  'extraction in post.',
        evidenceSubIds: [for (final p in pts) p.sub.id],
        metricSeries: bgs,
      ),
    ];
  }

  /// **Tilt / collimation.** Driven by the session's PSF field tiles +
  /// astrometric residual vectors via [OpticalTrainDiagnosticsService] —
  /// the same engine behind the equipment screen's optical-health card, so
  /// the morning report and the live card can never disagree. Silent when
  /// the science pipeline produced no tiles for the session (the common
  /// case for rigs with the science tier disabled).
  List<NightFinding> _detectTiltCollimation(NightData data) {
    final diag = data.opticalDiagnostics;
    if (diag == null) return const [];

    final findings = <NightFinding>[];
    if (diag.tiltScore >= OpticalHealthScore.tiltWarnThreshold) {
      final critical =
          diag.tiltScore >= OpticalHealthScore.tiltCriticalThreshold;
      findings.add(
        NightFinding(
          id: 'field_tilt',
          severity: critical
              ? NightFindingSeverity.critical
              : NightFindingSeverity.warn,
          title:
              'Field tilt detected '
              '(score ${diag.tiltScore.toStringAsFixed(0)}/100)',
          explanation:
              'Star size (PSF) is systematically uneven across the frame; the '
              'strongest degradation is toward ${diag.dominantTiltDirection}. '
              'This pattern held across the night\'s solved frames, which '
              'points at sensor tilt or a sagging imaging-train connection '
              'rather than seeing.',
          advice:
              'Check the camera/corrector connection for sag and the '
              'sensor tilt adjustment (if your camera has a tilt plate). The '
              'equipment screen\'s optical-health card shows the live '
              'corner-by-corner breakdown.',
        ),
      );
    }
    if (diag.collimationScore >= OpticalHealthScore.collimationWarnThreshold) {
      final critical =
          diag.collimationScore >=
          OpticalHealthScore.collimationCriticalThreshold;
      findings.add(
        NightFinding(
          id: 'collimation_spacing',
          severity: critical
              ? NightFindingSeverity.critical
              : NightFindingSeverity.warn,
          title:
              'Collimation / spacing mismatch '
              '(score ${diag.collimationScore.toStringAsFixed(0)}/100)',
          explanation:
              'Astrometric residuals grow toward the field edges relative to '
              'the centre — the signature of optical misalignment or wrong '
              'corrector/flattener back-spacing, not atmosphere.',
          advice:
              'Verify collimation and the flattener back-focus distance '
              '(55 mm is typical but check your corrector\'s spec).',
        ),
      );
    }
    return findings;
  }

  /// **The frame grader's own verdict.** Every other detector looks for a
  /// *change* across the night — drift, a collapse, an onset — so a night that
  /// is uniformly bad from the first sub to the last trips none of them, and
  /// the score (which only subtracts) lands on a perfect 100 with "A clean
  /// night — no problems detected". A live 4×3 s run does exactly that while
  /// the same app's Workbench badges all four subs POOR (HFR 5.7 against its
  /// 3.5 cull line, quality_score ~35).
  ///
  /// So the night verdict reads the same [FrameQualityAssessmentService] the
  /// Workbench reads. This is a reconciliation, not a second opinion: if the
  /// grader condemns most of the night, the night is not clean, whatever the
  /// trend detectors saw.
  ///
  /// Deliberately conservative — a night is only faulted when at least half its
  /// subs are graded POOR, so one bad frame in a good night stays the frame
  /// list's business.
  List<NightFinding> _detectGraderPoorNight(NightData data) {
    if (data.subs.length < NightAnalysisService.minGradableSubs) {
      return const [];
    }
    const assessor = FrameQualityAssessmentService();
    final frames = [for (final s in data.subs) s.asGradableFrame()];
    final assessments = assessor.assessBatch(frames);
    if (assessments.isEmpty) return const [];

    final poorIds = <int>[
      for (final s in data.subs)
        if (assessments[s.id]?.level == FrameQualityLevel.poor) s.id,
    ];
    final total = data.subs.length;
    final poor = poorIds.length;
    if (poor * 2 < total) return const [];

    final hfrs = [
      for (final s in data.subs)
        if (s.hfr != null && s.hfr! > 0) s.hfr!,
    ];
    final medianHfr = _median(hfrs);
    final hfrClause = medianHfr == null
        ? ''
        : ' Median HFR across the night was '
              '${medianHfr.toStringAsFixed(2)} px.';
    final all = poor == total;

    return [
      NightFinding(
        id: 'frames_graded_poor',
        severity: all
            ? NightFindingSeverity.critical
            : NightFindingSeverity.warn,
        title: all
            ? 'Every sub was graded POOR'
            : '$poor of $total subs were graded POOR',
        explanation:
            'The frame grader — the same one behind the Workbench badges — '
            'rates ${all ? 'all $total' : '$poor of $total'} of this '
            'session\'s subs POOR.$hfrClause No single trend explains it, so '
            'the night was already this way when it started rather than '
            'degrading part-way through.',
        advice: all
            ? 'Treat this night as unusable until you know why: run an '
                  'autofocus and check focus, star shape and tracking before '
                  'the next session. Open Workbench to see each sub\'s reason.'
            : 'Open Workbench to see which subs were faulted and why before '
                  'integrating.',
        evidenceSubIds: poorIds,
      ),
    ];
  }
}
