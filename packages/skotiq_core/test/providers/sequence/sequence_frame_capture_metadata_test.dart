// A sequencer-captured frame must land in `captured_images` carrying the same
// capture metadata as the FITS file written from the same exposure.
//
// The FITS header is built from the Rust `FrameContext`, which holds the live
// per-frame telemetry. Discarding that struct and building the database row
// from a separate progress event — node id, save path and grading metrics only
// — lands a sequenced sub with NULL gain, offset, sensor temperature, cooler
// power, mount pointing, pier side, focuser position and rotator angle while
// the file written microseconds earlier has all of them: the row and the file
// disagreeing about the same frame.
//
// The FrameContext's own values ride onto the frame event
// (`FrameCaptureMetadata`), so both surfaces are stamped from one struct. This
// suite is the second half of that proof: the Rust test
// `database_row_and_fits_header_agree_for_the_same_frame`
// (bridge/src/sequencer_ops.rs) asserts the FITS header equals the event
// payload; these assert the `captured_images` row equals the event payload.
// Chained, the row equals the header.
//
// Deliberately NOT tested against `resolveFrameAttribution`: that is a second
// source of truth, consulted only as a fallback for a host too old to send the
// payload, which the last test covers.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// The capture payload the Rust side ships on every frame event, spelled with
/// the shared [FrameCaptureKeys] so a renamed key breaks this test rather than
/// silently dropping a column.
Map<String, dynamic> _captureData() => <String, dynamic>{
  FrameCaptureKeys.gain: 139,
  FrameCaptureKeys.offset: 21,
  FrameCaptureKeys.sensorTempC: -9.5,
  FrameCaptureKeys.coolerPowerPercent: 63.5,
  FrameCaptureKeys.mountRaHours: 5.5,
  FrameCaptureKeys.mountDecDegrees: -5.25,
  FrameCaptureKeys.mountAltitudeDeg: 48.5,
  FrameCaptureKeys.mountAzimuthDeg: 171.25,
  FrameCaptureKeys.pierSide: 'West',
  FrameCaptureKeys.focuserPosition: 31705,
  FrameCaptureKeys.focuserTemperatureC: 4.25,
  FrameCaptureKeys.rotatorAngleDeg: 212.5,
  FrameCaptureKeys.exposureSecs: 120.0,
  FrameCaptureKeys.binX: 2,
  FrameCaptureKeys.binY: 2,
  FrameCaptureKeys.frameType: 'Dark',
  FrameCaptureKeys.targetId: 'target-header-node-9',
};

