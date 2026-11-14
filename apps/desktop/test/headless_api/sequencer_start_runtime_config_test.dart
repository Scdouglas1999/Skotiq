import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// The headless `load -> start` path must push the operator's runtime config
/// into the native executor before the run begins — the third piece of
/// `SequenceExecutor.start()` this branch never mirrored, after the session row
/// and the run row.
///
/// Measured against the release bundle: `image_grading_enabled` = true and
/// `image_grading_star_count_min` = 100000 persisted AND read back through
/// `GET /api/settings`, and a sim night driven through load -> start accepted
/// twelve of twelve 43-star frames, graded them all `pass` and left `Reject/`
/// empty. The identical thresholds pushed by hand through
/// `POST /api/sequencer/update-default-quality-check` on the SAME live process
/// rejected every frame on the next run. The thresholds worked; nothing sent
/// them. The run configuration now carries them.
class _MockHostBackend extends Mock implements SkotiqBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation) ?? Future<void>.value();
}

class _MockDeviceBackend extends Mock implements DeviceBackend {}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _FixedSettingsNotifier extends AppSettingsNotifier {
  _FixedSettingsNotifier(this._value);
  final AppSettingsState _value;

  @override
  Future<AppSettingsState> build() async => _value;
}

/// Grading switched on with a floor no frame this rig can clear — the exact
/// configuration the appliance ignored.
const _gradingOn = AppSettingsState(
  enableImageGrading: true,
  imageGradingStarCountMin: 100000,
  imageGradingMaxConsecutiveRejects: 9999,
  imageGradingRejectFolderPath: '/captures/rejects',
);

String _wireSequence() => jsonEncode({
  'id': 'seq-grading',
  'name': 'Grading Night',
  'root_node_id': 'target-1',
  'nodes': [
    {
      'id': 'target-1',
      'name': 'Grading Night',
      'enabled': true,
      'children': <String>[],
      'node_type': {
        'type': 'TargetHeader',
        'target_name': 'Grading Night',
        'ra_hours': 5.588,
        'dec_degrees': -5.391,
        'priority': 0,
      },
    },
  ],
});

void main() {
  group('headless load->start seeds the run configuration', () {
    late _MockHostBackend host;
    late _MockDeviceBackend devices;
    late ProviderContainer container;
    late SequencerHandlers handlers;

    ProviderContainer build({AppSettingsState settings = _gradingOn}) {
      final c = createHeadlessTestContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, host),
          ),
          // The SAME object behind both providers: the handler drives the
          // narrow role, the executor drives the wide one, and the appliance
          // they model is one host. Sharing it is also what lets the ordering
          // assertion below span both.
          sequencerBackendProvider.overrideWithValue(host),
          deviceBackendProvider.overrideWithValue(devices),
          appSettingsProvider.overrideWith(
            () => _FixedSettingsNotifier(settings),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      host = _MockHostBackend();
      devices = _MockDeviceBackend();
      when(() => host.eventStream).thenAnswer((_) => const Stream.empty());
      when(
        () => host.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      when(() => devices.getConnectedDevices()).thenAnswer((_) async => []);
    });

    Future<Response> load(ProviderContainer c, String json) =>
        translateHandlerErrors(
          SequencerHandlers(c).handleSequencerLoad(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sequencer/load'),
              body: jsonEncode({'json': json}),
            ),
          ),
        );

    Future<Response> start() => translateHandlerErrors(
      handlers.handleSequencerStart(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/start'),
          body: jsonEncode({}),
        ),
      ),
    );

    test(
      'the operator grading thresholds are pushed before the run starts',
      () async {
        container = build();
        handlers = SequencerHandlers(container);
        await load(container, _wireSequence());
        // No in-editor sequence => the bare headless branch, the one that
        // never seeded anything.
        expect(container.read(currentSequenceProvider), isNull);

        final response = await start();
        expect(response.statusCode, 200);

        // The operator's own numbers, and pushed BEFORE the executor is told to
        // go: thresholds that arrive afterwards are too late for the first
        // frame, which is the frame a start under cloud most needs graded.
        verifyInOrder([
          () => host.sequencerApplyRunConfig(any()),
          () => host.sequencerStart(),
        ]);
        final sent = verify(
          () => host.sequencerApplyRunConfig(captureAny()),
        ).captured;
        final config = jsonDecode(sent.last as String) as Map<String, dynamic>;
        expect(config['default_quality_check'], {
          'hfr_threshold': _gradingOn.imageGradingHfrThresholdPx,
          'hfr_baseline_percent': _gradingOn.imageGradingHfrBaselinePercent,
          'eccentricity_threshold':
              _gradingOn.imageGradingEccentricityThreshold,
          'star_count_min': 100000,
          'max_consecutive_rejects': 9999,
        });
        expect(config['reject_folder_path'], '/captures/rejects');
      },
    );

    test(
      'a runtime-config push that fails refuses the start and says why',
      () async {
        when(
          () => host.sequencerApplyRunConfig(any()),
        ).thenThrow(StateError('executor refused the settings'));
        container = build();
        handlers = SequencerHandlers(container);
        await load(container, _wireSequence());

        final response = await start();

        expect(response.statusCode, 500);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body['error'], 'runtime_config_seed_failed');
        expect(body['message'], contains('image grading'));
        // The run must not have begun. A night that started here would image
        // with the operator's grading, reject folder and cadence replaced by
        // library defaults, and nothing on the run record would say so.
        verifyNever(() => host.sequencerStart());
      },
    );
  });
}
