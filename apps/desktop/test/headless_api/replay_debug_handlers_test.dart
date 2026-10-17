import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/replay_debug_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockSequencerBackend extends Mock implements SequencerBackend {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReplayDebugHandlers', () {
    late SkotiqDatabase database;
    late _MockSequencerBackend backend;
    late ProviderContainer container;
    late ReplayDebugHandlers handlers;

    setUp(() async {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      backend = _MockSequencerBackend();
      when(
        () => backend.sequencerSetDecisionLoggingEnabled(any()),
      ).thenAnswer((_) async {});
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          sequencerBackendProvider.overrideWithValue(backend),
        ],
      );
      handlers = ReplayDebugHandlers(container);
      await container
          .read(replayDebugServiceProvider)
          .persist(
            ReplayDecision(
              id: null,
              sequenceRunId: 42,
              timestamp: DateTime.utc(2026, 7, 14),
              category: DecisionCategory.schedulerPick,
              summary: 'Selected M42 after altitude scoring',
              details: const {'score': 0.91},
            ),
          );
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    Request get(String path) =>
        Request('GET', Uri.parse('http://localhost$path'));

    Request post(String path, [Map<String, Object?> body = const {}]) =>
        Request(
          'POST',
          Uri.parse('http://localhost$path'),
          body: jsonEncode(body),
        );

    test('lists and counts the host decision log', () async {
      final list = await handlers.handleListDecisions(
        get('/api/sequencer/replay-debug/decisions?runId=42'),
      );
      final listBody = jsonDecode(await list.readAsString()) as Map;
      expect(list.statusCode, HttpStatus.ok);
      expect(listBody['total'], 1);
      final row = (listBody['items'] as List).single as Map;
      expect(row['sequence_run_id'], 42);
      expect(row['summary'], contains('M42'));

      final count = await handlers.handleCountDecisions(
        get('/api/sequencer/replay-debug/decisions/count?runId=42'),
      );
      expect((jsonDecode(await count.readAsString()) as Map)['count'], 1);

      // No runId: every row on the host. This is what the "Clear all replay
      // history" confirmation asks for so it can state how much it is about to
      // delete instead of asking for consent to an unknown quantity.
      final total = await handlers.handleCountDecisions(
        get('/api/sequencer/replay-debug/decisions/count'),
      );
      expect((jsonDecode(await total.readAsString()) as Map)['count'], 1);
    });

    test('rejects invalid run ids before reading the database', () async {
      final response = await translateHandlerErrors(
        handlers.handleListDecisions(
          get('/api/sequencer/replay-debug/decisions?runId=0'),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
    });

    test(
      'settings are strict and enabled updates persist plus seed runtime',
      () async {
        final settings = await handlers.handleGetSettings(
          get('/api/sequencer/replay-debug/settings'),
        );
        final settingsBody = jsonDecode(await settings.readAsString()) as Map;
        expect(settingsBody['enabled'], isTrue);
        expect(settingsBody['retentionDays'], 90);

        final updated = await handlers.handleSetEnabled(
          post('/api/sequencer/replay-debug/settings/enabled', {
            'enabled': false,
          }),
        );
        final updatedBody = jsonDecode(await updated.readAsString()) as Map;
        expect(updatedBody['status'], 'ok');
        expect(updatedBody['enabled'], isFalse);
        expect(
          await database.settingsDao.getSetting(replayDebugEnabledKey),
          'false',
        );
        verify(
          () => backend.sequencerSetDecisionLoggingEnabled(false),
        ).called(1);

        await database.settingsDao.setSetting(replayDebugEnabledKey, 'broken');
        final corrupt = await translateHandlerErrors(
          handlers.handleGetSettings(
            get('/api/sequencer/replay-debug/settings'),
          ),
        );
        expect(corrupt.statusCode, HttpStatus.internalServerError);
        final corruptBody = jsonDecode(await corrupt.readAsString()) as Map;
        expect(corruptBody['error'], 'replay_settings_corrupt');
      },
    );

    test('retention and clear mutate the host authority', () async {
      final retention = await handlers.handleSetRetention(
        post('/api/sequencer/replay-debug/settings/retention', {'days': 45}),
      );
      expect(
        (jsonDecode(await retention.readAsString()) as Map)['retentionDays'],
        45,
      );
      expect(
        await database.settingsDao.getSetting(replayDebugRetentionDaysKey),
        '45',
      );

      final cleared = await handlers.handleClear(
        post('/api/sequencer/replay-debug/clear'),
      );
      expect((jsonDecode(await cleared.readAsString()) as Map)['removed'], 1);
      expect(
        await container.read(replayDebugServiceProvider).countByRun(42),
        0,
      );
    });
  });
}
