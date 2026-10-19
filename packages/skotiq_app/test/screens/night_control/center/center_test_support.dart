// Pumps the Tonight center column (or one of its parts) with a board's view
// models, inside the density a NightControlLayout would publish.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/center/frame_stage.dart';
import 'package:skotiq_app/screens/night_control/center/frame_strip.dart';
import 'package:skotiq_app/screens/night_control/center/night_center.dart';
import 'package:skotiq_app/screens/night_control/center/session_charts_row.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_series_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/night_control_layout.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_backend.dart';
import '../fixtures/night_fixtures.dart';

/// Records what the action bar asked of the controller.
class FakeNightActionApi implements NightActionApi {
  final List<ManualActionId> ran = <ManualActionId>[];
  int cancels = 0;

  @override
  ManualActionState get state => ManualActionState.idle;

  @override
  Future<void> run(ManualActionId id) async => ran.add(id);

  @override
  Future<void> cancel() async => cancels++;

  @override
  Future<void> snapshot() async {}
  @override
  Future<void> toggleLoop() async {}
  @override
  Future<void> autofocus() async {}
  @override
  Future<void> solveAndSync() async {}
  @override
  Future<void> center() async {}
  @override
  Future<void> dither() async {}
  @override
  Future<void> flipNow() async {}
  @override
  Future<void> toggleTracking() async {}
  @override
  Future<void> toggleCooler() async {}
  @override
  DateTime? get armedStartAt => null;
  @override
  Future<void> armStartAtDark() async {}
  @override
  void cancelArmedStart() {}
}

/// A tiny frame; the stage decodes it, but the tests read the pills.
CapturedImageData testFrame({
  String? filePath = '/data/M74/M74_Ha_0043.fits',
  String filter = 'Ha',
  double exposure = 180,
}) =>
    CapturedImageData(
      width: 6,
      height: 4,
      displayData: Uint8List(6 * 4 * 4),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(mean: 100, stdDev: 5, hfr: 2.13),
      capturedAt: NightFixtures.at(23, 49, 12),
      settings: ExposureSettings(
        exposureTime: exposure,
        gain: 139,
        offset: 21,
        filter: filter,
      ),
      filePath: filePath,
    );

/// The board's strip with file paths, so a frame on the stage can be
/// matched to its row.
List<StripFrameVm> stripWithPaths(List<StripFrameVm> frames) => <StripFrameVm>[
      for (final f in frames)
        StripFrameVm(
          id: f.id,
          frameNumber: f.frameNumber,
          capturedAt: f.capturedAt,
          filter: f.filter,
          exposureSecs: f.exposureSecs,
          hfr: f.hfr,
          starCount: f.starCount,
          accepted: f.accepted,
          filePath: '/data/M74/M74_Ha_00${f.frameNumber}.fits',
          isNewest: f.isNewest,
        ),
    ];

/// Everything the center column reads, from [board] unless overridden.
List<Override> centerOverrides(
  NightBoard board, {
  NightActionApi? api,
  CapturedImageData? image,
  List<StripFrameVm>? frames,
  NightExposureVm? exposure,
  NightAutofocusVm? autofocus,
  NightStageSolveVm? solve,
  ManualActionState? actionState,
  NightSeriesVm? guideSeries,
  NightLastSessionVm? lastSession,
  NightAutofocusCurveVm? lastAutofocus,
  NightGuiderIdleVm? guider,
  NightSeriesVm? coolerHistory,
}) {
  final backend = MockBackend();
  when(() => backend.getImageThumbnail(any()))
      .thenAnswer((_) async => Uint8List(0));
  return <Override>[
    nightRunPhaseProvider.overrideWithValue(board.phase),
    nightSessionFramesProvider.overrideWithValue(frames ?? board.frames),
    nightFrameSeriesProvider.overrideWithValue(board.frameSeries),
    nightGuideSeriesProvider.overrideWithValue(
      guideSeries ?? board.guideSeries,
    ),
    nightTemperatureSeriesProvider.overrideWithValue(board.temperatureSeries),
    nightCoolerHistoryProvider.overrideWithValue(
      coolerHistory ?? const NightSeriesVm(lines: <SeriesLineVm>[]),
    ),
    nightManualActionsProvider.overrideWithValue(board.actions),
    nightActionStateProvider.overrideWithValue(
      actionState ?? board.actionState,
    ),
    nightActionApiProvider.overrideWithValue(api ?? FakeNightActionApi()),
    nightStageImageProvider.overrideWithValue(image),
    nightStageExposureProvider.overrideWithValue(exposure),
    nightStageAutofocusProvider.overrideWithValue(autofocus),
    nightStageSolveProvider.overrideWithValue(solve),
    nightStageStretchProvider.overrideWithValue(false),
    nightLastSessionProvider.overrideWithValue(lastSession),
    nightLastAutofocusProvider.overrideWithValue(lastAutofocus),
    nightGuiderIdleProvider.overrideWithValue(
      guider ??
          const NightGuiderIdleVm(
            connected: true,
            canCommand: true,
            state: Phd2State.stopped,
          ),
    ),
    stretchedImageProvider.overrideWith((ref) async => null),
    clockProvider.overrideWithValue(const SystemClock()),
    imagingBackendProvider.overrideWithValue(backend),
    isRemoteModeProvider.overrideWithValue(false),
  ];
}

/// Pumps [child] (the whole center column by default) in a [size] center
/// slot. [mode] picks the density; the single column scrolls the page.
Future<ProviderContainer> pumpCenter(
  WidgetTester tester,
  List<Override> overrides, {
  Size size = const Size(744, 758),
  NightControlMode mode = NightControlMode.threeColumn,
  double textScale = 1,
  Widget child = const NightCenter(),
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  final single = mode == NightControlMode.singleColumn;
  final density = NightControlDensity(
    mode: mode,
    centerWidth: size.width,
    compactHeight: size.height < NightControlLayout.compactBodyHeight,
    planDrawerOpen: false,
    openPlanDrawer: null,
    closePlanDrawer: null,
    child: child,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme ?? SkotiqTheme.dark,
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: app!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: single ? SingleChildScrollView(child: density) : density,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}
