// The sequence timeline draws the twilight of the site's night that holds the
// run's start. A run that starts after midnight shows this morning's dawn
// bands, not the next evening's dusk.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_timeline.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// 01:00 local on a November night.
final _start = DateTime(2026, 11, 22, 1);

/// A longitude whose solar time is the host's clock time, so 01:00 on the
/// host is 01:00 at the site in every timezone.
final _longitude = _start.timeZoneOffset.inMinutes / 4.0;

class _LocatedSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      AppSettingsState(latitude: 40.02, longitude: _longitude);
}

/// Six hours of exposures: 01:00 to 07:00, through every dawn twilight.
Sequence _smallHoursSequence() {
  final exposure = ExposureNode(
    name: 'Small hours',
    durationSecs: 6 * 3600,
    count: 1,
    ditherEvery: null,
  );
  final root = InstructionSetNode(name: 'Root', childIds: [exposure.id]);
  return Sequence.create(
    name: 'After midnight',
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

  testWidgets('a run starting at 01:00 shows the dawn bands', (tester) async {
    final editor = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    editor.state = _smallHoursSequence();
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
            body:
                SequenceTimeline(colors: SkotiqColors.dark, startTime: _start),
          ),
        ),
      ),
    );
    await container.read(appSettingsProvider.future);
    await tester.pump();

    // Band regions are Positioned containers; the legend swatches are not.
    final bands = tester
        .widgetList<Positioned>(find.byType(Positioned))
        .map((p) => p.child)
        .whereType<Container>()
        .map((c) => c.color)
        .toSet();
    for (final MapEntry(key: name, value: hue) in {
      'astronomical': namedAstroTwilightBand,
      'nautical': namedNauticalTwilightBand,
      'civil': namedCivilTwilightBand,
    }.entries) {
      expect(bands, contains(hue), reason: 'no $name dawn band is drawn');
    }
  });
}
