import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/wire_models.dart';

// The encoded strings below are the bytes released clients, the web
// dashboard and the phone app read. A change to one of them is a protocol
// change, not a refactor.
void main() {
  group('sequence runs', () {
    final run = RemoteSequenceRun(
      id: 4,
      sequenceId: 2,
      sequenceName: 'NGC 891',
      startedAt: DateTime.utc(2026, 11, 8, 1),
      endedAt: DateTime.utc(2026, 11, 8, 5, 30),
      status: 'completed',
      statsJson: '{"frames":30}',
    );

    test('a run row encodes every field, nulls included', () {
      expect(
        jsonEncode(run.toJson()),
        '{"id":4,"sequenceId":2,"sequenceName":"NGC 891",'
        '"startedAt":"2026-11-08T01:00:00.000Z",'
        '"endedAt":"2026-11-08T05:30:00.000Z","status":"completed",'
        '"statsJson":"{\\"frames\\":30}"}',
      );
      final open = RemoteSequenceRun(
        id: 5,
        startedAt: DateTime.utc(2026, 11, 9),
        status: 'running',
      );
      expect(
        jsonEncode(open.toJson()),
        '{"id":5,"sequenceId":null,"sequenceName":null,'
        '"startedAt":"2026-11-09T00:00:00.000Z","endedAt":null,'
        '"status":"running","statsJson":null}',
      );
      expect(RemoteSequenceRun.fromJson(run.toJson()).toJson(), run.toJson());
    });

    test('a page wraps its rows with the matching total', () {
      final page = RemotePage(items: [run], total: 7);
      final json = page.toJson((row) => row.toJson());
      expect(json.keys, ['items', 'total']);
      final read = RemotePage.fromJson(json, RemoteSequenceRun.fromJson);
      expect(read.total, 7);
      expect(read.items.single.toJson(), run.toJson());
      expect(
        () => RemotePage.fromJson({
          'items': [run.toJson(), run.toJson()],
          'total': 1,
        }, RemoteSequenceRun.fromJson),
        throwsFormatException,
      );
    });

    test('the detail names a target only when it has one', () {
      final detail = RemoteSequenceRunDetail(
        id: 4,
        startedAt: DateTime.utc(2026, 11, 8, 1),
        status: 'completed',
        frameCount: 0,
      );
      expect(detail.toJson().containsKey('targetName'), isFalse);
      expect(detail.toJson().keys.last, 'frameCount');
      final named = RemoteSequenceRunDetail(
        id: 4,
        startedAt: DateTime.utc(2026, 11, 8, 1),
        status: 'completed',
        frameCount: 3,
        targetName: 'NGC 891',
      );
      expect(
        RemoteSequenceRunDetail.fromJson(named.toJson()).targetName,
        'NGC 891',
      );
    });

    test('diff context keeps both snapshots, null when absent', () {
      const context = RemoteSequenceRunDiffContext(
        runId: 4,
        sequenceId: null,
        currentSnapshotJson: '{"v":2}',
        previousSnapshotJson: null,
      );
      expect(
        jsonEncode(context.toJson()),
        '{"runId":4,"sequenceId":null,"currentSnapshotJson":"{\\"v\\":2}",'
        '"previousSnapshotJson":null}',
      );
    });
  });

  group('replay', () {
    final at = DateTime.utc(2026, 11, 8, 2, 3, 4, 5);

    test('an event leaves out a missing source and empty fields', () {
      final bare = RemoteReplayEvent(
        timestamp: at,
        timestampMs: at.millisecondsSinceEpoch,
        severity: 'warning',
        message: 'Guide star faint',
      );
      expect(
        jsonEncode(bare.toJson()),
        '{"timestamp":"2026-11-08T02:03:04.005Z","timestampMs":1794103384005,'
        '"severity":"warning","message":"Guide star faint"}',
      );
      final full = RemoteReplayEvent(
        timestamp: at,
        timestampMs: at.millisecondsSinceEpoch,
        severity: 'error',
        source: 'Grader',
        message: 'Frame rejected',
        fields: const {'hfr': 4.5},
      );
      expect(full.toJson().keys, [
        'timestamp',
        'timestampMs',
        'severity',
        'source',
        'message',
        'fields',
      ]);
      expect(RemoteReplayEvent.fromJson(full.toJson()).toJson(), full.toJson());
    });

    test('an events page says why it is partial', () {
      const partial = RemoteReplayEventsPage(
        items: [],
        total: 0,
        isPartial: true,
        partialReason: 'no_buffered_entries',
        source: 'logging_service_ring_buffer',
      );
      expect(
        jsonEncode(partial.toJson()),
        '{"items":[],"total":0,"is_partial":true,'
        '"source":"logging_service_ring_buffer",'
        '"partialReason":"no_buffered_entries"}',
      );
      const complete = RemoteReplayEventsPage(
        items: [],
        total: 0,
        isPartial: false,
        source: 'logging_service_ring_buffer',
      );
      expect(complete.toJson().containsKey('partialReason'), isFalse);
      expect(
        RemoteReplayEventsPage.fromJson(complete.toJson()).isPartial,
        isFalse,
      );
    });

    test('a frame encodes every column in the order clients read', () {
      final frame = RemoteReplayFrame(
        id: 1,
        fileName: 'a.fits',
        filePath: '/f/a.fits',
        capturedAt: at,
        capturedAtMs: at.millisecondsSinceEpoch,
        frameType: 'light',
        exposureDuration: 60,
        binX: 1,
        binY: 1,
        isAccepted: true,
        hfr: 2.5,
      );
      expect(
        jsonEncode(frame.toJson()),
        '{"id":1,"fileName":"a.fits","filePath":"/f/a.fits",'
        '"capturedAt":"2026-11-08T02:03:04.005Z",'
        '"capturedAtMs":1794103384005,"frameType":"light",'
        '"exposureDuration":60.0,"filter":null,"gain":null,"offset":null,'
        '"binX":1,"binY":1,"sensorTemp":null,"hfr":2.5,"starCount":null,'
        '"background":null,"noise":null,"qualityScore":null,'
        '"guidingRmsRa":null,"guidingRmsDec":null,"guidingRmsTotal":null,'
        '"mountRa":null,"mountDec":null,"mountAltitude":null,'
        '"mountAzimuth":null,"focuserPosition":null,"isAccepted":true,'
        '"rejectionReason":null,"sessionId":null,"targetId":null}',
      );
      expect(
        RemoteReplayFrame.fromJson(frame.toJson()).toJson(),
        frame.toJson(),
      );
    });
  });

  group('history', () {
    test('an observation log entry is sent in UTC', () {
      final entry = RemoteNotesJournalEntry(
        id: 1,
        timestamp: DateTime.utc(2026, 5, 1, 22),
        objectName: 'M31',
        ra: 0.7,
        dec: 41.3,
      );
      final json = entry.toJson();
      expect(json['timestamp'], '2026-05-01T22:00:00.000Z');
      expect(json.length, 17);
      expect(RemoteNotesJournalEntry.fromJson(json).toJson(), entry.toJson());
    });

    test('a guide RMS row reads the session id as a number or as text', () {
      final entry = RemoteGuideRmsHistoryEntry(
        id: 1,
        sessionId: 113,
        totalRmsArcsec: 0.62,
        sampleCount: 240,
        recordedAt: DateTime.utc(2026, 11, 8),
      );
      expect(
        jsonEncode(entry.toJson()),
        '{"id":1,"sessionId":113,"mountId":null,"targetId":null,'
        '"totalRmsArcsec":0.62,"sampleCount":240,"exposureSeconds":null,'
        '"recordedAt":"2026-11-08T00:00:00.000Z"}',
      );
      final fromOldHost = entry.toJson()..['sessionId'] = '113';
      expect(RemoteGuideRmsHistoryEntry.fromJson(fromOldHost).sessionId, 113);
    });

    test('a polar alignment row round-trips', () {
      final entry = RemotePolarAlignmentHistoryEntry(
        id: 2,
        startedAt: DateTime.utc(2026, 4, 1, 21),
        completedAt: DateTime.utc(2026, 4, 1, 21, 9),
        autoCompleted: true,
        isNorth: false,
        finalTotalError: 0.22,
        configJson: '{}',
      );
      expect(entry.toJson().keys.first, 'id');
      expect(entry.toJson().keys.last, 'configJson');
      expect(
        RemotePolarAlignmentHistoryEntry.fromJson(entry.toJson()).toJson(),
        entry.toJson(),
      );
    });
  });

  group('calibration', () {
    test('a dark row carries the on-disk check', () {
      final dark = RemoteDarkLibraryEntry(
        id: 1,
        filePath: '/d/dark.fits',
        fileName: 'dark.fits',
        exposureDuration: 300,
        sensorTempC: -10,
        gain: 100,
        offset: 10,
        binX: 1,
        binY: 1,
        frameType: 'dark',
        width: null,
        height: null,
        masterPath: null,
        frameCount: null,
        createdAt: DateTime.utc(2026, 3, 1, 12),
        fileSize: null,
        fileExists: false,
      );
      expect(
        jsonEncode(dark.toJson()),
        '{"id":1,"filePath":"/d/dark.fits","fileName":"dark.fits",'
        '"exposureDuration":300.0,"sensorTempC":-10.0,"gain":100,'
        '"offset":10,"binX":1,"binY":1,"frameType":"dark","width":null,'
        '"height":null,"masterPath":null,"frameCount":null,'
        '"createdAt":"2026-03-01T12:00:00.000Z","fileSize":null,'
        '"fileExists":false}',
      );
    });

    test('a flat recommendation nests what it is based on', () {
      const recommendation = RemoteFlatRecommendation(
        exposureDuration: 1.5,
        basedOnFlatId: 3,
        ageDays: 2,
        confidence: 'high',
      );
      expect(
        jsonEncode(recommendation.toJson()),
        '{"exposureDuration":1.5,'
        '"basedOn":{"flatId":3,"ageDays":2,"confidence":"high"}}',
      );
    });
  });

  group('plugins', () {
    test('a bundled plugin row keeps the archive fields as nulls', () {
      final plugin = RemotePluginManifest(
        id: 'p',
        name: 'Plugin',
        version: '1.0.0',
        author: 'Team',
        description: 'Does a thing',
        enabled: true,
        signed: false,
        signatureValid: false,
        installedAt: DateTime.utc(2026, 11, 8),
        source: 'bundled',
        runtimeLoaded: true,
        canEnable: true,
      );
      expect(
        jsonEncode(plugin.toJson()),
        '{"id":"p","name":"Plugin","version":"1.0.0","author":"Team",'
        '"description":"Does a thing","enabled":true,"signed":false,'
        '"signatureValid":false,"sha256":null,"sizeBytes":null,'
        '"installedAt":"2026-11-08T00:00:00.000Z","installedFilename":null,'
        '"loadError":null,"source":"bundled","runtimeLoaded":true,'
        '"canEnable":true}',
      );
      expect(
        RemotePluginManifest.fromJson(plugin.toJson()).toJson(),
        plugin.toJson(),
      );
    });
  });

  group('host files', () {
    test('a root listing has no current or parent folder', () {
      const listing = RemoteDirectoryListing(
        currentPath: null,
        parentPath: null,
        directories: [RemoteDirectoryEntry(name: 'Data', path: '/data')],
      );
      expect(
        jsonEncode(listing.toJson()),
        '{"currentPath":null,"parentPath":null,'
        '"directories":[{"name":"Data","path":"/data"}]}',
      );
    });

    test('a log file row sends its time in UTC', () {
      final file = RemoteLogFileInfo(
        name: 'skotiq.log.2026-11-08',
        sizeBytes: 1234,
        modifiedAt: DateTime.utc(2026, 11, 8, 19),
        isCurrent: false,
      );
      expect(
        jsonEncode(file.toJson()),
        '{"name":"skotiq.log.2026-11-08","sizeBytes":1234,'
        '"modifiedAt":"2026-11-08T19:00:00.000Z","isCurrent":false}',
      );
    });
  });
}
