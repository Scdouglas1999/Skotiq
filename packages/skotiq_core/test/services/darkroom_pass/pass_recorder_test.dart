import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';

SkotiqEvent _telemetry(
  String runId,
  String kind,
  int t, [
  Map<String, dynamic>? detail,
]) => SkotiqEvent(
  timestamp: t,
  severity: EventSeverity.info,
  category: EventCategory.imaging,
  eventType: 'IntegrationTelemetry',
  data: <String, dynamic>{
    'run_id': runId,
    'kind': kind,
    'detail': detail ?? <String, dynamic>{},
  },
);

void main() {
  late Directory base;
  late StreamController<SkotiqEvent> events;
  late DarkroomPassRecorder recorder;
  var now = DateTime.fromMillisecondsSinceEpoch(1800000000000);

  setUp(() async {
    base = await Directory.systemTemp.createTemp('pass_recorder_test');
    events = StreamController<SkotiqEvent>.broadcast();
    recorder = DarkroomPassRecorder(
      events: events.stream,
      baseDirectory: () async => base.path,
      clock: () => now,
      saveDelay: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    await recorder.dispose();
    await events.close();
    await base.delete(recursive: true);
  });

  test('native reports and Dart reports land in one log per run', () async {
    recorder.report('run-1', PassKinds.passPlanned, {
      'sessionId': 7,
      'target': 'M31',
    });
    events.add(
      _telemetry(
        'run-1',
        PassKinds.runStarted,
        now.millisecondsSinceEpoch + 5,
        {'lane': 'L'},
      ),
    );
    events.add(
      _telemetry('other', PassKinds.runStarted, now.millisecondsSinceEpoch + 6),
    );
    await Future<void>.delayed(Duration.zero);

    final log = recorder.live('run-1')!;
    expect(log.entries.map((e) => e.kind), [
      PassKinds.passPlanned,
      PassKinds.runStarted,
    ]);
    expect(recorder.runningForSession(7), 'run-1');
    expect(recorder.running, containsAll(<String>['run-1', 'other']));
  });

  test('reports for a session join its running pass, or start one', () async {
    recorder.report('run-1', PassKinds.passPlanned, {'sessionId': 7});
    recorder.reportForSession(7, PassKinds.stage, {
      'stage': 'draft',
      'state': 'started',
    });
    expect(recorder.live('run-1')!.entries, hasLength(2));

    recorder.report('run-1', PassKinds.passEnded, {'ok': true});
    expect(recorder.runningForSession(7), isNull);
    recorder.reportForSession(7, PassKinds.stage, {
      'stage': 'draft',
      'state': 'started',
    });
    final fresh = recorder.runningForSession(7)!;
    expect(fresh, isNot('run-1'));
    expect(recorder.live(fresh)!.plan!['sessionId'], 7);
  });

  test('an ended pass is saved, listed and its stage rates kept', () async {
    recorder.report('run/1', PassKinds.passPlanned, {
      'sessionId': 3,
      'target': 'NGC 891',
    });
    now = now.add(const Duration(seconds: 1));
    recorder.report('run/1', PassKinds.runStarted, {
      'lane': 'L',
      'subs': 2,
      'names': ['a', 'b'],
    });
    now = now.add(const Duration(seconds: 2));
    recorder.report('run/1', PassKinds.calibrated, {'index': 1});
    recorder.report('run/1', PassKinds.calibrated, {'index': 2});
    recorder.report('run/1', PassKinds.referenceChoosing);
    now = now.add(const Duration(seconds: 1));
    recorder.report('run/1', PassKinds.passEnded, {'ok': true});
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final file = File(p.join(base.path, 'passes', 'run_1.json'));
    expect(file.existsSync(), isTrue);
    final saved = PassLog.fromJson(jsonDecode(file.readAsStringSync()))!;
    expect(saved.runId, 'run/1');
    expect(saved.ended, isTrue);

    final rates = await recorder.storedRates();
    expect(rates['calibrate'], closeTo(1.0, 1e-9));

    final records = await recorder.records();
    expect(records.single.target, 'NGC 891');
    expect(records.single.ended, isTrue);

    final loaded = await DarkroomPassRecorder(
      events: const Stream<SkotiqEvent>.empty(),
      baseDirectory: () async => base.path,
    ).load('run/1');
    expect(loaded!.entries, hasLength(saved.entries.length));
  });

  test('preview directories are per run, under the passes folder', () async {
    final dir = await recorder.previewDir('post-session-71');
    expect(dir, p.join(base.path, 'passes', 'post-session-71'));
    expect(Directory(dir!).existsSync(), isTrue);
  });
}
