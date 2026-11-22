// The main window comes back where the operator left it: its size, position
// and maximized state.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:skotiq_core/utils.dart' show resolveSkotiqDataDirectory;
import 'package:window_manager/window_manager.dart';

/// The main window's last normal (not maximized) bounds, in logical pixels
/// on the desktop, and whether it was maximized.
class WindowPlacement {
  const WindowPlacement({required this.bounds, required this.maximized});

  final Rect bounds;
  final bool maximized;

  WindowPlacement copyWith({Rect? bounds, bool? maximized}) => WindowPlacement(
    bounds: bounds ?? this.bounds,
    maximized: maximized ?? this.maximized,
  );

  Map<String, Object> toJson() => {
    'x': bounds.left,
    'y': bounds.top,
    'width': bounds.width,
    'height': bounds.height,
    'maximized': maximized,
  };

  /// The placement [json] holds, or null when it is not one.
  static WindowPlacement? fromJson(Object? json) {
    if (json is! Map) return null;
    double? number(String key) {
      final value = json[key];
      return value is num && value.isFinite ? value.toDouble() : null;
    }

    final x = number('x');
    final y = number('y');
    final width = number('width');
    final height = number('height');
    final maximized = json['maximized'];
    if (x == null || y == null || width == null || height == null) return null;
    if (width <= 0 || height <= 0 || maximized is! bool) return null;
    return WindowPlacement(
      bounds: Rect.fromLTWH(x, y, width, height),
      maximized: maximized,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WindowPlacement &&
      other.bounds == bounds &&
      other.maximized == maximized;

  @override
  int get hashCode => Object.hash(bounds, maximized);

  @override
  String toString() => 'WindowPlacement($bounds, maximized: $maximized)';
}

/// How much of the window's top edge (where its title bar is) must be on a
/// screen for the window to be put back there: enough to grab and move it.
const Size kPlacementGrabArea = Size(120, 40);

/// [saved] fitted to the screens now attached ([screens], each screen's
/// visible area): kept where it was when its title bar is on one of them,
/// with its size cut to that screen; null when no screen shows its title bar
/// (the monitor it was on is gone), so the window opens at its default
/// place instead of off screen.
WindowPlacement? placementOnScreens(WindowPlacement saved, List<Rect> screens) {
  final bounds = saved.bounds;
  final titleBar = Rect.fromLTWH(
    bounds.left,
    bounds.top,
    bounds.width,
    math.min(kPlacementGrabArea.height, bounds.height),
  );
  for (final screen in screens) {
    final visible = titleBar.intersect(screen);
    if (visible.width < math.min(kPlacementGrabArea.width, bounds.width) ||
        visible.height < math.min(kPlacementGrabArea.height, bounds.height)) {
      continue;
    }
    final width = math.min(bounds.width, screen.width);
    final height = math.min(bounds.height, screen.height);
    final left = bounds.left.clamp(screen.left, screen.right - width);
    final top = bounds.top.clamp(screen.top, screen.bottom - height);
    return saved.copyWith(
      bounds: Rect.fromLTWH(left.toDouble(), top.toDouble(), width, height),
    );
  }
  return null;
}

/// The placement kept in `window_placement.json` in the app's data
/// directory. Per machine: a window's place on this desktop means nothing on
/// another one, so it is not a setting a linked client shares.
class WindowPlacementStore {
  WindowPlacementStore(this.file);

  final File file;

  static Future<WindowPlacementStore> open() async {
    final dir = await resolveSkotiqDataDirectory();
    return WindowPlacementStore(File('${dir.path}/window_placement.json'));
  }

  /// The saved placement, or null when none was saved or the file cannot be
  /// read (the window then opens at its default place).
  Future<WindowPlacement?> read() async {
    try {
      if (!await file.exists()) return null;
      return WindowPlacement.fromJson(jsonDecode(await file.readAsString()));
    } on Object {
      return null;
    }
  }

  Future<void> write(WindowPlacement placement) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(placement.toJson()), flush: true);
    await temp.rename(file.path);
  }
}

/// Follows the window and saves its placement a moment after it settles.
/// A maximized or minimized window keeps the normal bounds it had, so
/// un-maximizing after a relaunch goes back to them.
class WindowPlacementRecorder with WindowListener {
  WindowPlacementRecorder({
    required this.store,
    required WindowPlacement initial,
    required Future<Rect> Function() readBounds,
    required Future<bool> Function() readMaximized,
    required Future<bool> Function() readMinimized,
    this.settle = const Duration(milliseconds: 500),
    void Function(Object error)? onError,
  }) : _placement = initial,
       _readBounds = readBounds,
       _readMaximized = readMaximized,
       _readMinimized = readMinimized,
       _onError = onError;

  /// A recorder for the real window.
  factory WindowPlacementRecorder.forWindow({
    required WindowPlacementStore store,
    required WindowPlacement initial,
    void Function(Object error)? onError,
  }) => WindowPlacementRecorder(
    store: store,
    initial: initial,
    readBounds: windowManager.getBounds,
    readMaximized: windowManager.isMaximized,
    readMinimized: windowManager.isMinimized,
    onError: onError,
  );

  final WindowPlacementStore store;
  final Duration settle;
  final Future<Rect> Function() _readBounds;
  final Future<bool> Function() _readMaximized;
  final Future<bool> Function() _readMinimized;
  final void Function(Object error)? _onError;

  WindowPlacement _placement;
  WindowPlacement? _written;
  Timer? _timer;

  WindowPlacement get placement => _placement;

  Future<void> _capture() async {
    try {
      final maximized = await _readMaximized();
      if (await _readMinimized()) return;
      _placement = maximized
          ? _placement.copyWith(maximized: true)
          : WindowPlacement(bounds: await _readBounds(), maximized: false);
    } on Object catch (e) {
      _onError?.call(e);
    }
  }

  void _changed() {
    _timer?.cancel();
    _timer = Timer(settle, () => unawaited(flush()));
  }

  /// Read the window now and save its placement when it changed.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await _capture();
    if (_placement == _written) return;
    try {
      await store.write(_placement);
      _written = _placement;
    } on Object catch (e) {
      _onError?.call(e);
    }
  }

  @override
  void onWindowMoved() => _changed();

  @override
  void onWindowResized() => _changed();

  @override
  void onWindowMaximize() => _changed();

  @override
  void onWindowUnmaximize() => _changed();

  @override
  void onWindowRestore() => _changed();
}

/// The visible area of every attached screen, or none when they cannot be
/// read.
Future<List<Rect>> attachedScreens() async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    return [
      for (final display in displays)
        (display.visiblePosition ?? Offset.zero) &
            (display.visibleSize ?? display.size),
    ];
  } on Object {
    return const [];
  }
}
