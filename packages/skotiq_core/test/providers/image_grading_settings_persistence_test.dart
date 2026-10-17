import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late ProviderContainer container;

  setUp(() async {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    await container.read(appSettingsProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('rejects non-finite and out-of-range grading thresholds', () async {
    final notifier = container.read(appSettingsProvider.notifier);

    await expectLater(
      notifier.setImageGradingHfrThreshold(double.nan),
      throwsArgumentError,
    );
    await expectLater(
      notifier.setImageGradingEccentricityThreshold(1.1),
      throwsArgumentError,
    );
    await expectLater(
      notifier.setImageGradingStarCountMin(0),
      throwsArgumentError,
    );
    await expectLater(
      notifier.setImageGradingMaxConsecutiveRejects(101),
      throwsArgumentError,
    );

    final settings = container.read(appSettingsProvider).value!;
    expect(settings.imageGradingHfrThresholdPx, 3.5);
    // The default (0.8 since the owner's 2026-10-06 decision), unchanged by
    // the rejected 1.1.
    expect(settings.imageGradingEccentricityThreshold, 0.8);
    expect(settings.imageGradingStarCountMin, 10);
    expect(settings.imageGradingMaxConsecutiveRejects, 3);
  });

  test('valid thresholds and cleared optional checks survive reload', () async {
    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.setImageGradingHfrThreshold(4.25);
    await notifier.setImageGradingStarCountMin(null);
    await notifier.setImageGradingMaxConsecutiveRejects(7);

    container.invalidate(appSettingsProvider);
    final reloaded = await container.read(appSettingsProvider.future);
    expect(reloaded.imageGradingHfrThresholdPx, 4.25);
    expect(reloaded.imageGradingStarCountMin, isNull);
    expect(reloaded.imageGradingMaxConsecutiveRejects, 7);
  });
}
