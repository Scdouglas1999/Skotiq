// Persistence coverage for the sequencer density preference: the default on a
// fresh store, a write/read round-trip through SettingsDao, a fresh notifier
// re-hydrating the stored value, an unknown stored value falling back safely,
// and the mobile pin to comfortable.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/mock_database.dart';

void main() {
  test('defaults to ledger on a fresh store', () async {
    final db = mockDatabase();
    addTearDown(db.close);
    final container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);

    expect(await container.read(sequencerDensityPrefsProvider.future),
        SequencerDensity.ledger);
    // The synchronous view resolves to the same default while hydrating.
    expect(container.read(sequencerDensityProvider), SequencerDensity.ledger);
  });

  test('setDensity persists and a fresh notifier reads it back', () async {
    final db = mockDatabase();
    addTearDown(db.close);
    final container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);

    await container
        .read(sequencerDensityPrefsProvider.notifier)
        .setDensity(SequencerDensity.compact);

    // The sync provider follows the write immediately.
    expect(container.read(sequencerDensityProvider), SequencerDensity.compact);
    // The row landed under the shared settings key.
    expect(await SettingsDao(db).getSetting('sequencer_density_v1'), 'compact');

    // A fresh container hydrates from the database, not memory.
    final container2 =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container2.dispose);
    expect(await container2.read(sequencerDensityPrefsProvider.future),
        SequencerDensity.compact);
  });

  test('unrecognised stored value falls back to the default', () async {
    final db = mockDatabase();
    addTearDown(db.close);
    await SettingsDao(db).setSetting('sequencer_density_v1', 'side-by-side');
    final container =
        ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);

    expect(await container.read(sequencerDensityPrefsProvider.future),
        SequencerDensity.ledger);
  });

  test('mobile pins every preference to comfortable', () {
    expect(effectiveSequencerDensity(SequencerDensity.ledger, isMobile: true),
        SequencerDensity.comfortable);
    expect(effectiveSequencerDensity(SequencerDensity.compact, isMobile: true),
        SequencerDensity.comfortable);
    expect(effectiveSequencerDensity(SequencerDensity.ledger, isMobile: false),
        SequencerDensity.ledger);
  });
}
