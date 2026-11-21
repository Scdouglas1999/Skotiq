import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_stack/live_stack_darkroom_panel.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_stack/live_stack_darkroom_provider.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_stack/live_stack_formatters.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_stack/live_stack_frame_log_panel.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_stack/live_stack_tuning_panel.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart'
    show stackedPreviewStretchProvider;
import 'package:skotiq_app/screens/night_control/center/frame_stage.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _ScriptedDarkroomSeam implements DarkroomSeam {
  int registryCalls = 0;
  int renderCalls = 0;
  Completer<void>? registryGate;
  final List<String> renderedLiveKeys = [];
  final List<String> cancelledIds = [];

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    registryCalls++;
    final gate = registryGate;
    if (gate != null) await gate.future;
    return <String, dynamic>{
      'draft': <String, dynamic>{
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'opId': 'stretch',
            'params': <String, dynamic>{
              'blackPoint': 980.0,
              'whitePoint': 42000.0,
              'd': 3.5,
              'b': 2.0,
              'symmetryPoint': 0.04,
            },
          },
        ],
      },
    };
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    renderCalls++;
    final key = context['liveStackKey'] as String? ?? '';
    renderedLiveKeys.add(key);
    return DarkroomRenderedPreview(
      width: 4,
      height: 4,
      isColor: false,
      rgba: Uint8List(4 * 4 * 4)..fillRange(0, 4 * 4 * 4, 200),
      report: <String, dynamic>{
        'report': <String, dynamic>{
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'opId': 'background_extract',
              'outcome': 'applied',
            },
            <String, dynamic>{'opId': 'stretch', 'outcome': 'applied'},
          ],
        },
      },
    );
  }

  @override
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args) async {
    final id = args['renderId'] as String?;
    if (id != null) cancelledIds.add(id);
    return const <String, dynamic>{'cancelled': true};
  }

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async =>
      const <String, dynamic>{'valid': true};

  @override
  Future<Map<String, dynamic>> renderExport({
    required String recipeJson,
    required Map<String, dynamic> args,
  }) async =>
      const <String, dynamic>{};
}

class _TestLiveStackNotifier extends LiveStackingNotifier {
  _TestLiveStackNotifier(super.ref, LiveStackingState initial) {
    state = initial;
  }

  @override
  void selectFilter(String filterKey) {
    final snap = state.filterStacks[filterKey];
    if (snap == null) return;
    state = state.copyWith(
      selectedFilterKey: filterKey,
      stats: snap.stats,
      previewData: snap.previewData,
      previewWidth: snap.previewWidth,
      previewHeight: snap.previewHeight,
    );
  }
}

LiveStackingState _twoFilterActiveState() {
  final lPixels = Uint16List(16)..fillRange(0, 16, 1500);
  final haPixels = Uint16List(16)..fillRange(0, 16, 2200);
  final lSnap = FilterStackSnapshot(
    filterKey: 'L',
    stats: const LiveStackingStats(
      stackedFrameCount: 2,
      totalFramesAttempted: 2,
      avgMatchedPairs: 32,
      avgAlignmentResidual: 0.35,
      totalIntegrationSecs: 120,
    ),
    previewData: lPixels,
    previewWidth: 4,
    previewHeight: 4,
    channels: 1,
    revision: 2,
  );
  final haSnap = FilterStackSnapshot(
    filterKey: 'Ha',
    stats: const LiveStackingStats(
      stackedFrameCount: 1,
      totalFramesAttempted: 2,
      rejectedAlignmentFailures: 1,
      totalIntegrationSecs: 300,
    ),
    previewData: haPixels,
    previewWidth: 4,
    previewHeight: 4,
    channels: 1,
    revision: 1,
  );
  return LiveStackingState(
    status: LiveStackingStatus.running,
    isArmed: true,
    stats: lSnap.stats,
    previewData: lPixels,
    previewWidth: 4,
    previewHeight: 4,
    selectedFilterKey: 'L',
    filterStacks: <String, FilterStackSnapshot>{'L': lSnap, 'Ha': haSnap},
    frameLog: <LiveStackFrameEvent>[
      LiveStackFrameEvent(
        sequenceIndex: 2,
        filterKey: 'Ha',
        sourceLabel: 'ha_002.fits',
        accepted: false,
        rejectionReason: 'Alignment residual too high: 4.10px',
        timestamp: DateTime.utc(2026, 11, 20, 4, 2, 0),
      ),
      LiveStackFrameEvent(
        sequenceIndex: 2,
        filterKey: 'L',
        sourceLabel: 'l_002.fits',
        accepted: true,
        matchedPairs: 32,
        inlierPairs: 30,
        alignmentResidualPx: 0.35,
        shiftXPx: 1.1,
        shiftYPx: -0.4,
        timestamp: DateTime.utc(2026, 11, 20, 4, 1, 0),
      ),
    ],
  );
}

