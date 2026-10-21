import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A log builder on a clock that starts at t0 and is advanced in seconds.
class _Log {
  _Log(this.runId);
  final String runId;
  static const t0 = 1800000000000;
  final List<PassLogEntry> entries = <PassLogEntry>[];

  void at(num seconds, String kind, [Map<String, dynamic> detail = const {}]) {
    entries.add(
      PassLogEntry(
        t: t0 + (seconds * 1000).round(),
        kind: kind,
        detail: detail,
      ),
    );
  }

  PassLog get log => PassLog(runId: runId, entries: List.of(entries));
}

Duration _s(num v) => Duration(milliseconds: (v * 1000).round());

/// Two lanes of four subs. Lane L: calibrate 0..4, reference 4..6, register
/// subs at 7, 8, 9, 10 (sub 4 rejected), weights at 10, normalize 11, 12, 13,
/// integrate 13..15, written 16, solve and save 16..18.
_Log _twoLanes() {
  final b = _Log('run-1')
    ..at(0, PassKinds.passPlanned, {
      'target': 'NGC 891',
      'sessionId': 71,
      'lanes': [
        {'lane': 'L', 'subs': 4, 'exposure': 90},
        {'lane': 'R', 'subs': 4, 'exposure': 120},
      ],
      'finishing': true,
      'drafts': 2,
    })
    ..at(0, PassKinds.runStarted, {
      'lane': 'L',
      'subs': 4,
      'names': ['a', 'b', 'c', 'd'],
      'exposures': [90, 90, 90, 90],
      'calibration': {
        'dark': false,
        'flat': false,
        'bias': false,
        'cosmetic': true,
      },
    });
  for (var i = 1; i <= 4; i++) {
    b.at(i, PassKinds.calibrated, {
      'index': i,
      'dateObs': '2026-10-21T02:5$i:00',
    });
  }
  b
    ..at(4, PassKinds.referenceChoosing)
    ..at(6, PassKinds.referenceChosen, {
      'index': 2,
      'path': '/p/L_reference.png',
    });
  for (var i = 1; i <= 4; i++) {
    final rejected = i == 4;
    b.at(6 + i, PassKinds.registered, {
      'index': i,
      'reference': i == 2,
      'accepted': !rejected,
      'reason': rejected
          ? 'registration failed: could not establish a consistent geometry: '
                'only 0 correspondences/inliers, need >= 6'
          : null,
      'stars': rejected ? null : 1000 + i,
      'fwhm': rejected ? null : 2.4 + i / 10,
      'rmsPx': rejected ? null : (i == 2 ? 0.0 : 0.5),
      'transform': rejected
          ? null
          : [1, 0, i == 2 ? 0 : 3.0, 0, 1, i == 2 ? 0 : 4.0, 0, 0, 1],
    });
  }
  b.at(10, PassKinds.weighted, {
    'weights': [
      {'index': 1, 'weight': 0.9},
      {'index': 2, 'weight': 1.0},
      {'index': 3, 'weight': 0.8},
    ],
  });
  for (var i = 1; i <= 3; i++) {
    b
      ..at(10 + i, PassKinds.normalized, {'index': i})
      ..at(10 + i, PassKinds.runningPreview, {
        'subs': i,
        'noise': 100 / i,
        'path': i == 2 ? null : '/p/L_running_$i.png',
      });
  }
  b
    ..at(13, PassKinds.integrating, {'subs': 3})
    ..at(15, PassKinds.integrated, {'frames': 3, 'noise': 40.0})
    ..at(16, PassKinds.written, {'previewPath': '/p/L_master.png'})
    ..at(16, PassKinds.runEnded, {'lane': 'L', 'ok': true})
    ..at(16, PassKinds.laneFinishing, {'lane': 'L'})
    ..at(18, PassKinds.laneFinished, {'lane': 'L', 'ok': true})
    ..at(18, PassKinds.runStarted, {
      'lane': 'R',
      'subs': 4,
      'names': ['e', 'f', 'g', 'h'],
      'exposures': [120, 120, 120, 120],
    })
    ..at(19, PassKinds.calibrated, {'index': 1});
  return b;
}

