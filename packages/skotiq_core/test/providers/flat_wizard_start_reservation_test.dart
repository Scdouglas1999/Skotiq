import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../mocks/mock_database.dart';

void main() {
  test('flat wizard reserves startup while the save dialog is open', () async {
    final db = createTestDatabase();
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final notifier = container.read(flatWizardProvider.notifier);
    await pumpEventQueue();

    expect(notifier.reserveStartPrompt(), isTrue);
    expect(notifier.isBusy, isTrue);
    expect(notifier.reserveStartPrompt(), isFalse);

    notifier.releaseStartPrompt();
    expect(notifier.isBusy, isFalse);
    expect(notifier.reserveStartPrompt(), isTrue);
  });
}
