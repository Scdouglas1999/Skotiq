// An event this build cannot read is dropped from the typed stream, and said
// once per kind in the log rather than not at all.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart' show typedEventFromWire;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/utils.dart';

void main() {
  late Directory dataRoot;
  late LoggingService service;
  final lines = <LogEntry>[];

  setUp(() async {
    dataRoot = Directory.systemTemp.createTempSync('sk-undecodable');
    service = LoggingService(
      applicationSupportDirectoryProvider: () async => dataRoot,
      environment: {skotiqDataDirEnv: dataRoot.path},
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    await service.initialize();
    Log.attach(service);
    lines.clear();
    service.logEntryStream.listen(lines.add);
  });

  tearDown(() async {
    Log.detach(service);
    await service.dispose();
    dataRoot.deleteSync(recursive: true);
  });

  SkotiqEvent progressWithoutItsCount() => SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: EventSeverity.info,
    category: EventCategory.sequencer,
    eventType: 'Progress',
    // `current` is required.
    data: const {'total': 10},
  );

  test('a known event with a field missing is logged once per kind', () async {
    expect(typedEventFromWire(progressWithoutItsCount()), isNull);
    expect(typedEventFromWire(progressWithoutItsCount()), isNull);
    await Future<void>.delayed(Duration.zero);

    final reported = lines
        .where((e) => e.source == 'BridgeEventCodec')
        .map((e) => e.message)
        .toList();
    expect(reported, hasLength(1));
    expect(reported.single, contains('sequencer/Progress'));
  });

  // The rig on 2026-11-15 at 21:52: every host start logged "Dropped a
  // system/HostRuntimeState event this build cannot read" and the same for
  // HostStateChanged. Those are the host's sync envelopes, which only travel
  // on the wire and have no typed form.
  test('a host sync envelope has no typed form and is not reported', () async {
    for (final type in ['HostRuntimeState', 'HostStateChanged']) {
      final envelope = SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.system,
        eventType: type,
        data: const {'channel': 'plateSolve', 'revision': 1},
      );
      expect(typedEventFromWire(envelope), isNull);
    }
    await Future<void>.delayed(Duration.zero);

    expect(lines.where((e) => e.source == 'BridgeEventCodec'), isEmpty);
  });

  // A linked run on 2026-11-22: host and client each logged
  // "Dropped a system/settings.changed event this build cannot read" after a
  // settings save and the same for sequencer/SequenceUpdated after a sequence
  // save. The host's Dart code makes both; their readers take the wire event.
  test('an event the host makes in Dart has no typed form and is not '
      'reported', () async {
    for (final (category, type) in [
      (EventCategory.system, settingsChangedEventType),
      (EventCategory.sequencer, sequenceUpdatedEventType),
    ]) {
      final event = SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: category,
        eventType: type,
        data: const {'key': 'theme', 'value': 'dark'},
      );
      expect(typedEventFromWire(event), isNull);
    }
    await Future<void>.delayed(Duration.zero);

    expect(lines.where((e) => e.source == 'BridgeEventCodec'), isEmpty);
  });
}
