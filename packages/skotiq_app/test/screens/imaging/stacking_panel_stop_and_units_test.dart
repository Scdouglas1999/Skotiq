// The live-stacking panel: Stop must not destroy the stack, and frame counts
// must not share a unitless list with pixel counts.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Ordered log of the operations the panel performed, so "saved before the
/// stacker was released" is provable and not merely plausible.
final _log = <String>[];

class _RecordingLiveStackingNotifier extends LiveStackingNotifier {
  _RecordingLiveStackingNotifier(super.ref, LiveStackingState initial) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }

  int stopCalls = 0;

  @override
  Future<void> stop() async {
    stopCalls++;
    _log.add('stop');
    // ignore: invalid_use_of_protected_member
    state = LiveStackingState(config: state.config);
  }
}

class _FakeLiveStackingService extends LiveStackingService {
  _FakeLiveStackingService(super.ref);

  final saved = <String>[];
  bool failSave = false;

  @override
  Future<LiveStackingMasterSave> saveMaster({required String filePath}) async {
    // Mirrors the real service: FITS is the master, PNG is the render, and any
    // other extension is refused rather than renaming the operator's file.
    final extension = filePath.contains('.')
        ? filePath.substring(filePath.lastIndexOf('.')).toLowerCase()
        : '';
    const writable = {'', '.fits', '.fit', '.fts', '.png'};
    if (!writable.contains(extension)) {
      _log.add('save-wrong-format');
      throw LiveStackingMasterFormatUnsupported(
        extension,
        reason: 'the live stacker writes a FITS master of the integration or a '
            'PNG of the render, and nothing else',
      );
    }
    if (failSave) {
      _log.add('save-failed');
      throw StateError('destination is not writable');
    }
    saved.add(filePath);
    _log.add('save');
    return extension == '.png'
        ? LiveStackingMasterSave(
            filePath: filePath,
            stackedFrameCount: 32,
            format: LiveStackingMasterFormat.linearMono16,
          )
        : LiveStackingMasterSave(
            filePath: filePath,
            stackedFrameCount: 32,
            format: LiveStackingMasterFormat.fitsMaster,
            totalIntegrationSecs: 3840.0,
            dateObs: '2026-08-14T03:21:09.000',
          );
  }
}

const _stats = LiveStackingStats(
  stackedFrameCount: 32,
  totalFramesAttempted: 32,
  rejectedAlignmentFailures: 0,
  avgMatchedPairs: 39.0,
  avgAlignmentResidual: 0.52,
  totalSigmaRejectedPixels: 7300000,
);

typedef _Harness = ({
  _RecordingLiveStackingNotifier stacker,
  _FakeLiveStackingService service,
});

