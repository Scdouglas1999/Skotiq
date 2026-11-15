// An event this build cannot read is dropped from the typed stream, and said
// once per kind in the log rather than not at all.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart' show typedEventFromWire;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
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
}
