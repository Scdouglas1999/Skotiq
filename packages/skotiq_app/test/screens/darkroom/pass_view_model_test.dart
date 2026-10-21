import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/pass_view/pass_view_model.dart';

Duration _s(num v) => Duration(milliseconds: (v * 1000).round());

PassLane _lane(String filter, Duration base, {int subs = 4}) {
  List<Duration> ticks(num start, num per) =>
      <Duration>[for (var i = 1; i <= subs; i++) base + _s(start + per * i)];
  return PassLane(
    filter: filter,
    exposureSec: 90,
    frames: <PassFrame>[
      for (var i = 1; i <= subs; i++)
        PassFrame(filter: filter, index: i, name: '$i'),
    ],
    spans: <PassSpan>[
      PassSpan(
          stage: PassStage.calibrate,
          start: base,
          end: base + _s(4),
          ticks: ticks(0, 1)),
      PassSpan(
          stage: PassStage.register,
          start: base + _s(4),
          end: base + _s(12),
          ticks: ticks(4, 2)),
      PassSpan(
          stage: PassStage.normalize,
          start: base + _s(12),
          end: base + _s(24),
          ticks: ticks(12, 3)),
      PassSpan(
          stage: PassStage.integrate, start: base + _s(24), end: base + _s(28)),
      PassSpan(
          stage: PassStage.write, start: base + _s(28), end: base + _s(29)),
    ],
  );
}

void main() {
  final l = _lane('L', Duration.zero);
  final r = _lane('R', _s(29));
  PassTimeline timeline({Duration? combineEnd}) => PassTimeline(
        target: 'T',
        lanes: <PassLane>[l, r],
        depths: const <PassDepth>[],
        channelFits: const <PassChannelFit>[],
        colorSpans: <PassSpan>[
          PassSpan(
            stage: PassStage.combine,
            start: _s(58),
            end: combineEnd,
          ),
        ],
      );

  test('a sub is measured only once its registration finished', () {
    final s = timeline(combineEnd: _s(60)).at(_s(8.5));
    expect(s.measured(l, l.frames[0]), isTrue);
    expect(s.measured(l, l.frames[1]), isTrue);
    expect(s.measured(l, l.frames[2]), isFalse);
    expect(s.weighed(l), isFalse);
  });

  test('the rest of a running stage is timed from its own seconds per sub', () {
    final s = timeline(combineEnd: _s(60)).at(_s(8.5));
    final reg = s.schedule
        .firstWhere((x) => x.filter == 'L' && x.stage == PassStage.register);
    // Two subs in 4 s: four subs end at 4 + 8 s.
    expect(reg.end, _s(12));
    expect(reg.estimated, isFalse);
    expect(reg.done, 2);
  });

  test('a later lane takes the first lane\'s measured lengths', () {
    final s = timeline(combineEnd: _s(60)).at(_s(30));
    final reg = s.schedule
        .firstWhere((x) => x.filter == 'R' && x.stage == PassStage.register);
    expect(reg.end! - reg.start, _s(8));
    expect(reg.estimated, isFalse);
  });

  test('a stage nothing can time leaves the remaining time a lower bound', () {
    final open = timeline().at(_s(58.5));
    final (_, complete) = open.remaining;
    expect(complete, isFalse);
    final combine = open.schedule.last;
    expect(combine.end, isNull);
    expect(combine.drawnEnd > combine.start, isTrue);

    final timed = timeline(combineEnd: _s(60)).at(_s(58.5));
    final (left, done) = timed.remaining;
    expect(done, isTrue);
    expect(left, _s(1.5));
  });
}
