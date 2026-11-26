import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/in_memory_database.dart';
import 'runtime_mirror/mirror_link.dart';

class _MockNetwork extends Mock implements NetworkBackend {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a viewer that missed the sweep still has its curve', () {
    final host = mirrorHost();
    const points = <VCurvePoint>[
      VCurvePoint(position: 14000, hfr: 4.5, starCount: 20),
      VCurvePoint(position: 14200, hfr: 2.25, starCount: 31),
      VCurvePoint(position: 14400, hfr: 3.1, starCount: 28),
    ];
    // The best figure is the lowest HFR of the measured pairs.
    final best = points.map((p) => p.hfr).reduce((a, b) => a < b ? a : b);
    const range = FocusRange(min: 13800, max: 14600);
    host.container
        .read(autofocusOverlayProvider.notifier)
        .state = AutofocusOverlayState(
      isRunning: true,
      isVisible: true,
      currentPoint: 3,
      totalPoints: 9,
      vcurvePoints: points,
      currentHfr: 3.1,
      bestHfr: best,
      starCount: 28,
      status: 'Measuring point 3/9',
      focusRange: range,
      starCrops: const [
        StarCrop(
          pixelsBase64: 'aaaa',
          width: 32,
          height: 32,
          hfr: 2.25,
          snr: 18,
        ),
      ],
    );

    final viewer = _viewer();
    const AutofocusRunChannel().apply(
      RuntimeApplyContext(viewer, networkBackend: _link()),
      const AutofocusRunChannel().encode(
        host.container.read(autofocusOverlayProvider),
      ),
    );

    final shown = viewer.read(autofocusOverlayProvider);
    expect(shown.isRunning, isTrue);
    expect(shown.vcurvePoints.map((p) => p.position), [14000, 14200, 14400]);
    expect(shown.vcurvePoints.map((p) => p.hfr), [4.5, 2.25, 3.1]);
    expect(shown.bestHfr, best);
    expect(shown.focusRange?.min, 13800);
    expect(shown.focusRange?.max, 14600);
    expect(shown.isVisible, isTrue);

    final partial = const AutofocusRunChannel().encode(shown)!;
    partial['focusRange'] = {'min': 13800};
    const AutofocusRunChannel().apply(
      RuntimeApplyContext(viewer, networkBackend: _link()),
      partial,
    );
    expect(viewer.read(autofocusOverlayProvider).focusRange, isNull);
    expect(viewer.read(autofocusOverlayProvider).bestHfr, best);

    const AutofocusRunChannel().apply(
      RuntimeApplyContext(viewer, networkBackend: _link()),
      const AutofocusRunChannel().encode(AutofocusOverlayState()),
    );
    final idle = viewer.read(autofocusOverlayProvider);
    expect(idle.isRunning, isFalse);
    expect(idle.isVisible, isFalse);

