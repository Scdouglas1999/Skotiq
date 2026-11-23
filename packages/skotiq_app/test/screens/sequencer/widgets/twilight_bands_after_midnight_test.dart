// The sequence timeline draws the twilight of every site night the run
// touches. A run that starts after midnight shows this morning's dawn bands,
// and one planned in the morning shows the coming evening's dusk.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_timeline.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A longitude whose solar time is the host's clock time, so 01:00 on the
/// host is 01:00 at the site in every timezone.
final _longitude = DateTime(2026, 11, 22).timeZoneOffset.inMinutes / 4.0;

class _LocatedSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      AppSettingsState(latitude: 40.02, longitude: _longitude);
}

Sequence _sequenceOf(Duration length) {
  final exposure = ExposureNode(
    name: 'Exposures',
    durationSecs: length.inSeconds.toDouble(),
    count: 1,
    ditherEvery: null,
  );
  final root = InstructionSetNode(name: 'Root', childIds: [exposure.id]);
  return Sequence.create(
    name: 'Twilight bands',
    rootNodeId: root.id,
    nodes: {root.id: root, exposure.id: exposure.copyWith(parentId: root.id)},
  );
}

void main() {
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1400, 1200);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Future<Set<Color?>> pumpBands(
    WidgetTester tester, {
    required DateTime start,
    required Duration length,
  }) async {
    final editor = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    editor.state = _sequenceOf(length);
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        currentSequenceProvider.overrideWith((_) => editor),
        appSettingsProvider.overrideWith(_LocatedSettings.new),
        sequencerOverheadConfigProvider.overrideWithValue(
          const SequenceOverheadConfig(downloadOverheadPerExposureSecs: 0),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SequenceTimeline(colors: SkotiqColors.dark, startTime: start),
          ),
        ),
      ),
    );
    await container.read(appSettingsProvider.future);
    await tester.pump();

    // Band regions are Positioned containers; the legend swatches are not.
    return tester
        .widgetList<Positioned>(find.byType(Positioned))
        .map((p) => p.child)
        .whereType<Container>()
        .map((c) => c.color)
        .toSet();
  }

  void expectAllBands(Set<Color?> bands, String when) {
    for (final MapEntry(key: name, value: hue) in {
      'astronomical': namedAstroTwilightBand,
      'nautical': namedNauticalTwilightBand,
      'civil': namedCivilTwilightBand,
    }.entries) {
      expect(bands, contains(hue), reason: 'no $name $when band is drawn');
    }
  }

  testWidgets('a run starting at 01:00 shows the dawn bands', (tester) async {
    final bands = await pumpBands(
      tester,
      start: DateTime(2026, 11, 22, 1),
      length: const Duration(hours: 6),
    );
    expectAllBands(bands, 'dawn');
  });

  testWidgets('a run planned at 10:00 shows the evening bands', (tester) async {
    final bands = await pumpBands(
      tester,
      start: DateTime(2026, 11, 22, 10),
      length: const Duration(hours: 12),
    );
    expectAllBands(bands, 'dusk');
  });

  testWidgets('a run starting at 16:00 shows the evening bands', (
    tester,
  ) async {
    final bands = await pumpBands(
      tester,
      start: DateTime(2026, 11, 22, 16),
      length: const Duration(hours: 4),
    );
    expectAllBands(bands, 'dusk');
  });
}
