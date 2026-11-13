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

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart'
    as bridge_event;

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// The capture payload the Rust side ships on every frame event, under its
/// wire keys.
Map<String, dynamic> _captureData() => <String, dynamic>{
  'gain': 139,
  'offset': 21,
  'sensor_temp_c': -9.5,
  'cooler_power_percent': 63.5,
  'mount_ra_hours': 5.5,
  'mount_dec_degrees': -5.25,
  'mount_altitude_deg': 48.5,
  'mount_azimuth_deg': 171.25,
  'pier_side': 'West',
  'focuser_position': 31705,
  'focuser_temperature_c': 4.25,
  'rotator_angle_deg': 212.5,
  'exposure_secs': 120.0,
  'bin_x': 2,
  'bin_y': 2,
  'frame_type': 'Dark',
  'target_id': 'target-header-node-9',
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
    'session restore settings follow saved captures, not the manual preset',
    () async {
      final container = buildContainer(
        loadedSequence: _disagreeingSequence('snapshot-node'),
      );
      container.read(exposureSettingsProvider.notifier).state =
          const ExposureSettings(exposureTime: 3, gain: 250, offset: 50);
      await container
          .read(sessionStateProvider.notifier)
          .startSession(targetName: 'M74');
      final id = container.read(sessionStateProvider).dbSessionId!;
      final executor = container.read(sequenceExecutorProvider);
      executor.handleSequencerEventForTest(
        bridge_event.SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: bridge_event.EventSeverity.info,
          category: bridge_event.EventCategory.sequencer,
          eventType: 'FrameAccepted',
          data: {
            'node_id': 'snapshot-node',
            'frame': 1,
            'save_path': '/captures/dark.fits',
            ..._captureData(),
          },
        ),
      );
      await executor.liveStackingFeedSettledForTest;
      final row = await SessionsDao(db).getSessionById(id);
      final snapshot = EquipmentSnapshot.fromJsonString(
        row!.equipmentSnapshot!,
      );
      expect(snapshot.cameraGain, 139);
      expect(snapshot.cameraOffset, 21);
      expect(snapshot.cameraBinX, 2);
      expect(snapshot.cameraBinY, 2);
      expect(snapshot.exposureTime, 120);
      expect(snapshot.focuserPosition, 31705);
      expect(container.read(exposureSettingsProvider).gain, 250);
    },
  );
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

  /// A frame event without its capture record is not a frame this build
  /// reads: no row is written from a guess.
  test('a frame event without its capture record writes no row', () async {
    final container = buildContainer();
    final executor = container.read(sequenceExecutorProvider);

    executor.handleSequencerEventForTest(
      bridge_event.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: bridge_event.EventSeverity.info,
        category: bridge_event.EventCategory.sequencer,
        eventType: 'FrameAccepted',
        data: const {
          'node_id': 'exposure-node-no-capture',
          'frame': 1,
          'total': 1,
          'accepted_total': 1,
          'rejected_total': 0,
          'save_path': '/captures/m42/L_0001.fits',
        },
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 200));
    final rows = await ImagesDao(
      db,
    ).getImagesByProducingNode(producingNodeId: 'exposure-node-no-capture');
    expect(rows, isEmpty);
  });

  /// The loaded sequence tree must not contribute a single column, not even
  /// when it says something different. The tree is what the sequence ASKED
  /// for; the payload is what the camera DID.
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
}
