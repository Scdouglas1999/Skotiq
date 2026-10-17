// What the imaging screen can offer DepthLock, and what it says when it
// cannot — including while a live stack is running, where the frame that can
// anchor a region is the stack's reference sub rather than the stack.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_selection.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// The real notifier, parked on a chosen state.
///
/// Subclassed rather than replaced because the provider is typed to
/// [LiveStackingNotifier]; nothing in these tests drives a stack, they only
/// ask what the selection makes of one.
class _FakeLiveStacking extends LiveStackingNotifier {
  _FakeLiveStacking(super.ref, LiveStackingState initial) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }
}

CapturedImageData _frame({
  required String path,
  bool isColor = false,
  int width = 4144,
  int height = 2822,
}) =>
    CapturedImageData(
      width: width,
      height: height,
      displayData: Uint8List(0),
      histogram: const <int>[],
      stats: const ImageStats(),
      capturedAt: DateTime(2026, 9, 12, 22),
      settings:
          const ExposureSettings(exposureTime: 300, gain: 100, offset: 50),
      filePath: path,
      isColor: isColor,
    );

ProviderContainer _container({
  CapturedImageData? frame,
  LiveStackingState stack = const LiveStackingState(),
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      liveStackingProvider.overrideWith(
        (ref) => _FakeLiveStacking(ref, stack),
      ),
      if (frame != null) currentImageProvider.overrideWith((ref) => frame),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('with nothing on screen and no stack, it asks for a frame', () {
    final selection = _container().read(depthLockSelectionProvider);
    expect(selection.canSelect, isFalse);
    expect(selection.blocker, contains('No frame is on screen'));
  });

  test('a running stack names the sub to open, never the stack itself', () {
    final selection = _container(
      stack: const LiveStackingState(
        status: LiveStackingStatus.running,
        referenceImagePath: '/data/M51/L_0001.fits',
      ),
    ).read(depthLockSelectionProvider);

    expect(selection.canSelect, isFalse);
    expect(selection.blocker, contains('A live stack is running on L_0001'));
    expect(
      selection.blocker,
      contains('the stack itself is not a calibrated light'),
    );
  });

  test('a colour render cannot anchor a region', () {
    final selection = _container(
      frame: _frame(path: '/data/M51/rgb.fits', isColor: true),
    ).read(depthLockSelectionProvider);

    expect(selection.canSelect, isFalse);
    expect(selection.blocker, contains('monochrome, linear data'));
  });

  test('a preview with no file behind it cannot be re-read', () {
    final selection = _container(
      frame: _frame(path: ''),
    ).read(depthLockSelectionProvider);

    expect(selection.canSelect, isFalse);
    expect(selection.blocker, contains('not a file on disk'));
  });

  test(
    'the stack\'s own reference sub is markable, and says what it is missing',
    () {
      final selection = _container(
        frame: _frame(path: '/data/M51/L_0001.fits'),
        stack: const LiveStackingState(
          status: LiveStackingStatus.running,
          referenceImagePath: '/data/M51/L_0001.fits',
        ),
      ).read(depthLockSelectionProvider);

      // Marking is allowed: the file's own header may carry a TAN solution
      // even when Skotiq has no plate-solve row for it.
      expect(selection.canSelect, isTrue);
      expect(selection.isLiveStackReference, isTrue);
      expect(selection.referencePath, '/data/M51/L_0001.fits');
      expect(
        selection.advisory,
        contains(
          'The live stack\'s reference sub L_0001.fits has no plate solve; '
          'solve it or open a solved sub',
        ),
      );
    },
  );

  test('path comparison survives separator and case differences', () {
    final selection = _container(
      frame: _frame(path: r'C:\Data\M51\L_0001.FITS'),
      stack: const LiveStackingState(
        status: LiveStackingStatus.running,
        referenceImagePath: 'C:/Data/M51/L_0001.fits',
      ),
    ).read(depthLockSelectionProvider);

    expect(selection.isLiveStackReference, isTrue);
  });

  test('a different sub during a stack is treated as itself', () {
    final selection = _container(
      frame: _frame(path: '/data/M51/L_0057.fits'),
      stack: const LiveStackingState(
        status: LiveStackingStatus.running,
        referenceImagePath: '/data/M51/L_0001.fits',
      ),
    ).read(depthLockSelectionProvider);

    // The rectangles would be drawn in THIS sub's pixels, so this sub is the
    // reference — anything else would store a region against a frame it was
    // not drawn on.
    expect(selection.isLiveStackReference, isFalse);
    expect(selection.referencePath, '/data/M51/L_0057.fits');
    expect(selection.advisory, contains('no plate solve on record'));
  });

  test('an idle stack contributes nothing', () {
    final selection = _container(
      stack: const LiveStackingState(
        referenceImagePath: '/data/M51/L_0001.fits',
      ),
    ).read(depthLockSelectionProvider);

    expect(selection.blocker, contains('No frame is on screen'));
  });
}
