// The Framing side column after its redesign into one panel: the sections
// come in a fixed order, every action the old column offered is still on it
// and still does its job, and the column lays out without overflow at the
// panel's 250 px minimum.

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/framing/framing_screen.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_panel_parts.dart';
import 'package:skotiq_app/widgets/slew_dropdown_button.dart';
import 'package:skotiq_app/widgets/tutorial_keys/framing_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Seeds the framing state and records the calls the column makes that would
/// otherwise reach the network or the database.
class _RecordingFraming extends FramingNotifier {
  _RecordingFraming(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }

  int surveyLoads = 0;
  int saves = 0;

  @override
  Future<void> loadSurveyImage({double? canvasWidthLogicalPx}) async {
    surveyLoads++;
  }

  @override
  Future<void> saveTarget() async {
    saves++;
  }
}

class _SeededMount extends MountStateNotifier {
  _SeededMount(super.ref, MountState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

class _SeededSettings extends AppSettingsNotifier {
  _SeededSettings(this._seed);
  final AppSettingsState _seed;

  @override
  Future<AppSettingsState> build() async => _seed;
}

const _m42 = FramingTarget(
  name: 'M42',
  catalogId: 'NGC 1976',
  raHours: 5.588,
  decDegrees: -5.39,
  magnitude: 4.0,
);

const _ready = FramingEquipmentResult(
  status: EquipmentStatus.ready,
  profileName: 'My First Rig',
  equipment: FramingEquipment(
    cameraName: 'Simulated Camera',
    sensorWidthMm: 23.5,
    sensorHeightMm: 15.7,
    pixelSizeMicrons: 3.76,
    pixelsX: 6248,
    pixelsY: 4176,
    telescopeName: 'My First Rig',
    focalLengthMm: 530,
    apertureMm: 106,
  ),
);

FramingState _mosaicState() => FramingState(
      target: _m42,
      previewFovDegrees: 3,
      surveyImageBytes: Uint8List.fromList(const [1, 2, 3]),
      mosaicEnabled: true,
      mosaicPanels: [
        for (var i = 0; i < 4; i++)
          FramingMosaicPanel(
            index: i,
            column: i % 2,
            row: i ~/ 2,
            centerRaHours: 5.588 + (i.isEven ? -0.05 : 0.05),
            centerDecDegrees: -5.39 + (i < 2 ? 0.6 : -0.6),
            name: 'M42 Panel ${i + 1}',
          ),
      ],
    );

/// Desktop density: the column's 28 px controls are what the owner sees.
final _desktop = TargetPlatformVariant.only(TargetPlatform.linux);

/// Matches of [finder] inside the side column (right of the canvas), top to
/// bottom; the canvas draws target names of its own.
List<Rect> _inColumn(WidgetTester tester, Finder finder) {
  final rects = [
    for (final element in finder.evaluate())
      tester.getRect(find.byElementPredicate((e) => e == element)),
  ].where((r) => r.left > 1100 - 330).toList()
    ..sort((a, b) => a.top.compareTo(b.top));
  return rects;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingFraming framing;

  Future<HarnessHandle> pumpColumn(
    WidgetTester tester, {
    FramingState? state,
    FramingEquipmentResult equipment = _ready,
    double height = 2600,
  }) async {
    final handle = await pumpAppScreen(
      tester,
      const FramingView(),
      // Tall enough that the whole column is laid out without scrolling.
      size: Size(1100, height),
      settle: false,
      extraOverrides: [
        framingProvider.overrideWith(
          (ref) => framing = _RecordingFraming(ref, state ?? _mosaicState()),
        ),
        framingFOVProvider.overrideWith((ref) async => equipment),
        mountStateProvider.overrideWith(
          (ref) => _SeededMount(
            ref,
            const MountState(
              connectionState: DeviceConnectionState.connected,
              isParked: false,
            ),
          ),
        ),
        appSettingsProvider.overrideWith(
          () => _SeededSettings(
            const AppSettingsState(latitude: 47.6, longitude: -122.3),
          ),
        ),
      ],
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return handle;
  }

  /// Taps [finder] after bringing it on screen.
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('sections read top to bottom in one fixed order',
      variant: _desktop, (tester) async {
    await pumpColumn(tester);

    final titles = [
      'M42',
      'Telescope',
      'Sequence',
      'Camera',
      'Rotation',
      'Sky view',
      'Mosaic'
    ];
    final tops = <double>[];
    for (final title in titles) {
      final rects = _inColumn(
        tester,
        find.byWidgetPredicate(
          (w) => w is FramingPanelSection && w.title == title,
        ),
      );
      expect(rects, isNotEmpty, reason: '$title section is missing');
      tops.add(rects.first.top);
    }
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]),
          reason: '${titles[i]} must sit below ${titles[i - 1]}');
    }
    // The old column's second slew button and duplicate survey/preview
    // controls are gone: one of each.
    expect(find.byType(SlewDropdownButton), findsOneWidget);
    expect(find.text('Survey'), findsOneWidget);
  });

  testWidgets('every action is on the column and enabled with a target',
      variant: _desktop, (tester) async {
    await pumpColumn(tester);

    expect(find.byTooltip('Copy coordinates'), findsOneWidget);
    expect(find.byTooltip('Save target'), findsOneWidget);
    expect(
      tester
          .widget<SlewDropdownButton>(find.byKey(FramingTutorialKeys.slewBtn))
          .isEnabled,
      isTrue,
    );
    for (final label in [
      'Auto-build sequence',
      'Add to sequence',
      'Create mosaic project (4 panels)',
    ]) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byType(SkotiqButton),
      );
      expect(button, findsOneWidget, reason: label);
      expect(tester.widget<SkotiqButton>(button).onPressed, isNotNull,
          reason: '$label must be live with a target');
    }
    expect(find.text('Solve latest camera frame'), findsOneWidget);
    expect(find.text('Reload image'), findsOneWidget);
    expect(find.text('Cache image'), findsOneWidget);
    expect(find.text('Sequence'), findsOneWidget);
    // The mosaic's panels ride along to Add to sequence; the section says so.
    expect(find.text('4 mosaic panels'), findsOneWidget);
  });

  testWidgets('the column controls drive the framing state', variant: _desktop,
      (tester) async {
    final handle = await pumpColumn(tester);
    FramingState read() => handle.container.read(framingProvider);

    // Panel 3 in the list, before any grid change regenerates the panels.
    await tap(tester, find.text('3'));
    expect(read().selectedPanelIndex, 2);

    await tap(tester, find.byTooltip('Save target'));
    expect(framing.saves, 1);

    await tap(tester, find.text('Reload image'));
    expect(framing.surveyLoads, greaterThanOrEqualTo(1));

    await tap(tester, find.text('+90'));
    expect(read().rotation, 90);

    expect(read().showGrid, isTrue);
    await tap(tester, find.text('Grid').first);
    expect(read().showGrid, isFalse);

    await tap(tester, find.text('Labels'));
    expect(read().showLabels, isFalse);

    await tap(tester, find.text('Numbers'));
    expect(
        read().showPanelNumbers, isNot(const FramingState().showPanelNumbers));

    await tap(tester, find.text('BR'));
    expect(read().mosaicConfig.startCorner, MosaicStartCorner.bottomRight);

    await tap(tester, find.text('5°'));
    expect(read().previewFovDegrees, 5.0);

    // The Columns stepper's +, the first + in the column (the canvas has its
    // own zoom +).
    final plus = _inColumn(tester, find.byIcon(LucideIcons.plus)).first;
    await tester.tapAt(plus.center);
    await tester.pump(const Duration(milliseconds: 50));
    expect(read().mosaicConfig.columns, 3);
  });

  testWidgets('Sky view folds away and comes back', variant: _desktop,
      (tester) async {
    await pumpColumn(tester);
    expect(find.text('Survey'), findsOneWidget);

    await tap(tester, find.text('Sky view'));
    expect(find.text('Survey'), findsNothing);

    await tap(tester, find.text('Sky view'));
    expect(find.text('Survey'), findsOneWidget);
  });

  testWidgets('no target: an empty state, and nothing to act on',
      variant: _desktop, (tester) async {
    await pumpColumn(tester, state: const FramingState());

    expect(find.text('No target selected'), findsOneWidget);
    expect(find.text('No target'), findsOneWidget);
    expect(find.byType(SlewDropdownButton), findsNothing);
    for (final label in ['Auto-build sequence', 'Add to sequence']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byType(SkotiqButton),
      );
      expect(tester.widget<SkotiqButton>(button).onPressed, isNull,
          reason: '$label has nothing to add without a target');
    }
  });

  testWidgets('a mosaic without a camera says why it is off', variant: _desktop,
      (tester) async {
    await pumpColumn(
      tester,
      state: const FramingState(target: _m42),
      equipment:
          const FramingEquipmentResult(status: EquipmentStatus.noProfile),
    );

    expect(find.text('Set up equipment to plan a mosaic.'), findsOneWidget);
    expect(
      find.textContaining('No equipment profile', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Needs a camera'), findsOneWidget);
  });

  testWidgets('lays out without overflow at the 250 px panel minimum',
      variant: _desktop, (tester) async {
    await pumpColumn(tester);
    // The resize handle sits just left of the 320 px panel; drag it 70 px
    // toward the panel.
    await tester.dragFrom(
        const Offset(1100 - 320 - 5, 300), const Offset(70, 0));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final survey = tester.getRect(find.text('Sky view'));
    expect(survey.left, greaterThan(1100 - 260),
        reason: 'the panel should now be about 250 px wide');
    expect(tester.takeException(), isNull);
  });
}