Future<_Harness> _pumpPanel(
  WidgetTester tester, {
  String? destination,
  bool failSave = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 1600);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  _log.clear();

  late _RecordingLiveStackingNotifier stacker;
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      isRemoteModeProvider.overrideWithValue(false),
      connectedCameraIdProvider.overrideWithValue(null),
      stackingMasterDestinationPickerProvider.overrideWithValue(
        (suggestedName) async {
          _log.add('pick:$suggestedName');
          return destination;
        },
      ),
      liveStackingServiceProvider.overrideWith(
        (ref) => _FakeLiveStackingService(ref)..failSave = failSave,
      ),
      liveStackingProvider.overrideWith((ref) {
        stacker = _RecordingLiveStackingNotifier(
          ref,
          const LiveStackingState(
            status: LiveStackingStatus.running,
            stats: _stats,
            lastFrameSigmaRejectedPixels: 271800,
            lastFrameTotalPixels: 2073600,
          ),
        );
        return stacker;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: StackingPanel(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  await tester.pump();
  return (
    stacker: stacker,
    service:
        container.read(liveStackingServiceProvider) as _FakeLiveStackingService,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Stop does not discard an accumulated stack unprompted',
      (tester) async {
    final harness = await _pumpPanel(tester);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      harness.stacker.stopCalls,
      0,
      reason: '32 stacked frames must not be released without a prompt',
    );
    expect(find.text('Keep this stack?'), findsOneWidget);
  });

  testWidgets('Discard is an explicit choice that then releases the stack',
      (tester) async {
    final harness = await _pumpPanel(tester);

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(harness.stacker.stopCalls, 1);
    expect(harness.service.saved, isEmpty);
  });

  testWidgets('Save master writes the stack out before releasing it',
      (tester) async {
    final harness = await _pumpPanel(tester, destination: '/tmp/master.fits');

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save master'));
    await tester.pumpAndSettle();

    expect(harness.service.saved, ['/tmp/master.fits']);
    expect(harness.stacker.stopCalls, 1);
    final ops = _log.where((e) => !e.startsWith('pick:')).toList();
    expect(ops, ['save', 'stop'],
        reason: 'the master must be on disk before the stacker is released');
    expect(find.textContaining('/tmp/master.fits'), findsOneWidget);
    // Decision 8: the master carries its integration, so the confirmation can
    // state it instead of naming a frame count alone.
    expect(find.textContaining('3840 s integration'), findsOneWidget);
  });

  // The default destination is the data product, not the render: an operator
  // who accepts the suggested name gets a FITS master.
  testWidgets('the suggested destination is a FITS master', (tester) async {
    await _pumpPanel(tester, destination: '/tmp/master.fits');

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save master'));
    await tester.pumpAndSettle();

    final picked = _log.firstWhere((e) => e.startsWith('pick:'));
    expect(picked, endsWith('.fits'));
    expect(picked, contains('32frames'));
  });

  testWidgets('a cancelled destination leaves the stack running',
      (tester) async {
    final harness = await _pumpPanel(tester);

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save master'));
    await tester.pumpAndSettle();

    expect(harness.service.saved, isEmpty);
    expect(harness.stacker.stopCalls, 0,
        reason: 'cancelling the save must not cost the operator the stack');
  });

  testWidgets('a failed save leaves the stack running', (tester) async {
    final harness = await _pumpPanel(
      tester,
      destination: '/nope/master.png',
      failSave: true,
    );

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save master'));
    await tester.pumpAndSettle();

    expect(harness.stacker.stopCalls, 0);
    expect(find.text('Could not save the stacked master'), findsOneWidget);
  });

  // Typing `stack_master.fits` into the save chooser must not produce
  // `stack_master.png` on disk: a silently swapped extension leaves the operator
  // believing they have a FITS master with a header, WCS and integration
  // metadata when they have a picture. A format the stacker cannot write is
  // refused with the reason rather than renamed.
  testWidgets('a format the stacker cannot write is refused, not renamed',
      (tester) async {
    final harness = await _pumpPanel(
      tester,
      destination: '/tmp/ns-audit/stack_master.tif',
    );

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save master'));
    await tester.pumpAndSettle();

    expect(harness.service.saved, isEmpty);
    expect(
      harness.stacker.stopCalls,
      0,
      reason: 'nothing was written, so the stack must survive',
    );
    expect(find.text('That master cannot be written here'), findsOneWidget);
    expect(find.textContaining('.tif'), findsWidgets);
  });

  testWidgets('the Stop prompt names the format it is about to write',
      (tester) async {
    await _pumpPanel(tester);

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();

    expect(find.textContaining('FITS master'), findsOneWidget);
  });

  testWidgets('Statistics rows carry units for frames and for pixels',
      (tester) async {
    await _pumpPanel(tester);

    expect(find.text('32 frames'), findsWidgets);
    expect(find.text('7.3M px'), findsOneWidget);
    expect(find.text('271.8K px'), findsOneWidget);
    expect(find.text('PIXELS REJECTED BY SIGMA CLIPPING'), findsOneWidget);
  });
}
