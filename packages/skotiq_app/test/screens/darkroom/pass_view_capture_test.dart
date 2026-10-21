// Renders the two Darkroom pass-view directions from a real pass, at three
// moments, at the full window and at the side panel's width.
//
// The pass comes from a capture of the production integration over a real
// night (the `passviz` harness in the bridge crate, then the fixture script
// beside it), so every number, thumbnail and image is what the pipeline
// produced. Opt-in: set PASSVIZ_FIXTURE to the fixture directory and
// PASSVIZ_SHOTS to where the PNGs go.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/pass_view/pass_view_directions.dart';
import 'package:skotiq_app/screens/darkroom/pass_view/pass_view_model.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../golden/surface_golden_harness.dart';

Duration _ms(num v) => Duration(milliseconds: v.round());

Future<ui.Image?> _decode(String path) async {
  final file = File(path);
  if (!file.existsSync()) return null;
  final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
  return (await codec.getNextFrame()).image;
}

/// The lane's stages from its progress events, offset by [base].
///
/// Each event says a phase is at a sub: `calibrating` after a sub loaded,
/// `registering` and `normalizing` before a sub starts, so a sub of those two
/// finishes at the next event.
List<PassSpan> _spans(List<Map<String, dynamic>> events, Duration base) {
  final t0 = events.first['t'] as int;
  Duration at(Map<String, dynamic> e) => base + _ms((e['t'] as int) - t0);
  List<Map<String, dynamic>> phase(String p) =>
      events.where((e) => e['phase'] == p).toList();

  final cal = phase('calibrating');
  final reg = phase('registering');
  final weigh = phase('weighting');
  final norm = phase('normalizing');
  final integ = phase('integrating');
  final write = phase('writing');
  final preview = phase('preview');

  List<Duration> startsToEnds(List<Map<String, dynamic>> ev, Duration end) {
    final starts =
        ev.where((e) => (e['done'] as int? ?? 0) > 0).map(at).toList();
    return <Duration>[for (var i = 1; i < starts.length; i++) starts[i], end];
  }

  final calEnd = at(cal.last);
  final regEnd = at(weigh.first);
  final normEnd = at(integ.first);
  final intEnd = at(integ.last);
  final done = at(preview.last);
  return <PassSpan>[
    PassSpan(
      stage: PassStage.calibrate,
      start: at(cal.first),
      end: calEnd,
      ticks: <Duration>[
        for (final e in cal)
          if ((e['done'] as int? ?? 0) > 0) at(e),
      ],
    ),
    PassSpan(
      stage: PassStage.register,
      start: calEnd,
      end: regEnd,
      ticks: startsToEnds(reg, regEnd),
    ),
    PassSpan(
      stage: PassStage.normalize,
      start: regEnd,
      end: normEnd,
      ticks: startsToEnds(norm, normEnd),
    ),
    PassSpan(stage: PassStage.integrate, start: normEnd, end: intEnd),
    PassSpan(stage: PassStage.write, start: at(write.first), end: done),
  ];
}