    const AutofocusRunChannel()
        .apply(RuntimeApplyContext(viewer, networkBackend: _link()), const {
          'running': false,
          'currentPoint': 3,
          'totalPoints': 9,
          'status': 'Autofocus cancelled',
          'outcome': 'cancelled',
          'vcurvePoints': <Object>[],
          'starCrops': <Object>[],
        });
    final cancelled = viewer.read(autofocusOverlayProvider);
    expect(cancelled.isRunning, isFalse);
    expect(cancelled.result, isNull);
    expect(cancelled.hasError, isFalse);
    expect(cancelled.cancelled, isTrue);
  });

  test('panel visibility stays on the window that opened it', () {
    final open = _viewer();
    final closed = _viewer();
    final link = _link();
    const running = {
      'running': true,
      'currentPoint': 2,
      'totalPoints': 9,
      'bestHfr': 2.25,
      'currentHfr': 2.4,
      'starCount': 12,
      'status': 'Measuring point 2/9',
      'vcurvePoints': [
        {'position': 14000, 'hfr': 4.5},
        {'position': 14200, 'hfr': 2.25},
      ],
      'starCrops': <Object>[],
    };
    const AutofocusRunChannel().apply(
      RuntimeApplyContext(open, networkBackend: link),
      running,
    );
    // This window is already in the run and the operator closed the panel.
    // A later snapshot of the same run must leave it closed.
    closed
        .read(autofocusOverlayProvider.notifier)
        .state = const AutofocusOverlayState(
      isRunning: true,
      isVisible: false,
      currentPoint: 2,
      totalPoints: 9,
      status: 'Measuring point 2/9',
    );
    const AutofocusRunChannel().apply(
      RuntimeApplyContext(closed, networkBackend: link),
      running,
    );
    expect(open.read(autofocusOverlayProvider).isVisible, isTrue);
    expect(closed.read(autofocusOverlayProvider).isVisible, isFalse);
  });

  test('hiding the panel does not tell the host the run stopped', () {
    final host = mirrorHost();
    final overlay = host.container.read(autofocusOverlayProvider.notifier)
      ..onAutofocusStarted();
    overlay.dismiss();
    final state = host.container.read(autofocusOverlayProvider);
    expect(state.isVisible, isFalse);
    expect(state.isRunning, isTrue);
    expect(const AutofocusRunChannel().encode(state)!['running'], isTrue);

    overlay.state = state.copyWith(currentPoint: 3, totalPoints: 9);
    const AutofocusRunChannel().apply(
      RuntimeApplyContext(host.container),
      const {
        'running': true,
        'currentPoint': 1,
        'totalPoints': 9,
        'status': 'Measuring point 1/9',
        'vcurvePoints': [
          {'position': 14000, 'hfr': 4.5},
        ],
        'starCrops': <Object>[],
      },
    );
    expect(host.container.read(autofocusOverlayProvider).currentPoint, 3);
  });

  test('a viewer that joins after a finished run does not pop its result', () {
    const result = AutofocusResult(
      bestPosition: 25071,
      bestHfr: 2.12,
      focusData: [],
      method: 'vcurve',
      timestamp: 0,
      curveFitQuality: 0.9,
      backlashApplied: false,
    );
    const settled = AutofocusOverlayState(
      status: 'Complete - HFR: 2.12 at position 25071',
      result: result,
      bestHfr: 2.12,
    );
    final viewer = _viewer();
    void apply(AutofocusOverlayState s) => const AutofocusRunChannel().apply(
      RuntimeApplyContext(viewer, networkBackend: _link()),
      const AutofocusRunChannel().encode(s),
    );

    // Hours-old result in the first snapshot: kept for Tonight, not shown.
    apply(settled);
    var shown = viewer.read(autofocusOverlayProvider);
    expect(shown.result?.bestHfr, 2.12);
    expect(shown.isVisible, isFalse);

    // A run that starts and finishes while the viewer watches does show.
    apply(const AutofocusOverlayState(isRunning: true, status: 'Point 1/9'));
    expect(viewer.read(autofocusOverlayProvider).isVisible, isTrue);
    apply(settled);
    shown = viewer.read(autofocusOverlayProvider);
    expect(shown.isVisible, isTrue);
    expect(shown.isMinimized, isTrue);
  });

  test('a result that lands after an empty first snapshot is shown', () {
    final viewer = _viewer();
    void apply(AutofocusOverlayState s) => const AutofocusRunChannel().apply(
      RuntimeApplyContext(viewer, networkBackend: _link()),
      const AutofocusRunChannel().encode(s),
    );
    apply(const AutofocusOverlayState());
    apply(const AutofocusOverlayState(status: 'Autofocus failed'));
    expect(viewer.read(autofocusOverlayProvider).isVisible, isTrue);
  });
}

ProviderContainer _viewer() {
  final backend = _link();
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) => _FixedBackend(ref, backend)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

_MockNetwork _link() {
  final backend = _MockNetwork();
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  return backend;
}

class _FixedBackend extends BackendNotifier {
  _FixedBackend(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}
