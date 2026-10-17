// The Diagnostics tab showed loading skeletons forever — but only for the
// session the operator had just opened in the Science tab.
//
// psfTilesForSessionProvider / residualVectorsForSessionProvider re-wrapped
// their source with the deprecated `ref.watch(provider.stream)`, which
// forwards only events emitted AFTER the listener attaches and replays
// nothing. sessionPsfTilesProvider is a non-autoDispose StreamProvider over a
// drift query, so once ANY other surface had subscribed and the query had
// emitted its one value, the re-wrapper attached to an already-emitted stream
// and never received anything. opticalTrainDiagnosticsProvider then returned
// AsyncValue.loading() forever.
//
// The subscription ORDER is the whole defect: a test that reads the
// diagnostics provider first passes against the broken code too.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/database/database.dart'
    show PsfFieldTileRow, AstrometryResidualVectorRow;
import 'package:skotiq_core/src/providers/optical_train_diagnostics_provider.dart';
import 'package:skotiq_core/src/providers/science_provider.dart'
    show sessionPsfTilesProvider, sessionResidualVectorsProvider;

const _sessionId = 7;

PsfFieldTileRow _tile(int index) => PsfFieldTileRow(
  id: index,
  capturedImageId: 1,
  sessionId: _sessionId,
  // Tile position is carried by the row/col grid indices; the row has no
  // pixel-space centre.
  tileRow: index ~/ 3,
  tileCol: index % 3,
  starCount: 25,
  medianFwhm: 3.0,
  medianHfr: 1.5,
  medianEccentricity: 0.2,
  roundness: 0.9,
  timestamp: DateTime.utc(2026, 5, 1),
);

void main() {
  late StreamController<List<PsfFieldTileRow>> psfController;
  late StreamController<List<AstrometryResidualVectorRow>> residualController;

  setUp(() {
    psfController = StreamController<List<PsfFieldTileRow>>.broadcast();
    residualController =
        StreamController<List<AstrometryResidualVectorRow>>.broadcast();
  });

  tearDown(() async {
    await psfController.close();
    await residualController.close();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        sessionPsfTilesProvider.overrideWith((ref, id) => psfController.stream),
        sessionResidualVectorsProvider.overrideWith(
          (ref, id) => residualController.stream,
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'diagnostics resolve when the Science tab subscribed to the rows first',
    () async {
      final container = makeContainer();

      // 1. The Science tab subscribes and the query emits its single value.
      final sub = container.listen(
        sessionPsfTilesProvider(_sessionId),
        (_, _) {},
        fireImmediately: true,
      );
      final residualSub = container.listen(
        sessionResidualVectorsProvider(_sessionId),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);
      addTearDown(residualSub.close);

      psfController.add(List<PsfFieldTileRow>.generate(9, _tile));
      residualController.add(const <AstrometryResidualVectorRow>[]);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(sessionPsfTilesProvider(_sessionId)).hasValue,
        isTrue,
        reason: 'precondition: the source has already emitted',
      );

      // 2. Only NOW does the operator open Diagnostics.
      final diagnostics = container.read(
        opticalTrainDiagnosticsProvider(_sessionId),
      );

      expect(
        diagnostics.isLoading,
        isFalse,
        reason: 'the rows are already in hand; a skeleton here is a lie',
      );
      expect(diagnostics.hasValue, isTrue);
    },
  );

  test(
    'the derived row providers forward the source value, not a fresh stream',
    () async {
      final container = makeContainer();

      final sub = container.listen(
        sessionPsfTilesProvider(_sessionId),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);
      psfController.add(List<PsfFieldTileRow>.generate(9, _tile));
      await Future<void>.delayed(Duration.zero);

      final forwarded = container.read(psfTilesForSessionProvider(_sessionId));
      expect(forwarded.hasValue, isTrue);
      expect(forwarded.value, hasLength(9));
    },
  );

  test(
    'diagnostics still resolve when Diagnostics subscribes first (no regression)',
    () async {
      final container = makeContainer();

      final sub = container.listen(
        opticalTrainDiagnosticsProvider(_sessionId),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      psfController.add(List<PsfFieldTileRow>.generate(9, _tile));
      residualController.add(const <AstrometryResidualVectorRow>[]);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(opticalTrainDiagnosticsProvider(_sessionId)).hasValue,
        isTrue,
      );
    },
  );
}
