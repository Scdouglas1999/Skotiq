// The one-time DepthLock introduction: when it appears, and that it does not
// come back.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_hint.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'depthlock_test_doubles.dart';

/// A settings DAO that lives in a map, so the hint's persistence can be
/// asserted without a database.
class _RecordingSettingsDao implements SettingsDao {
  _RecordingSettingsDao([Map<String, String>? seed])
      : store = <String, String>{...?seed} {
    _controller.add(store[kDepthLockHintDismissedKey]);
  }

  final Map<String, String> store;
  final StreamController<String?> _controller =
      StreamController<String?>.broadcast();

  @override
  Future<String?> getSetting(String key) async => store[key];

  @override
  Stream<String?> watchSetting(String key) async* {
    yield store[key];
    yield* _controller.stream;
  }

  @override
  Future<void> setSetting(String key, String value) async {
    store[key] = value;
    if (key == kDepthLockHintDismissedKey) _controller.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLiveStacking extends LiveStackingNotifier {
  _FakeLiveStacking(super.ref);
}

CapturedImageData _solvedFrame() => CapturedImageData(
      width: 4144,
      height: 2822,
      displayData: Uint8List(0),
      histogram: const <int>[],
      stats: const ImageStats(),
      capturedAt: DateTime(2026, 9, 12, 22),
      settings:
          const ExposureSettings(exposureTime: 300, gain: 100, offset: 50),
      filePath: '/data/M51/L_0001.fits',
    );

Future<_RecordingSettingsDao> _pumpHint(
  WidgetTester tester, {
  required FakeDepthLockBackend backend,
  CapturedImageData? frame,
  Map<String, String>? seed,
  VoidCallback? onMarkRegion,
}) async {
  final dao = _RecordingSettingsDao(seed);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsDaoProvider.overrideWithValue(dao),
        depthLockBackendProvider.overrideWithValue(backend),
        depthLockEventStreamProvider.overrideWithValue(
          const Stream<SkotiqEvent>.empty(),
        ),
        liveStackingProvider.overrideWith(_FakeLiveStacking.new),
        if (frame != null) currentImageProvider.overrideWith((ref) => frame),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SizedBox(
            width: 700,
            child: DepthLockHint(onMarkRegion: onMarkRegion),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return dao;
}

void main() {
  testWidgets('the hint appears once a markable frame is on screen', (
    tester,
  ) async {
    await _pumpHint(
      tester,
      backend: FakeDepthLockBackend(),
      frame: _solvedFrame(),
      onMarkRegion: () {},
    );

    expect(find.textContaining('Chasing something faint?'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'Mark a region'),
      findsOneWidget,
    );
  });

  testWidgets('no frame, no hint', (tester) async {
    await _pumpHint(tester, backend: FakeDepthLockBackend());
    expect(find.textContaining('Chasing something faint?'), findsNothing);
  });

  testWidgets('a goal that already exists makes the hint pointless', (
    tester,
  ) async {
    await _pumpHint(
      tester,
      backend: FakeDepthLockBackend(
        goals: <DepthLockGoal>[depthLockGoalFixture()],
      ),
      frame: _solvedFrame(),
    );

    expect(find.textContaining('Chasing something faint?'), findsNothing);
  });

  testWidgets('dismissing it records the choice and takes it off screen', (
    tester,
  ) async {
    final dao = await _pumpHint(
      tester,
      backend: FakeDepthLockBackend(),
      frame: _solvedFrame(),
    );

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();

    expect(dao.store[kDepthLockHintDismissedKey], 'true');
    expect(find.textContaining('Chasing something faint?'), findsNothing);
  });

  testWidgets('a dismissal from an earlier night is remembered', (
    tester,
  ) async {
    await _pumpHint(
      tester,
      backend: FakeDepthLockBackend(),
      frame: _solvedFrame(),
      seed: <String, String>{kDepthLockHintDismissedKey: 'true'},
    );

    expect(find.textContaining('Chasing something faint?'), findsNothing);
  });

  testWidgets('taking the offer is also an answer', (tester) async {
    var marked = false;
    final dao = await _pumpHint(
      tester,
      backend: FakeDepthLockBackend(),
      frame: _solvedFrame(),
      onMarkRegion: () => marked = true,
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Mark a region'));
    await tester.pumpAndSettle();

    expect(marked, isTrue);
    expect(dao.store[kDepthLockHintDismissedKey], 'true');
    expect(find.textContaining('Chasing something faint?'), findsNothing);
  });
}
