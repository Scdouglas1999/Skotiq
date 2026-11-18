// After a relaunch on the rig (2026-11-17) the main window came up centered
// and not maximized, with PHD2 in front of part of it. The window now comes
// back with the size, position and maximized state it was left with.
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/window_placement.dart';

void main() {
  const left = Rect.fromLTWH(0, 0, 1920, 1040);
  const right = Rect.fromLTWH(1920, 0, 2560, 1400);

  group('placementOnScreens', () {
    test('a window on a screen goes back where it was', () {
      const saved = WindowPlacement(
        bounds: Rect.fromLTWH(2100, 80, 1600, 900),
        maximized: true,
      );
      expect(placementOnScreens(saved, [left, right]), saved);
    });

    test('a window whose monitor is gone opens at the default place', () {
      const saved = WindowPlacement(
        bounds: Rect.fromLTWH(2100, 80, 1600, 900),
        maximized: false,
      );
      expect(placementOnScreens(saved, [left]), isNull);
      expect(placementOnScreens(saved, const []), isNull);
    });

    test('a window bigger than its screen is cut to it', () {
      const saved = WindowPlacement(
        bounds: Rect.fromLTWH(100, 20, 2400, 1300),
        maximized: false,
      );
      expect(
        placementOnScreens(saved, [left])!.bounds,
        const Rect.fromLTWH(0, 0, 1920, 1040),
      );
    });

    test('a title bar above the top of every screen is not a place', () {
      const saved = WindowPlacement(
        bounds: Rect.fromLTWH(200, -600, 1200, 700),
        maximized: false,
      );
      expect(placementOnScreens(saved, [left]), isNull);
    });
  });

  test('a placement reads back as it was saved', () async {
    final dir = await Directory.systemTemp.createTemp('sk_window_placement_');
    addTearDown(() => dir.delete(recursive: true));
    final store = WindowPlacementStore(File('${dir.path}/window.json'));
    expect(await store.read(), isNull);
    const placement = WindowPlacement(
      bounds: Rect.fromLTWH(40, 60, 1500, 880),
      maximized: true,
    );
    await store.write(placement);
    expect(await store.read(), placement);

    await store.file.writeAsString('{"x": "not a number"}');
    expect(await store.read(), isNull);
  });

  group('WindowPlacementRecorder', () {
    late Directory dir;
    late WindowPlacementStore store;
    var bounds = const Rect.fromLTWH(10, 20, 1600, 900);
    var maximized = false;
    var minimized = false;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sk_window_recorder_');
      store = WindowPlacementStore(File('${dir.path}/window.json'));
      bounds = const Rect.fromLTWH(10, 20, 1600, 900);
      maximized = false;
      minimized = false;
    });
    tearDown(() => dir.delete(recursive: true));

    WindowPlacementRecorder recorder() => WindowPlacementRecorder(
      store: store,
      initial: WindowPlacement(bounds: bounds, maximized: false),
      readBounds: () async => bounds,
      readMaximized: () async => maximized,
      readMinimized: () async => minimized,
    );

    test('a move is saved once the window settles', () async {
      final r = WindowPlacementRecorder(
        store: store,
        initial: WindowPlacement(bounds: bounds, maximized: false),
        readBounds: () async => bounds,
        readMaximized: () async => maximized,
        readMinimized: () async => minimized,
        settle: const Duration(milliseconds: 100),
      );
      bounds = const Rect.fromLTWH(300, 200, 1400, 800);
      r.onWindowMoved();
      r.onWindowResized();
      expect(store.file.existsSync(), isFalse, reason: 'not while it moves');
      for (var i = 0; i < 50 && !store.file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        await store.read(),
        const WindowPlacement(
          bounds: Rect.fromLTWH(300, 200, 1400, 800),
          maximized: false,
        ),
      );
    });

    test('maximized keeps the normal bounds to go back to', () async {
      final r = recorder();
      bounds = const Rect.fromLTWH(300, 200, 1400, 800);
      await r.flush();
      maximized = true;
      bounds = const Rect.fromLTWH(0, 0, 1920, 1040);
      await r.flush();
      expect(
        await store.read(),
        const WindowPlacement(
          bounds: Rect.fromLTWH(300, 200, 1400, 800),
          maximized: true,
        ),
      );
    });

    test('a minimized window keeps the placement it had', () async {
      final r = recorder();
      maximized = true;
      await r.flush();
      minimized = true;
      maximized = false;
      bounds = const Rect.fromLTWH(-32000, -32000, 160, 28);
      await r.flush();
      expect((await store.read())!.maximized, isTrue);
      expect(
        (await store.read())!.bounds,
        const Rect.fromLTWH(10, 20, 1600, 900),
      );
    });
  });
}
