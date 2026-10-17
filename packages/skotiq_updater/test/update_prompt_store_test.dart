// When the app checks, and when it is allowed to interrupt you about what it
// found. Getting this wrong is not a crash — it is either an update prompt
// appearing over a running sequence, or a release nobody is ever told about.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_updater/src/providers/update_provider.dart';
import 'package:skotiq_updater/src/services/update_prompt_store.dart';
import 'package:skotiq_updater/src/services/update_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dataDir;
  late UpdatePromptStore store;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('sk-prompt-');
    store = UpdatePromptStore(() async => dataDir);
  });

  tearDown(() async {
    if (await dataDir.exists()) await dataDir.delete(recursive: true);
  });

  final now = DateTime.utc(2026, 9, 22, 20);

  group('check throttling', () {
    test('a first run is always due', () {
      expect(
        const UpdatePromptState().isCheckDue(now, const Duration(hours: 12)),
        isTrue,
      );
    });

    test('a recent check is not repeated', () {
      final state = UpdatePromptState(
        lastCheckAt: now.subtract(const Duration(hours: 2)),
      );
      expect(state.isCheckDue(now, const Duration(hours: 12)), isFalse);
    });

    test('the interval elapsing makes it due again', () {
      final state = UpdatePromptState(
        lastCheckAt: now.subtract(const Duration(hours: 12, minutes: 1)),
      );
      expect(state.isCheckDue(now, const Duration(hours: 12)), isTrue);
    });

    test('a clock that jumped forward does not suppress checks', () {
      // The rig's clock gets set by hand and by GPS. A stored time in the
      // future would otherwise block every check until real time caught up
      // — potentially for years.
      final state = UpdatePromptState(
        lastCheckAt: now.add(const Duration(days: 365)),
      );
      expect(state.isCheckDue(now, const Duration(hours: 12)), isTrue);
    });
  });

  group('deferral', () {
    const remindAfter = Duration(days: 3);

    test('a freshly deferred version stays quiet', () {
      final state = UpdatePromptState(
        deferredVersion: '7.2.0',
        deferredAt: now.subtract(const Duration(hours: 1)),
      );
      expect(state.isDeferred('7.2.0', now, remindAfter), isTrue);
    });

    test('the reminder window expiring asks again', () {
      final state = UpdatePromptState(
        deferredVersion: '7.2.0',
        deferredAt: now.subtract(const Duration(days: 3, hours: 1)),
      );
      expect(state.isDeferred('7.2.0', now, remindAfter), isFalse);
    });

    test('a newer version asks immediately', () {
      // "Not now" was about that build, not about updates in general.
      final state = UpdatePromptState(
        deferredVersion: '7.2.0',
        deferredAt: now,
      );
      expect(state.isDeferred('7.3.0', now, remindAfter), isFalse);
    });

    test('a deferral timestamped in the future expires', () {
      final state = UpdatePromptState(
        deferredVersion: '7.2.0',
        deferredAt: now.add(const Duration(days: 30)),
      );
      expect(state.isDeferred('7.2.0', now, remindAfter), isFalse);
    });

    test('clearing a deferral keeps the last check time', () {
      final state = UpdatePromptState(
        lastCheckAt: now,
        deferredVersion: '7.2.0',
        deferredAt: now,
      ).copyWith(clearDeferral: true);

      expect(state.deferredVersion, isNull);
      expect(state.deferredAt, isNull);
      // Clearing a skip must not also make the app re-check immediately.
      expect(state.lastCheckAt, now);
    });
  });

  group('persistence', () {
    test('state survives a round trip', () async {
      await store.write(
        UpdatePromptState(
          lastCheckAt: now,
          deferredVersion: '7.2.0',
          deferredAt: now.subtract(const Duration(days: 1)),
        ),
      );

      final read = await store.read();
      expect(read.lastCheckAt, now);
      expect(read.deferredVersion, '7.2.0');
      expect(read.deferredAt, now.subtract(const Duration(days: 1)));
    });

    test('an absent file reads as empty rather than throwing', () async {
      final read = await store.read();
      expect(read.lastCheckAt, isNull);
      expect(read.deferredVersion, isNull);
    });

    test('a corrupt file reads as empty', () async {
      // Losing the record costs one extra check and one extra prompt. Failing
      // here instead would mean never updating again.
      final file = File(p.join(dataDir.path, 'updates', 'prompt_state.json'));
      await file.parent.create(recursive: true);
      await file.writeAsString('{not json');

      final read = await store.read();
      expect(read.lastCheckAt, isNull);
      expect(read.deferredVersion, isNull);
      expect(
        read.isCheckDue(now, const Duration(hours: 12)),
        isTrue,
        reason: 'a lost record must not disable update checks',
      );
    });

    test('overlapping writes leave the last one, whole', () async {
      // The provider fires some writes without awaiting them. Two that
      // overlapped used to open the same file twice and write at offset 0
      // from both handles, leaving the shorter JSON followed by the tail of
      // the longer one (unreadable, so the deferral was lost) or the older
      // state on top. Measured before the fix: 165 of 200 rounds corrupt.
      for (var round = 0; round < 50; round++) {
        unawaited(
          store.write(
            UpdatePromptState(
              lastCheckAt: now,
              deferredVersion: '7.2.0-a-long-prerelease-name.$round',
              deferredAt: now,
            ),
          ),
        );
        await store.write(
          UpdatePromptState(lastCheckAt: now.add(Duration(minutes: round))),
        );

        final raw = await File(
          p.join(dataDir.path, 'updates', 'prompt_state.json'),
        ).readAsString();
        expect(() => jsonDecode(raw), returnsNormally, reason: raw);
        final read = await store.read();
        expect(read.lastCheckAt, now.add(Duration(minutes: round)));
        expect(read.deferredVersion, isNull);
      }
    });

    test('writes land beside the other update markers', () async {
      await store.write(UpdatePromptState(lastCheckAt: now));
      expect(
        await File(
          p.join(dataDir.path, 'updates', 'prompt_state.json'),
        ).exists(),
        isTrue,
      );
    });
  });

  test('a slow startup read cannot clobber a check it raced', () async {
    // The store load is async and the startup check fires on a timer. If the
    // load lands after a check recorded its timestamp, it used to overwrite it
    // with the stale on-disk value and the next launch would check again.
    final slow = _SlowPromptStore(() async => dataDir)
      ..stored = const UpdatePromptState();

    final notifier = UpdateNotifier(
      currentVersion: '7.1.0',
      currentBuildNumber: 28,
      promptStore: slow,
      updateService: UpdateService(
        currentVersion: '7.1.0',
        currentBuildNumber: 28,
        applicationSupportDirectoryProvider: () async => dataDir,
      ),
    );
    addTearDown(notifier.dispose);

    // Start a check while the load is still outstanding, then release it.
    final checking = notifier.checkForUpdatesIfDue(now: now);
    slow.gate.complete();
    await checking;

    // The check ran and its time was kept, so the next launch stays quiet.
    expect(slow.stored.lastCheckAt, isNotNull);
    await notifier.checkForUpdatesIfDue(
      now: now.add(const Duration(minutes: 1)),
    );
    expect(slow.stored.lastCheckAt, now);
  });
}

/// A store whose read resolves only when the test lets it, so the startup
/// race can be reproduced deterministically.
class _SlowPromptStore extends UpdatePromptStore {
  _SlowPromptStore(super.dataDirectoryProvider);

  final Completer<void> gate = Completer<void>();
  UpdatePromptState stored = const UpdatePromptState();

  @override
  Future<UpdatePromptState> read() async {
    await gate.future;
    return stored;
  }

  @override
  Future<void> write(UpdatePromptState state) async {
    stored = state;
  }
}