Future<PassTimeline> _load(String dir) async {
  final doc = jsonDecode(File('$dir/pass.json').readAsStringSync())
      as Map<String, dynamic>;
  final lanes = <PassLane>[];
  var base = Duration.zero;
  for (final raw in (doc['filters'] as List).cast<Map<String, dynamic>>()) {
    final filter = raw['filter'] as String;
    final events = (raw['events'] as List).cast<Map<String, dynamic>>();
    final frames = <PassFrame>[];
    final records = (raw['frames'] as List).cast<Map<String, dynamic>>();
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      final t = (r['transform'] as List?)?.cast<num>();
      final identity =
          t != null && t[2] == 0 && t[5] == 0 && t[0] == 1 && t[1] == 0;
      frames.add(PassFrame(
        filter: filter,
        index: i + 1,
        name: r['name'] as String,
        capturedAt: DateTime.tryParse('${r['dateObs']}Z')?.toLocal(),
        stars: (r['starCount'] as num?)?.toInt(),
        fwhm: (r['fwhm'] as num?)?.toDouble(),
        eccentricity: (r['eccentricity'] as num?)?.toDouble(),
        background: (r['background'] as num?)?.toDouble(),
        noise: (r['noise'] as num?)?.toDouble(),
        snr: (r['snr'] as num?)?.toDouble(),
        weight: (r['weight'] as num?)?.toDouble(),
        rmsPx: (r['rmsResidualPx'] as num?)?.toDouble(),
        dx: t?[2].toDouble(),
        dy: t?[5].toDouble(),
        rotationDeg: t == null
            ? null
            : math.atan2(t[3].toDouble(), t[0].toDouble()) * 180 / math.pi,
        accepted: r['accepted'] as bool,
        reason: (r['reason'] as String?)?.replaceFirst(
            RegExp(r'^registration failed: .*only 0 correspondences.*$'),
            'no stars matched the reference'),
        isReference: identity,
        thumbnail: await _decode('$dir/${r['thumb']}'),
      ));
    }
    final spans = _spans(events, base);
    lanes.add(PassLane(
      filter: filter,
      frames: frames,
      spans: spans,
      exposureSec: (records.first['exposureSec'] as num?)?.toDouble() ?? 0,
      masterNoise: (raw['masterNoise'] as num?)?.toDouble(),
      framesIntegrated: raw['framesIntegrated'] as int?,
      framesRejected: raw['framesRejected'] as int?,
      masterPreview: await _decode('$dir/preview_$filter.png'),
      rejectionMap: await _decode('$dir/rejmap_$filter.png'),
      referencePreview: await _decode('$dir/reference_$filter.png'),
    ));
    base = spans.last.end!;
  }

  final depths = <PassDepth>[];
  for (final d in (doc['depths'] as List).cast<Map<String, dynamic>>()) {
    depths.add(PassDepth(
      depth: d['depth'] as int,
      noise: (d['noise'] as num).toDouble(),
      image: await _decode('$dir/preview_${d['tag']}.png'),
    ));
  }
  final lead = doc['filters'][0] as Map<String, dynamic>;
  depths.add(PassDepth(
    depth: lead['framesIntegrated'] as int,
    noise: (lead['masterNoise'] as num).toDouble(),
    image: lanes.first.masterPreview,
  ));

  final fits = <PassChannelFit>[];
  var alignMs = 0;
  for (final a in (doc['alignment'] as List).cast<Map<String, dynamic>>()) {
    if (a['transform'] == null) {
      final error = '${a['error']}';
      final m = RegExp(r'only (\d+) correspondences').firstMatch(error);
      fits.add(PassChannelFit.failed(
        a['filter'] as String,
        m == null ? error : '${m.group(1)} stars matched',
      ));
      continue;
    }
    final t = (a['transform'] as List).cast<num>();
    alignMs += a['ms'] as int;
    fits.add(PassChannelFit(
      filter: a['filter'] as String,
      dx: t[2].toDouble(),
      dy: t[5].toDouble(),
      rotationDeg: math.atan2(t[3].toDouble(), t[0].toDouble()) * 180 / math.pi,
      scale: math.sqrt(t[0] * t[0] + t[3] * t[3]),
      matched: a['matched'] as int,
      inliers: a['inliers'] as int,
      rmsPx: (a['rmsPx'] as num).toDouble(),
    ));
  }
  final alignStart = base;
  final alignEnd = alignStart + _ms(alignMs);
  // The combine has no timing of its own yet; the drafts are timed from the
  // last real dawn pass (four drafts in 37.5 s).
  const far = Duration(hours: 9);
  return PassTimeline(
    target: 'NGC 891',
    lanes: lanes,
    depths: depths,
    channelFits: fits,
    colorImage: await _decode('$dir/color.png'),
    colorCaption: 'Color preview from the four masters (prototype composite)',
    calibrationNote: 'cosmetic correction only, no dark, flat or bias matched',
    colorSpans: <PassSpan>[
      PassSpan(
        stage: PassStage.align,
        start: alignStart,
        end: alignEnd,
        ticks: <Duration>[
          for (var i = 1; i <= fits.length; i++)
            alignStart + _ms(alignMs * i / fits.length),
        ],
      ),
      PassSpan(stage: PassStage.combine, start: alignEnd, end: null),
      PassSpan(
        stage: PassStage.draft,
        start: far,
        end: far + const Duration(milliseconds: 37551),
        estimated: true,
      ),
    ],
  );
}

void main() {
  final fixture = Platform.environment['PASSVIZ_FIXTURE'];
  final shots = Platform.environment['PASSVIZ_SHOTS'];
  final skip = fixture == null || shots == null
      ? 'set PASSVIZ_FIXTURE and PASSVIZ_SHOTS to render the pass view'
      : null;

  setUpAll(SurfaceGoldenHarness.ensureCaptureFonts);

  Future<void> capture(
    WidgetTester tester, {
    required PassSnapshot snapshot,
    required PassViewDirection direction,
    required bool panel,
    required String name,
  }) async {
    final size = panel ? const Size(360, 1480) : const Size(1536, 864);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: SkotiqTheme.dark,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: SkotiqColors.dark.background,
        body: RepaintBoundary(
          key: key,
          child: SizedBox.fromSize(
            size: size,
            child: PassView(
                snapshot: snapshot, direction: direction, panel: panel),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull, reason: name);
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(shots!).createSync(recursive: true);
      File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('pass view directions at three moments', (tester) async {
    final timeline = (await tester.runAsync(() => _load(fixture!)))!;
    final lead = timeline.lanes.first;
    final reg = lead.span(PassStage.register);
    final norm = lead.span(PassStage.normalize);
    final align = timeline.colorSpans.first;
    final moments = <String, Duration>{
      // Registering the sixth luminance sub, five measured.
      'early': reg.ticks[4] + const Duration(milliseconds: 400),
      // Eight luminance subs in the running mean.
      'mid': norm.ticks[7] + const Duration(milliseconds: 500),
      // Channels aligned, color combining.
      'late': align.end! + const Duration(seconds: 2),
    };
    for (final MapEntry(key: moment, value: t) in moments.entries) {
      final snapshot = timeline.at(t);
      for (final direction in PassViewDirection.values) {
        for (final panel in <bool>[false, true]) {
          await capture(
            tester,
            snapshot: snapshot,
            direction: direction,
            panel: panel,
            name:
                '${direction.name}-$moment-${panel ? 'panel-360x1480' : 'desktop-1536x864'}',
          );
        }
      }
    }
  }, skip: skip != null);
}