Widget _wrap(
  Widget child, {
  Key? scopeKey,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    key: scopeKey,
    overrides: [
      stackedPreviewStretchProvider.overrideWithValue(
        ({
          required int width,
          required int height,
          required List<int> data,
          required int channels,
        }) =>
            Uint8List(width * height * 4)
              ..fillRange(0, width * height * 4, 180),
      ),
      ...overrides,
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
      supportedLocales: SkotiqLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets(
    'Night Control FrameStage stays clean when idle and shows per-filter live stack switcher when active',
    (tester) async {
      // 1. Idle: mode pill does NOT appear.
      await tester.pumpWidget(
        _wrap(
          const SizedBox(width: 900, height: 600, child: FrameStage()),
          overrides: [
            liveStackingProvider.overrideWith(
              (ref) => _TestLiveStackNotifier(ref, const LiveStackingState()),
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('night_stage_mode_pill')), findsNothing);

      // 2. Active multi-filter live stack: mode pill appears and lets user
      // switch to Live stack + switch between L and Ha stacks.
      await tester.pumpWidget(
        _wrap(
          const SizedBox(width: 900, height: 600, child: FrameStage()),
          scopeKey: UniqueKey(),
          overrides: [
            liveStackingProvider.overrideWith(
              (ref) => _TestLiveStackNotifier(ref, _twoFilterActiveState()),
            ),
          ],
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('night_stage_mode_pill')),
        findsOneWidget,
      );
      expect(find.text('Live stack (3)'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('night_stage_mode_live_stack')),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byKey(const ValueKey('live_stack_filter_pill_L')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('live_stack_filter_pill_Ha')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('live_stack_filter_pill_Ha')));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('Live stack · Ha'), findsOneWidget);
    },
  );

  testWidgets(
    'LiveStackDarkroomPanel runs Auto-develop through DarkroomSeam with single registry call',
    (tester) async {
      final seam = _ScriptedDarkroomSeam();
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 340,
            height: 700,
            child: LiveStackDarkroomPanel(colors: SkotiqColors.dark),
          ),
          overrides: [
            darkroomSeamProvider.overrideWithValue(seam),
            liveStackingProvider.overrideWith(
              (ref) => _TestLiveStackNotifier(ref, _twoFilterActiveState()),
            ),
          ],
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('live_darkroom_auto_develop')),
      );
      await tester.pumpAndSettle();

      expect(seam.registryCalls, 1);
      expect(seam.renderCalls, 1);
      expect(seam.renderedLiveKeys, ['L']);
      expect(find.text('background_extract · applied'), findsOneWidget);
      expect(find.text('Auto-adapt as frames stack'), findsOneWidget);
    },
  );

  testWidgets(
    'LiveStackFrameLogPanel and LiveStackTuningPanel expose telemetry and presets',
    (tester) async {
      final active = _twoFilterActiveState();
      await tester.pumpWidget(
        _wrap(
          Row(
            children: [
              SizedBox(
                width: 340,
                height: 700,
                child: LiveStackFrameLogPanel(colors: SkotiqColors.dark),
              ),
              SizedBox(
                width: 340,
                height: 700,
                child: LiveStackTuningPanel(colors: SkotiqColors.dark),
              ),
            ],
          ),
          overrides: [
            liveStackingProvider.overrideWith(
              (ref) => _TestLiveStackNotifier(ref, active),
            ),
          ],
        ),
      );
      await tester.pump();

      expect(find.text('ha_002.fits'), findsOneWidget);
      expect(find.text('Alignment residual too high: 4.10px'), findsOneWidget);
      expect(find.text('l_002.fits'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('live_stack_preset_strictQuality')),
      );
      await tester.pump();
      expect(find.textContaining('1.2 px max residual'), findsOneWidget);
    },
  );

  test(
    'Unfiltered is the accent, and real band names keep their own colors',
    () {
      // Green primary: a red dot cannot be explained as "fell back to primary".
      final colors = SkotiqColors.darkWithAccent(const Color(0xFF3DDC97));
      expect(colors.primary, isNot(FilterColors.red));

      expect(FilterColors.knownColor('Unfiltered'), isNull);
      expect(FilterColors.knownColor('Filtered'), isNull);
      expect(FilterColors.knownColor('Infrared'), isNull);
      expect(liveStackFilterDotColor('Unfiltered', colors), colors.primary);
      expect(
        liveStackFilterDotColor('Unfiltered', colors),
        isNot(FilterColors.forName('Red', colors: colors)),
      );

      const bands = {
        'R': FilterColors.red,
        'Red': FilterColors.red,
        'G': FilterColors.green,
        'Green': FilterColors.green,
        'B': FilterColors.blue,
        'Blue': FilterColors.blue,
        'Ha': FilterColors.hydrogenAlpha,
        'Ha 7nm': FilterColors.hydrogenAlpha,
        'H-alpha': FilterColors.hydrogenAlpha,
        'OIII': FilterColors.oxygen,
        'O3': FilterColors.oxygen,
        'SII': FilterColors.sulfur,
        'S2': FilterColors.sulfur,
        'S-II': FilterColors.sulfur,
        'O-III': FilterColors.oxygen,
        'L': FilterColors.luminance,
        'Lum': FilterColors.luminance,
        'Luminance': FilterColors.luminance,
        'Clear': FilterColors.luminance,
        'NII': FilterColors.nitrogen,
      };
      for (final entry in bands.entries) {
        expect(
          FilterColors.knownColor(entry.key),
          entry.value,
          reason: entry.key,
        );
        final dot = liveStackFilterDotColor(entry.key, colors);
        expect(dot, isNot(colors.primary), reason: entry.key);
      }
      expect(
        liveStackFilterDotColor('Red', colors),
        FilterColors.forName('Red', colors: colors),
      );
      expect(FilterColors.knownColor('L-Pro'), isNull);
      expect(FilterColors.knownColor('L-eXtreme'), isNull);
    },
  );

  test(
    'liveStackFilterDotColor obeys Red Night theme for all optical filters',
    () {
      for (final filter in const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII']) {
        final c = liveStackFilterDotColor(filter, SkotiqColors.redNight);
        expect(
          c.g,
          closeTo(0.0, 0.05),
          reason: '$filter dot must not emit green light in Red Night theme',
        );
        expect(
          c.b,
          closeTo(0.0, 0.05),
          reason: '$filter dot must not emit blue light in Red Night theme',
        );
      }
    },
  );

  test(
    'LiveStackDarkroomNotifier preserves concurrent slider edits, respects disable mid-measure, and clears anchors on stop',
    () async {
      final gate = Completer<void>();
      final seam = _ScriptedDarkroomSeam()..registryGate = gate;
      late _TestLiveStackNotifier stackNotifier;
      final container = ProviderContainer(
        overrides: [
          darkroomSeamProvider.overrideWithValue(seam),
          liveStackingProvider.overrideWith((ref) {
            stackNotifier = _TestLiveStackNotifier(
              ref,
              _twoFilterActiveState(),
            );
            return stackNotifier;
          }),
        ],
      );
      addTearDown(container.dispose);

      final darkroom = container.read(liveStackDarkroomProvider.notifier);

      // Trigger measurement (blocked on `gate`) while user edits denoise concurrently.
      final enableFuture = darkroom.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      await darkroom.updateSettings(
        'L',
        const LiveDarkroomRecipeSettings(
          denoiseEnabled: true,
          denoiseStrength: 0.72,
          stretchMeasured: true,
        ),
      );
      gate.complete();
      await enableFuture;

      final afterMeasure =
          container.read(liveStackDarkroomProvider).settingsFor('L');
      expect(afterMeasure.denoiseEnabled, isTrue);
      expect(afterMeasure.denoiseStrength, closeTo(0.72, 1e-6));
      expect(afterMeasure.stretchBlackPoint, closeTo(980.0, 1e-6));

      // Stopping the stack clears stretchMeasured so the next target re-measures.
      stackNotifier.state = const LiveStackingState(
        status: LiveStackingStatus.idle,
      );
      expect(
        container
            .read(liveStackDarkroomProvider)
            .settingsFor('L')
            .stretchMeasured,
        isFalse,
      );

      // Disabling mid-measurement must not schedule a render once measurement returns.
      final gate2 = Completer<void>();
      seam.registryGate = gate2;
      final rendersBefore = seam.renderCalls;
      stackNotifier.state = _twoFilterActiveState();
      await darkroom.setEnabled(false);
      final enableFuture2 = darkroom.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      await darkroom.setEnabled(false);
      gate2.complete();
      await enableFuture2;
      expect(seam.renderCalls, rendersBefore);
    },
  );
}
