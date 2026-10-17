// Round-trip the LiveStacking / broadcast defaults through the
// SequencerDefaultsNotifier. Each new field exposed in the
// "Live Stacking & Broadcast" Settings section must:
//   * default to its initial value,
//   * persist through the SettingsDao,
//   * reload to the same value on next build (via `_loadDefaults`).

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' hide Sequence;
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/sequence/sequencer_defaults.dart';

/// Warm the SequencerDefaultsNotifier and wait for its `_loadDefaults`
/// async work (which reads ~20 keys from the SettingsDao) to settle
/// before the test reads state. Mirrors the convention in
/// `sequence_executor_defaults_test.dart`.
Future<void> _warmAndPump(ProviderContainer container) async {
  container.read(sequencerDefaultsProvider);
  await Future<void>.delayed(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SequencerDefaults LiveStacking & Broadcast', () {
    late SkotiqDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
    });

    tearDown(() async {
      container.dispose();
      // Drain microtasks so the notifier's _loadDefaults Future finishes
      // before we close the underlying database.
      await Future<void>.delayed(Duration.zero);
      await db.close();
    });

    test('first build returns sane initial defaults', () async {
      await _warmAndPump(container);
      final defaults = container.read(sequencerDefaultsProvider);
      expect(defaults.livestackingDefaultPort, 8081);
      expect(defaults.livestackingPublicByDefault, isFalse);
      expect(
        defaults.livestackingDefaultStackMethod,
        LiveStackingMethod.average,
      );
      expect(defaults.livestackingDefaultWatermark, isNull);
      expect(
        defaults.livestackingDefaultThumbnailSize,
        LiveStackingThumbnailSize.medium,
      );
      expect(defaults.livestackingDisableEverywhere, isFalse);
    });

    test('updateLiveStackingDefaults persists each new field', () async {
      await _warmAndPump(container);
      final notifier = container.read(sequencerDefaultsProvider.notifier);

      await notifier.updateLiveStackingDefaults(
        defaultPort: 9090,
        publicByDefault: true,
        defaultStackMethod: LiveStackingMethod.medianRej,
        defaultWatermark: r'M31 — L ${integration.hms}',
        defaultThumbnailSize: LiveStackingThumbnailSize.large,
        disableEverywhere: true,
      );

      final after = container.read(sequencerDefaultsProvider);
      expect(after.livestackingDefaultPort, 9090);
      expect(after.livestackingPublicByDefault, isTrue);
      expect(
        after.livestackingDefaultStackMethod,
        LiveStackingMethod.medianRej,
      );
      expect(after.livestackingDefaultWatermark, r'M31 — L ${integration.hms}');
      expect(
        after.livestackingDefaultThumbnailSize,
        LiveStackingThumbnailSize.large,
      );
      expect(after.livestackingDisableEverywhere, isTrue);

      // Verify the SettingsDao persisted everything verbatim.
      final dao = container.read(settingsDaoProvider);
      expect(await dao.getSetting('livestacking_default_port'), '9090');
      expect(await dao.getSetting('livestacking_public_by_default'), 'true');
      expect(
        await dao.getSetting('livestacking_default_stack_method'),
        'median_rej',
      );
      expect(
        await dao.getSetting('livestacking_default_watermark'),
        r'M31 — L ${integration.hms}',
      );
      expect(
        await dao.getSetting('livestacking_default_thumbnail_size'),
        'large',
      );
      expect(await dao.getSetting('livestacking_disable_everywhere'), 'true');
    });

    test('clearing watermark to null persists as empty string', () async {
      await _warmAndPump(container);
      final notifier = container.read(sequencerDefaultsProvider.notifier);
      await notifier.updateLiveStackingDefaults(defaultWatermark: 'hello');
      expect(
        container.read(sequencerDefaultsProvider).livestackingDefaultWatermark,
        'hello',
      );
      await notifier.updateLiveStackingDefaults(defaultWatermark: null);
      expect(
        container.read(sequencerDefaultsProvider).livestackingDefaultWatermark,
        isNull,
      );
      // Persisted empty-string sentinel for "cleared".
      final dao = container.read(settingsDaoProvider);
      expect(await dao.getSetting('livestacking_default_watermark'), '');
    });
  });

  group('LiveStackingThumbnailSize', () {
    test('storageKey round-trips through fromStorageKey', () {
      for (final size in LiveStackingThumbnailSize.values) {
        expect(LiveStackingThumbnailSize.fromStorageKey(size.storageKey), size);
      }
      // Unknown key falls back to medium (defence-in-depth).
      expect(
        LiveStackingThumbnailSize.fromStorageKey('hd-bogus'),
        LiveStackingThumbnailSize.medium,
      );
      expect(
        LiveStackingThumbnailSize.fromStorageKey(null),
        LiveStackingThumbnailSize.medium,
      );
    });

    test('label includes the pixel dimensions', () {
      expect(LiveStackingThumbnailSize.small.label, contains('640'));
      expect(LiveStackingThumbnailSize.medium.label, contains('1280'));
      expect(LiveStackingThumbnailSize.large.label, contains('1920'));
    });

    test('width/height map to the expected 16:9 pixel dimensions', () {
      expect(LiveStackingThumbnailSize.small.width, 640);
      expect(LiveStackingThumbnailSize.small.height, 360);
      expect(LiveStackingThumbnailSize.medium.width, 1280);
      expect(LiveStackingThumbnailSize.medium.height, 720);
      expect(LiveStackingThumbnailSize.large.width, 1920);
      expect(LiveStackingThumbnailSize.large.height, 1080);
    });
  });
}
