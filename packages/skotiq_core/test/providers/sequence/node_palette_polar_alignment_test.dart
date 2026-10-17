import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/sequence/node_palette.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

/// Minimal settings notifier so the palette sees a known observer latitude
/// without touching the persisted store.
class _FixedSettingsNotifier extends AppSettingsNotifier {
  _FixedSettingsNotifier(this._initial);

  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

Future<(ProviderContainer, SkotiqDatabase)> _container(
  double latitudeDeg,
) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      appSettingsProvider.overrideWith(
        () => _FixedSettingsNotifier(AppSettingsState(latitude: latitudeDeg)),
      ),
    ],
  );
  await container.read(appSettingsProvider.future);
  // Build the palette once and let SequencerDefaultsNotifier's async load
  // settle; disposing the container mid-load makes it publish onto a disposed
  // notifier and the whole test fails on unrelated plumbing.
  container.read(nodePaletteProvider);
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return (container, db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Polar Alignment is reachable from the node palette', () async {
    final (container, db) = await _container(41.5);
    addTearDown(() async {
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await db.close();
    });

    final categories = container.read(nodePaletteProvider);
    final mount = categories.singleWhere((c) => c.name == 'Mount');
    final item = mount.items.singleWhere((i) => i.name == 'Polar alignment');

    expect(item.createNode(), isA<PolarAlignmentNode>());
  });

  test('palette search for "polar" finds the node', () async {
    final (container, db) = await _container(41.5);
    addTearDown(() async {
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await db.close();
    });

    final matches = container
        .read(nodePaletteProvider)
        .expand((c) => c.items)
        .where(
          (i) =>
              i.name.toLowerCase().contains('polar') ||
              i.description.toLowerCase().contains('polar'),
        );

    expect(matches, isNotEmpty);
  });

  test(
    'a southern-hemisphere site gets a south-pole polar alignment node',
    () async {
      final (container, db) = await _container(-33.9);
      addTearDown(() async {
        container.dispose();
        await Future<void>.delayed(Duration.zero);
        await db.close();
      });

      final item = container
          .read(nodePaletteProvider)
          .expand((c) => c.items)
          .singleWhere((i) => i.name == 'Polar alignment');

      expect((item.createNode() as PolarAlignmentNode).isNorth, isFalse);
    },
  );

  test(
    'a northern-hemisphere site gets a north-pole polar alignment node',
    () async {
      final (container, db) = await _container(41.5);
      addTearDown(() async {
        container.dispose();
        await Future<void>.delayed(Duration.zero);
        await db.close();
      });

      final item = container
          .read(nodePaletteProvider)
          .expand((c) => c.items)
          .singleWhere((i) => i.name == 'Polar alignment');

      expect((item.createNode() as PolarAlignmentNode).isNorth, isTrue);
    },
  );
}