/// A one-node sequence whose ExposureNode config DISAGREES with
/// [_captureData] on every field the tree walk can also supply. Loaded into
/// `currentSequenceProvider`, it makes the two sources distinguishable: any
/// column that comes back with a tree value was written from the wrong source.
Sequence _disagreeingSequence(String nodeId) {
  final node = ExposureNode(
    id: nodeId,
    durationSecs: 300.0,
    count: 10,
    frameType: FrameType.light,
    gain: 0,
    offset: 0,
    binning: BinningMode.four,
  );
  return Sequence.create(
    name: 'disagreeing',
    nodes: {node.id: node},
    rootNodeId: node.id,
  );
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  late MockBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  ProviderContainer buildContainer({Sequence? loadedSequence}) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        if (loadedSequence != null)
          currentSequenceProvider.overrideWith((ref) {
            final notifier = CurrentSequenceNotifier();
            // ignore: invalid_use_of_protected_member
            notifier.state = loadedSequence;
            return notifier;
          }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  /// Poll for the row the fire-and-forget registration writes, then re-read it
  /// as a full drift row: `producing_node_id` is a raw-DDL column the Drift
  /// table does not declare, so the lookup goes through the DAO and the
  /// column assertions go through the typed row.
  Future<DbCapturedImage> awaitRow(String nodeId) async {
    final dao = ImagesDao(db);
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final rows = await dao.getImagesByProducingNode(producingNodeId: nodeId);
      if (rows.isNotEmpty) {
        final row = await dao.getImageById(rows.single.id);
        return row!;
      }
    }
    fail('captured_images row for $nodeId was never written');
  }

  test(
    'accepted frame persists every capture field the FITS header carries',
    () async {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);

      executor.handleSequencerEventForTest(
        bridge_event.SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: bridge_event.EventSeverity.info,
          category: bridge_event.EventCategory.sequencer,
          eventType: 'FrameAccepted',
          data: {
            'node_id': 'exposure-node-capture',
            'frame': 7,
            'total': 10,
            'hfr': 2.35,
            'star_count': 145,
            'accepted_total': 7,
            'rejected_total': 0,
            'save_path': '/captures/m42/D_0007.fits',
            ..._captureData(),
          },
        ),
      );

      final row = await awaitRow('exposure-node-capture');

      // Camera state comes from what the camera REPORTED, not from the node
      // CONFIG (what the sequence asked for), and the temperature/cooler
      // columns are written.
      expect(row.gain, 139, reason: 'FITS GAIN card says 139');
      expect(row.offset, 21, reason: 'FITS OFFSET card says 21');
      expect(
        row.sensorTemp,
        closeTo(-9.5, 1e-9),
        reason: 'FITS CCD-TEMP card says -9.5',
      );
      expect(row.coolerPower, closeTo(63.5, 1e-9));

      // Exposure geometry.
      expect(
        row.exposureDuration,
        closeTo(120.0, 1e-9),
        reason: 'FITS EXPTIME card says 120',
      );
      expect(row.binX, 2, reason: 'FITS XBINNING card says 2');
      expect(row.binY, 2, reason: 'FITS YBINNING card says 2');
      expect(
        row.frameType,
        'dark',
        reason: 'FITS IMAGETYP card says Dark; the images DB stores lowercase',
      );

      // Where the telescope was. Mount RA is HOURS in this column while the
      // numeric FITS RA card is degrees — same pointing, different unit.
      expect(row.mountRa, closeTo(5.5, 1e-9));
      expect(row.mountDec, closeTo(-5.25, 1e-9));
      expect(row.mountAltitude, closeTo(48.5, 1e-9));
      expect(row.mountAzimuth, closeTo(171.25, 1e-9));
      expect(row.pierSide, 'West');

      // Focuser / rotator, which the FITS header has always carried as
      // FOCUSPOS / FOCTEMP / ROTATPOS.
      expect(row.focuserPosition, 31705);
      expect(row.focuserTemp, closeTo(4.25, 1e-9));
      expect(row.rotatorAngle, closeTo(212.5, 1e-9));
    },
  );

  /// A rejected frame is still written to disk with a full FITS header, so its
  /// row has to be stamped from the same struct. Rejects are the frames an
  /// operator most wants the equipment state for.
  test('rejected frame persists the same capture fields', () async {
    final container = buildContainer();
    final executor = container.read(sequenceExecutorProvider);

    executor.handleSequencerEventForTest(
      bridge_event.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: bridge_event.EventSeverity.warning,
        category: bridge_event.EventCategory.sequencer,
        eventType: 'FrameRejected',
        data: {
          'node_id': 'exposure-node-capture-reject',
          'frame': 8,
          'total': 10,
          'reason': 'HFR 6.2 above limit',
          'accepted_total': 7,
          'rejected_total': 1,
          'reject_path': '/captures/m42/Reject/D_0008.fits',
          ..._captureData(),
        },
      ),
    );

    final row = await awaitRow('exposure-node-capture-reject');

    expect(row.isAccepted, isFalse);
    expect(row.gain, 139);
    expect(row.offset, 21);
    expect(row.sensorTemp, closeTo(-9.5, 1e-9));
    expect(row.coolerPower, closeTo(63.5, 1e-9));
    expect(row.mountRa, closeTo(5.5, 1e-9));
    expect(row.mountDec, closeTo(-5.25, 1e-9));
    expect(row.pierSide, 'West');
    expect(row.focuserPosition, 31705);
    expect(row.rotatorAngle, closeTo(212.5, 1e-9));
  });

  /// A paired phone talking to a not-yet-updated appliance receives a frame
  /// event with none of these keys. The columns must stay NULL rather than
  /// pick up a zero that reads as a real measurement.
  test(
    'frame event without a capture payload leaves the columns null',
    () async {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);

      executor.handleSequencerEventForTest(
        bridge_event.SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: bridge_event.EventSeverity.info,
          category: bridge_event.EventCategory.sequencer,
          eventType: 'FrameAccepted',
          data: const {
            'node_id': 'exposure-node-legacy-capture',
            'frame': 1,
            'total': 1,
            'accepted_total': 1,
            'rejected_total': 0,
            'save_path': '/captures/m42/L_0001.fits',
          },
        ),
      );

      final row = await awaitRow('exposure-node-legacy-capture');

      expect(row.sensorTemp, isNull);
      expect(row.coolerPower, isNull);
      expect(row.mountRa, isNull);
      expect(row.mountDec, isNull);
      expect(row.mountAltitude, isNull);
      expect(row.mountAzimuth, isNull);
      expect(row.pierSide, isNull);
      expect(row.focuserPosition, isNull);
      expect(row.focuserTemp, isNull);
      expect(row.rotatorAngle, isNull);
    },
  );

  // The residual second source: `capture.X ?? attribution.X`.
  //
  // `resolveFrameAttribution` walks the loaded sequence tree and can still
  // supply gain, offset, binning, frame type and exposure length. These two
  // tests pin exactly when it may and may not do so, because a fallback nobody
  // has bounded is just the two-sources-of-truth defect wearing a `??`.

  /// With a capture payload present (every FFI frame, and any host new enough
  /// to send one), the tree must not contribute a single column — not even when
  /// it is loaded and says something different. The tree is what the sequence
  /// ASKED for; the payload is what the camera DID.
  test('capture payload beats a loaded sequence that disagrees', () async {
    const nodeId = 'exposure-node-disagree';
    final container = buildContainer(
      loadedSequence: _disagreeingSequence(nodeId),
    );
    final executor = container.read(sequenceExecutorProvider);

    executor.handleSequencerEventForTest(
      bridge_event.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: bridge_event.EventSeverity.info,
        category: bridge_event.EventCategory.sequencer,
        eventType: 'FrameAccepted',
        data: {
          'node_id': nodeId,
          'frame': 1,
          'total': 10,
          'accepted_total': 1,
          'rejected_total': 0,
          'save_path': '/captures/m42/D_0001.fits',
          ..._captureData(),
        },
      ),
    );

    final row = await awaitRow(nodeId);

    expect(
      row.gain,
      139,
      reason: 'the node config says 0; the camera says 139',
    );
    expect(
      row.offset,
      21,
      reason: 'the node config says 0; the camera says 21',
    );
    expect(
      row.binX,
      2,
      reason: 'the node config says 4x4; the camera says 2x2',
    );
    expect(row.binY, 2);
    expect(
      row.exposureDuration,
      closeTo(120.0, 1e-9),
      reason: 'the node config asked for 300s; the shutter ran 120s',
    );
    expect(
      row.frameType,
      'dark',
      reason: 'the node config says light; the frame was captured as a dark',
    );
  });

  /// The ONLY case the fallback serves: a paired client whose appliance predates
  /// the capture payload. Its frame event carries none of the keys, so the tree
  /// walk is all there is — and a NULL gain/offset or a 1x1 binning stamped onto
  /// a 4x4 frame breaks master-dark matching for that whole session.
  ///
  /// Delete the `?? attribution.X` fallbacks and this is what stops working; it
  /// cannot be reproduced on the FFI path, which is why the fallbacks stay.
  test('legacy host with no capture payload falls back to the tree', () async {
    const nodeId = 'exposure-node-legacy-attribution';
    final container = buildContainer(
      loadedSequence: _disagreeingSequence(nodeId),
    );
    final executor = container.read(sequenceExecutorProvider);

    executor.handleSequencerEventForTest(
      bridge_event.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: bridge_event.EventSeverity.info,
        category: bridge_event.EventCategory.sequencer,
        eventType: 'FrameAccepted',
        data: const {
          'node_id': nodeId,
          'frame': 1,
          'total': 10,
          'accepted_total': 1,
          'rejected_total': 0,
          'save_path': '/captures/m42/L_0001.fits',
        },
      ),
    );

    final row = await awaitRow(nodeId);

    expect(row.gain, 0);
    expect(row.offset, 0);
    expect(row.binX, 4);
    expect(row.binY, 4);
    expect(row.exposureDuration, closeTo(300.0, 1e-9));
    expect(row.frameType, 'light');
  });

  test(
    'a captured dark lands in the dark library; a light frame does not',
    () async {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);
      void send(String nodeId, String frameType, String path) {
        executor.handleSequencerEventForTest(
          bridge_event.SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: bridge_event.EventSeverity.info,
            category: bridge_event.EventCategory.sequencer,
            eventType: 'FrameAccepted',
            data: {
              'node_id': nodeId,
              'frame': 1,
              'total': 1,
              'accepted_total': 1,
              'rejected_total': 0,
              'save_path': path,
              ..._captureData(),
              FrameCaptureKeys.frameType: frameType,
            },
          ),
        );
      }

      send('dark-node', 'Dark', '/captures/Dark/Dark_DARK_0001.fits');
      send('light-node', 'Light', '/captures/M42/M42_L_0001.fits');
      await awaitRow('dark-node');
      await awaitRow('light-node');
      List<DarkLibraryEntry> entries = const [];
      for (var i = 0; i < 40 && entries.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        entries = await db.darkLibraryDao.getAllEntries();
      }

      expect(entries, hasLength(1));
      final dark = entries.single;
      expect(dark.filePath, '/captures/Dark/Dark_DARK_0001.fits');
      expect(dark.frameType, 'dark');
      expect(dark.exposureTime, closeTo(120.0, 1e-9));
      expect(dark.gain, 139);
      expect(dark.offset, 21);
      expect(dark.binX, 2);
      expect(dark.temperature, closeTo(-9.5, 1e-9));
      expect(dark.masterDarkPath, isNull);
    },
  );
}