void main() {
  group('PassTimeline.fromLog', () {
    test('folds the reports into lanes with every sub', () {
      final tl = PassTimeline.fromLog(_twoLanes().log);
      expect(tl.target, 'NGC 891');
      expect(tl.sessionId, 71);
      expect(tl.lanes.map((l) => l.lane), ['L', 'R']);
      final l = tl.lanes.first;
      expect(l.frames, hasLength(4));
      expect(l.frames[1].isReference, isTrue);
      expect(l.frames[3].accepted, isFalse);
      expect(l.frames[0].dx, 3.0);
      expect(l.frames[0].weight, 0.9);
      expect(l.calibrationNote, contains('cosmetic correction only'));
      expect(l.span(PassStage.normalize).total, 3);
      expect(l.span(PassStage.finish).end, _s(18));
    });

    test('a moment shows only what had been measured by then', () {
      final tl = PassTimeline.fromLog(_twoLanes().log);
      final l = tl.lanes.first;
      final s = tl.at(_s(8.5));
      expect(s.measured(l, l.frames[0]), isTrue);
      expect(s.measured(l, l.frames[1]), isTrue);
      expect(s.measured(l, l.frames[2]), isFalse);
      expect(s.weighed(l), isFalse);
      expect(s.activeSpan!.$2.stage, PassStage.register);
      expect(s.focusLane, l);
    });

    test('the image follows the pass: reference, running mean, master', () {
      final tl = PassTimeline.fromLog(_twoLanes().log);
      expect(tl.at(_s(5)).image.$1, isNull);
      expect(tl.at(_s(7)).image.$1, '/p/L_reference.png');
      // At two subs no PNG was written; the newest one that was is shown.
      expect(tl.at(_s(12.5)).image.$1, '/p/L_running_1.png');
      expect(tl.at(_s(13.5)).image.$1, '/p/L_running_3.png');
      expect(tl.at(_s(17)).image.$1, '/p/L_master.png');
    });

    test('picking the reference is its own stage, not the first sub', () {
      final tl = PassTimeline.fromLog(_twoLanes().log);
      expect(tl.at(_s(5)).activeSpan!.$2.stage, PassStage.reference);
      final l = tl.lanes.first;
      expect(l.span(PassStage.reference).end, _s(6));
      expect(l.span(PassStage.register).start, _s(6));
    });

    test(
      'a lane with nothing stacked shows the master an earlier lane wrote',
      () {
        final s = PassTimeline.fromLog(_twoLanes().log).at(_s(19.5));
        expect(s.focusLane!.lane, 'R');
        expect(s.image.$1, '/p/L_master.png');
        expect(s.image.$2, contains('until R'));
      },
    );

    test('a later lane is timed from the first lane\'s measured rates', () {
      final tl = PassTimeline.fromLog(_twoLanes().log);
      final s = tl.at(_s(19.5));
      final reg = s.schedule.firstWhere(
        (x) => x.lane == 'R' && x.stage == PassStage.register,
      );
      // L registered 4 subs in 4 s (6..10, after its reference was picked),
      // so R's 4 subs take 4 s too.
      expect(reg.end! - reg.start, _s(4));
      expect(reg.estimated, isFalse);
    });

    test('the drafts have no timing yet, so remaining is a lower bound', () {
      final s = PassTimeline.fromLog(_twoLanes().log).at(_s(19.5));
      final (_, complete) = s.remaining;
      expect(complete, isFalse);
      final drafts = s.schedule.firstWhere((x) => x.stage == PassStage.draft);
      expect(drafts.end, isNull);
      expect(drafts.drawnEnd > drafts.start, isTrue);
    });

    test(
      'a stored rate from an earlier pass times a stage, marked as such',
      () {
        final s = PassTimeline.fromLog(
          _twoLanes().log,
          history: const {'draft': 10.0},
        ).at(_s(19.5));
        final drafts = s.schedule.firstWhere((x) => x.stage == PassStage.draft);
        expect(drafts.end! - drafts.start, _s(20));
        expect(drafts.estimated, isTrue);
        expect(s.remaining.$2, isTrue);
      },
    );

    test('a finished record marks what never ran, and rates its stages', () {
      final b = _twoLanes()
        ..at(21, PassKinds.runEnded, {
          'lane': 'R',
          'ok': false,
          'error': 'cancelled during registering',
        })
        ..at(21, PassKinds.passEnded, {'ok': false, 'error': 'stopped'});
      final tl = PassTimeline.fromLog(b.log);
      final s = tl.snapshot(now: DateTime.now());
      expect(s.ended, isTrue);
      expect(s.elapsed, _s(21));
      expect(tl.lanes[1].failure, contains('cancelled'));
      expect(
        s.schedule.firstWhere((x) => x.stage == PassStage.draft).state,
        PassStepState.notRun,
      );
      final rates = tl.stageRates();
      expect(rates['register'], closeTo(4 / 4, 1e-9));
      expect(rates['reference'], closeTo(2 / 4, 1e-9));
      expect(rates.containsKey('draft'), isFalse);
    });

    test('channel fits and the drafts stage report through the same log', () {
      final b = _twoLanes()
        ..at(30, PassKinds.channelAligned, {
          'filter': 'R',
          'error':
              'could not establish a consistent geometry: only 0 '
              'correspondences/inliers, need >= 6',
          'ms': 200,
        })
        ..at(31, PassKinds.stage, {
          'stage': 'draft',
          'state': 'started',
          'total': 2,
        })
        ..at(35, PassKinds.stage, {'stage': 'draft', 'state': 'step'})
        ..at(36, PassKinds.combineDone, {'previewPath': '/p/color.png'});
      final tl = PassTimeline.fromLog(b.log);
      expect(tl.channelFits.single.failure, contains('0 correspondences'));
      final s = tl.at(_s(35.5));
      final drafts = s.schedule.firstWhere((x) => x.stage == PassStage.draft);
      expect(drafts.state, PassStepState.running);
      expect(drafts.done, 1);
      expect(tl.at(_s(37)).image.$1, '/p/color.png');
    });
  });

  test('passReadableReason states a failed match plainly', () {
    expect(
      passReadableReason(
        'registration failed: could not establish a '
        'consistent geometry: only 0 correspondences/inliers, need >= 6',
      ),
      'no stars matched the reference (0 matched, 6 needed)',
    );
    expect(
      passReadableReason('weight below the cull floor'),
      'weight below the cull floor',
    );
  });

  test('PassLog round-trips through JSON', () {
    final log = _twoLanes().log;
    final back = PassLog.fromJson(log.toJson())!;
    expect(back.runId, log.runId);
    expect(back.entries, hasLength(log.entries.length));
    expect(back.target, 'NGC 891');
  });
}
