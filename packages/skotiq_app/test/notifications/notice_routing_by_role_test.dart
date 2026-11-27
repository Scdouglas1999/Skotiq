// Which notices one happening raises, per app role and per notification
// setting: the in-app notices (toasts) and the phone pushes the host queues.
//
// Each cell runs the notice producers the role starts (taken from the
// always-on table, so a role that stops running one shows here) against a
// real router, error bridge and device service, fed the happening as the host
// publishes it. The phone's own alerts and how they meet the host's push are
// pinned in apps/mobile/test/services/phone_alert_identity_test.dart.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/services/run_dashboard_providers.dart';
import 'package:skotiq_app/startup/always_on_services.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/bridge_events.dart' as sk;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

enum _Role {
  hostGui(AppRole.hostGui, linked: false),
  hostDaemon(AppRole.hostDaemon, linked: false),
  linkedDesktop(AppRole.linkedClient, linked: true),
  linkedPhone(AppRole.mobile, linked: true);

  const _Role(this.appRole, {required this.linked});
  final AppRole appRole;
  final bool linked;
}

enum _Setting { defaults, rowOff, routingOff }

/// The producers of operator notices among the always-on services.
final List<ProviderListenable<Object?>> _noticeProducers = [
  notificationRouterProvider,
  pushNotificationServiceProvider,
  errorNotificationBridgeProvider,
  deviceServiceProvider,
  runCriticalAlertsProvider,
  runCriticalAlertPushProvider,
];

class _Happening {
  const _Happening(
    this.category,
    this.events, {
    this.waitForStopPush = false,
    this.label,
  });

  /// The routing row the row-off setting switches off; null for a happening
  /// no row tells, where row-off is the defaults.
  final NotificationCategory? category;
  final List<SkotiqEvent> Function(int cell) events;

  /// The table's name for a happening that is not one category's own.
  final String? label;

  String get name => label ?? category!.name;

  /// A stop's phone push waits out the authorship grace.
  final bool waitForStopPush;
}

SkotiqEvent _wire(
  sk.EventCategory category,
  sk.EventPayload payload,
  sk.EventSeverity severity,
) {
  final wire = wireEventFromTyped(
    sk.SkotiqEvent(
      eventId: BigInt.zero,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: severity,
      category: category,
      payload: payload,
    ),
  );
  return SkotiqEvent.fromWireJson(
    jsonDecode(jsonEncode(wire.toJson())) as Map<String, dynamic>,
  );
}

SkotiqEvent _seq(
  sk.SequencerEvent event, [
  sk.EventSeverity severity = sk.EventSeverity.info,
]) =>
    _wire(
        sk.EventCategory.sequencer, sk.EventPayload.sequencer(event), severity);

sk.SequencerEvent _recovery(String kind) {
  const started = '2026-11-26T02:00:00Z';
  return switch (kind) {
    'started' => const sk.SequencerEvent.recoveryStarted(
        startedAtIso: started,
        causeKind: 'guiding_lost',
        attemptCount: 1,
        maxAttempts: 3,
        retryIntervalSecs: 30,
        maxDurationSecs: 600,
        phase: 'Recovering',
      ),
    'completed' => const sk.SequencerEvent.recoveryCompleted(
        startedAtIso: started,
        causeKind: 'guiding_lost',
        attemptCount: 1,
        maxAttempts: 3,
        retryIntervalSecs: 30,
        maxDurationSecs: 600,
        phase: 'Recovered',
      ),
    _ => const sk.SequencerEvent.recoveryGaveUp(
        startedAtIso: started,
        causeKind: 'guiding_lost',
        attemptCount: 3,
        maxAttempts: 3,
        retryIntervalSecs: 30,
        maxDurationSecs: 600,
        phase: 'GaveUp',
        abortedByUser: false,
      ),
  };
}

SkotiqEvent _autofocus(String status, {bool inRun = false}) => _wire(
      sk.EventCategory.equipment,
      sk.EventPayload.equipment(
        sk.EquipmentEvent.propertyChanged(
          deviceType: 'focuser',
          deviceId: 'sim_focuser',
          property: 'AutofocusFinished',
          value: jsonEncode({'status': status, 'in_run': inRun}),
        ),
      ),
      sk.EventSeverity.info,
    );

/// One happening per category the host's events raise. The categories other
/// producers raise from Dart (clouds, transients, the morning draft, custom)
/// have no event of their own.
final List<_Happening> _happenings = [
  _Happening(
    NotificationCategory.sequenceStarted,
    (_) => [_seq(const sk.SequencerEvent.started(sequenceName: 'Night'))],
  ),
  _Happening(
    NotificationCategory.sequenceCompleted,
    (_) => [_seq(const sk.SequencerEvent.completed())],
  ),
  _Happening(
    NotificationCategory.sequenceFailed,
    (cell) => [
      _seq(
        sk.SequencerEvent.failed(error: 'Mount did not answer ($cell)'),
        sk.EventSeverity.error,
      ),
    ],
  ),
  _Happening(
    NotificationCategory.sequenceStopped,
    (_) => [_seq(const sk.SequencerEvent.stopped())],
    waitForStopPush: true,
  ),
  _Happening(
    NotificationCategory.sequencePaused,
    (_) => [_seq(const sk.SequencerEvent.paused())],
  ),
  _Happening(
    NotificationCategory.sequenceResumed,
    (_) => [_seq(const sk.SequencerEvent.resumed())],
  ),
  _Happening(
    NotificationCategory.targetStarted,
    (_) => [_seq(const sk.SequencerEvent.targetChanged(targetName: 'M31'))],
  ),
  _Happening(
    NotificationCategory.targetCompleted,
    (_) => [_seq(const sk.SequencerEvent.targetCompleted(targetName: 'M31'))],
  ),
  _Happening(
    NotificationCategory.meridianFlipPerformed,
    (_) => [
      _seq(
        const sk.SequencerEvent.meridianFlipOutcome(
          outcome: sk.FlipOutcome.success,
          targetName: 'M31',
          newPierSide: 'West',
          durationSecs: 90,
          attempts: 1,
          failedSteps: [],
        ),
      ),
    ],
  ),
  _Happening(
    NotificationCategory.autofocusCompleted,
    (_) => [_autofocus('Success')],
  ),
  _Happening(
    NotificationCategory.autofocusFailed,
    (_) => [_autofocus('Failure')],
  ),
  _Happening(
    NotificationCategory.autofocusContinued,
    (_) => [
      _seq(
        const sk.SequencerEvent.decisionLogged(
          timestampIso: '2026-11-26T02:00:00Z',
          category: 'system_event',
          summary: 'Autofocus did not converge',
          detailsJson: '{}',
          notice: sk.SequencerNotice.autofocusContinued(),
        ),
      ),
    ],
  ),
  _Happening(
    NotificationCategory.frameCaptured,
    (_) => [
      _wire(
        sk.EventCategory.imaging,
        const sk.EventPayload.imaging(
          sk.ImagingEvent.exposureCompleted(hfr: 2.1, starsDetected: 300),
        ),
        sk.EventSeverity.info,
      ),
    ],
  ),
  _Happening(
    NotificationCategory.frameRejected,
    (_) => [
      _seq(
        const sk.SequencerEvent.decisionLogged(
          timestampIso: '2026-11-26T02:00:00Z',
          category: 'system_event',
          summary: 'Three frames rejected',
          detailsJson: '{}',
          notice: sk.SequencerNotice.rejectStreak(
            consecutiveRejects: 3,
            reason: 'HFR over limit',
          ),
        ),
      ),
    ],
  ),
  _Happening(
    NotificationCategory.problemNoticed,
    (cell) => [
      _seq(
        sk.SequencerEvent.error(
          message: 'Dither did not settle ($cell)',
          kind: sk.SequencerErrorKind.stepProblem,
        ),
        sk.EventSeverity.warning,
      ),
    ],
  ),
  _Happening(
    NotificationCategory.exposureFailed,
    (cell) => [
      _wire(
        sk.EventCategory.imaging,
        sk.EventPayload.imaging(
          sk.ImagingEvent.exposureFailed(error: 'Readout timed out ($cell)'),
        ),
        sk.EventSeverity.error,
      ),
    ],
  ),
  _Happening(
    NotificationCategory.recoveryStarted,
    (_) => [_seq(_recovery('started'), sk.EventSeverity.warning)],
  ),
  _Happening(
    NotificationCategory.recoveryRecovered,
    (_) => [_seq(_recovery('completed'))],
  ),
  _Happening(
    NotificationCategory.recoveryGaveUp,
    (_) => [_seq(_recovery('gaveUp'), sk.EventSeverity.critical)],
  ),
  _Happening(
    NotificationCategory.guidingLost,
    (_) => [
      _wire(
        sk.EventCategory.guiding,
        const sk.EventPayload.guiding(sk.GuidingEvent.disconnected()),
        sk.EventSeverity.warning,
      ),
    ],
  ),
  _Happening(
    NotificationCategory.weatherUnsafe,
    (cell) => [
      _wire(
        sk.EventCategory.safety,
        sk.EventPayload.safety(
          sk.SafetyEvent.weatherUnsafe(reason: 'High wind ($cell)'),
        ),
        sk.EventSeverity.error,
      ),
    ],
  ),
  _Happening(
    NotificationCategory.weatherSafeAgain,
    (_) => [
      _wire(
        sk.EventCategory.safety,
        const sk.EventPayload.safety(sk.SafetyEvent.weatherSafe()),
        sk.EventSeverity.info,
      ),
    ],
  ),
  _Happening(
    NotificationCategory.mountFault,
    (cell) => [
      _wire(
        sk.EventCategory.safety,
        sk.EventPayload.safety(
          sk.SafetyEvent.mountMotionFault(
            deviceId: 'sim_mount',
            kind: 'runaway',
            message: 'The mount moved with no command ($cell).',
          ),
        ),
        sk.EventSeverity.critical,
      ),
    ],
  ),
  _Happening(
    NotificationCategory.diskSpaceLow,
    (_) => [
      _wire(
        sk.EventCategory.system,
        const sk.EventPayload.system(
          sk.SystemEvent.diskSpaceLow(availableGb: 1.5),
        ),
        sk.EventSeverity.error,
      ),
    ],
  ),
  _Happening(
    NotificationCategory.equipmentDisconnected,
    (cell) => [
      _wire(
        sk.EventCategory.equipment,
        sk.EventPayload.equipment(
          sk.EquipmentEvent.error(
            deviceType: 'Camera',
            deviceId: 'sim_camera_$cell',
            message: 'Device not responding ($cell)',
          ),
        ),
        sk.EventSeverity.error,
      ),
    ],
  ),
  _Happening(
    NotificationCategory.triggerFired,
    (_) => [
      _seq(
        const sk.SequencerEvent.triggerFired(
          triggerId: 't1',
          triggerName: 'Refocus',
          action: sk.SequencerTriggerAction.pause,
        ),
      ),
    ],
  ),
  _Happening(
    NotificationCategory.equipmentDisconnected,
    (cell) => [
      _wire(
        sk.EventCategory.equipment,
        sk.EventPayload.equipment(
          sk.EquipmentEvent.disconnected(
            deviceType: 'Camera',
            deviceId: 'sim_camera_$cell',
          ),
        ),
        sk.EventSeverity.error,
      ),
    ],
    label: 'equipmentLostNoMessage',
  ),
  _Happening(
    NotificationCategory.equipmentDisconnected,
    (cell) => [
      _wire(
        sk.EventCategory.equipment,
        sk.EventPayload.equipment(
          sk.EquipmentEvent.connecting(
            deviceType: 'Camera',
            deviceId: 'sim_camera_$cell',
            deviceName: 'Sim camera',
          ),
        ),
        sk.EventSeverity.info,
      ),
      _wire(
        sk.EventCategory.equipment,
        sk.EventPayload.equipment(
          sk.EquipmentEvent.error(
            deviceType: 'Camera',
            deviceId: 'sim_camera_$cell',
            message: 'No camera on the bus ($cell)',
          ),
        ),
        sk.EventSeverity.error,
      ),
    ],
    label: 'equipmentConnectFailed',
  ),
  _Happening(
    null,
    (cell) => [
      _wire(
        sk.EventCategory.equipment,
        sk.EventPayload.equipment(
          sk.EquipmentEvent.error(
            deviceType: 'Camera',
            deviceId: 'sim_camera_$cell',
            message: 'Gain was not restored ($cell)',
          ),
        ),
        sk.EventSeverity.warning,
      ),
    ],
    label: 'equipmentWarning',
  ),
  _Happening(
    NotificationCategory.mountMoved,
    (_) => [
      _mount(const sk.EquipmentEvent.mountSlewCompleted(
        deviceId: '',
        ra: 10,
        dec: 41,
      ))
    ],
    label: 'mountSlewIdle',
  ),
  _Happening(
    NotificationCategory.mountMoved,
    (_) => [
      _seq(const sk.SequencerEvent.started(sequenceName: 'Night')),
      _mount(const sk.EquipmentEvent.mountSlewCompleted(
        deviceId: '',
        ra: 10,
        dec: 41,
      )),
    ],
    label: 'mountSlewInRun',
  ),
  _Happening(
    NotificationCategory.mountMoved,
    (_) => [_mount(const sk.EquipmentEvent.mountParkCompleted(deviceId: ''))],
    label: 'mountParked',
  ),
  _Happening(
    NotificationCategory.mountMoved,
    (_) => [_mount(const sk.EquipmentEvent.mountUnparked(deviceId: ''))],
    label: 'mountUnparked',
  ),
];

SkotiqEvent _mount(sk.EquipmentEvent event) => _wire(
      sk.EventCategory.equipment,
      sk.EventPayload.equipment(event),
      sk.EventSeverity.info,
    );

NotificationRoutingMatrix? _storedMatrix(
  _Setting setting,
  NotificationCategory? category,
) =>
    switch (setting) {
      _Setting.defaults => null,
      _Setting.rowOff when category == null => null,
      _Setting.rowOff => NotificationRoutingMatrix.defaults().withRule(
          category!,
          NotificationRoutingMatrix.defaults()
              .ruleFor(category)
              .copyWith(enabled: false),
        ),
      _Setting.routingOff => NotificationRoutingMatrix.defaults().copyWith(
          enabled: false,
        ),
    };

/// What the operator gets from [happening] in [role] under [setting]: each
/// toast as `toast <level> <title>` and each queued phone push as
/// `push <title> [<eventType>]` (the phone keys its notification on the
/// event type), in the order they were raised.
Future<List<String>> _noticesFor(
  _Role role,
  _Happening happening,
  _Setting setting,
  int cell,
) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final matrix = _storedMatrix(setting, happening.category);
  if (matrix != null) {
    await db.settingsDao.setSetting(
      'notification_routing_matrix',
      jsonEncode(matrix.toJson()),
    );
  }
  final events = StreamController<SkotiqEvent>.broadcast();
  final SkotiqBackend backend;
  if (role.linked) {
    final network = _MockNetworkBackend();
    when(() => network.eventStream).thenAnswer((_) => events.stream);
    when(() => network.nativeReconnectedDeviceTypes)
        .thenReturn(DeviceType.values.toSet());
    backend = network;
  } else {
    final local = _MockFfiBackend();
    when(() => local.eventStream).thenAnswer((_) => events.stream);
    when(() => local.nativeReconnectedDeviceTypes)
        .thenReturn(DeviceType.values.toSet());
    backend = local;
  }
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      secretsStoreProvider.overrideWithValue(
        SecretsStore(InMemorySecureKeyValueStore()),
      ),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  final pushes = <String>[];
  final toasts = <String>[];
  final subscriptions = <ProviderSubscription<Object?>>[];
  StreamSubscription<PushNotification>? pushSub;
  try {
    for (final producer in _noticeProducers) {
      final entry = alwaysOnServices.singleWhere(
        (s) => identical(s.provider, producer),
      );
      if (!entry.roles.contains(role.appRole)) continue;
      subscriptions.add(container.listen(producer, (_, __) {}));
    }
    // The stored settings are what the host runs on, once they have loaded.
    // A linked client's settings are the host's, which this test has none of.
    if (!role.linked) {
      await container.read(appSettingsProvider.future);
      await container.read(pushNotificationConfigProvider.future);
      await container
          .read(notificationRoutingMatrixProvider.future)
          .catchError((Object _) => const NotificationRoutingMatrix());
    }
    // A screen that shows none of the happenings, so a notice that keeps
    // quiet where its result is on screen still shows.
    container.read(currentScreenProvider.notifier).state = AppScreen.settings;
    await pumpEventQueue();
    pushSub = container
        .read(pushNotificationServiceProvider)
        .notifications
        .listen((p) => pushes.add('push ${p.title} [${p.eventType}]'));
    container.listen<List<UiNotification>>(uiNotificationProvider, (
      previous,
      next,
    ) {
      final before = previous?.length ?? 0;
      for (final n in next.skip(before)) {
        toasts.add('toast ${n.level.name} ${n.title}');
      }
    });

    for (final event in happening.events(cell)) {
      events.add(event);
    }
    await pumpEventQueue();
    await Future<void>.delayed(
      happening.waitForStopPush
          ? const Duration(milliseconds: 5300)
          : const Duration(milliseconds: 30),
    );
    await pumpEventQueue();
    return [...toasts, ...pushes];
  } finally {
    await pushSub?.cancel();
    for (final s in subscriptions) {
      s.close();
    }
    container.dispose();
    await events.close();
    await db.close();
  }
}

String _key(_Role role, _Happening happening, _Setting setting) =>
    '${role.name} ${happening.name} ${setting.name}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a linked phone runs the same notice producers as a linked desktop', () {
    for (final producer in _noticeProducers) {
      final roles = alwaysOnServices
          .singleWhere((s) => identical(s.provider, producer))
          .roles;
      expect(
        roles.contains(AppRole.mobile),
        roles.contains(AppRole.linkedClient),
        reason: '$producer',
      );
    }
  });

  final actual = <String, List<String>>{};
  var cell = 0;
  for (final role in _Role.values) {
    for (final happening in _happenings) {
      for (final setting in _Setting.values) {
        final key = _key(role, happening, setting);
        final thisCell = cell++;
        test(key, () async {
          final got = await _noticesFor(role, happening, setting, thisCell);
          actual[key] = got;
          if (_printTable) return;
          expect(got, _expected[key] ?? const <String>[], reason: key);
        });
      }
    }
  }

  tearDownAll(() {
    if (!_printTable) return;
    final out = StringBuffer('const _expected = <String, List<String>>{\n');
    for (final entry in actual.entries) {
      if (entry.value.isEmpty) continue;
      out.writeln("  '${entry.key}': [");
      for (final line in entry.value) {
        out.writeln("    '${line.replaceAll("'", r"\'")}',");
      }
      out.writeln('  ],');
    }
    out.writeln('};');
    // ignore: avoid_print
    print(out);
  });
}

/// Set to print the observed table instead of checking it.
const bool _printTable = bool.fromEnvironment('NOTICE_TABLE_PRINT');

/// Cells with no notice are left out.
const _expected = <String, List<String>>{
  'hostGui sequenceStarted defaults': [
    'toast info Sequence started',
  ],
  'hostGui sequenceCompleted defaults': [
    'toast success Sequence complete',
    'push Sequence complete [sequenceCompleted]',
  ],
  'hostGui sequenceFailed defaults': [
    'toast error Sequence failed',
    'push Sequence failed [sequenceFailed]',
  ],
  'hostGui sequenceFailed rowOff': [
    'push Critical · Sequencer [sequenceFailed]',
  ],
  'hostGui sequenceStopped defaults': [
    'toast info Sequence stopped',
    'push Sequence stopped [sequenceStopped]',
  ],
  'hostGui sequencePaused defaults': [
    'toast info Sequence paused',
  ],
  'hostGui sequenceResumed defaults': [
    'toast info Sequence resumed',
  ],
  'hostGui targetCompleted defaults': [
    'toast success Target complete: M31',
    'push Target complete: M31 [targetCompleted]',
  ],
  'hostGui meridianFlipPerformed defaults': [
    'toast info Meridian flip performed',
    'push Meridian flip performed [meridianFlipPerformed]',
  ],
  'hostGui autofocusCompleted defaults': [
    'toast success Autofocus complete',
  ],
  'hostGui autofocusContinued defaults': [
    'toast info Autofocus failed: continuing',
    'push Autofocus failed: continuing [autofocusContinued]',
  ],
  'hostGui frameRejected defaults': [
    'toast warning Frames being rejected',
  ],
  'hostGui problemNoticed defaults': [
    'toast warning Problem noticed: the run continues',
    'push Problem noticed: the run continues [problemNoticed]',
  ],
  'hostGui exposureFailed defaults': [
    'toast error Exposure failed',
    'push Exposure failed [exposureFailed]',
  ],
  'hostGui exposureFailed rowOff': [
    'push Critical · Imaging [exposureFailed]',
  ],
  'hostGui recoveryStarted defaults': [
    'toast warning Recovery started',
  ],
  'hostGui recoveryRecovered defaults': [
    'toast success Recovery succeeded',
  ],
  'hostGui recoveryGaveUp defaults': [
    'toast error Recovery gave up',
    'push Recovery gave up [recoveryGaveUp]',
  ],
  'hostGui recoveryGaveUp rowOff': [
    'push Critical · Sequencer [recoveryGaveUp]',
  ],
  'hostGui guidingLost defaults': [
    'toast error Guiding lost',
    'push Guiding lost [guidingLost]',
  ],
  'hostGui weatherUnsafe defaults': [
    'toast error Weather unsafe',
    'push Weather unsafe [weatherUnsafe]',
  ],
  'hostGui weatherUnsafe rowOff': [
    'push Critical · Safety [weatherUnsafe]',
  ],
  'hostGui weatherSafeAgain defaults': [
    'toast success Weather safe again',
  ],
  'hostGui mountFault defaults': [
    'toast error Mount fault',
    'push Mount fault [mountFault]',
  ],
  'hostGui mountFault rowOff': [
    'push Critical · Safety [mountFault]',
  ],
  'hostGui diskSpaceLow defaults': [
    'toast error Disk space low',
    'push Disk space low [diskSpaceLow]',
  ],
  'hostGui diskSpaceLow rowOff': [
    'push Critical · System [diskSpaceLow]',
  ],
  'hostGui equipmentDisconnected defaults': [
    'toast error Equipment disconnected',
  ],
  'hostGui triggerFired defaults': [
    'toast info Trigger fired',
  ],
  'hostGui equipmentLostNoMessage defaults': [
    'toast error Equipment disconnected',
  ],
  'hostGui equipmentConnectFailed defaults': [
    'toast error Camera Error',
  ],
  'hostGui equipmentWarning defaults': [
    'toast warning Camera Warning',
  ],
  'hostGui equipmentWarning rowOff': [
    'toast warning Camera Warning',
  ],
  'hostGui equipmentWarning routingOff': [
    'toast warning Camera Warning',
  ],
  'hostGui mountSlewIdle defaults': [
    'toast success Mount',
  ],
  'hostGui mountSlewInRun defaults': [
    'toast info Sequence started',
  ],
  'hostGui mountSlewInRun rowOff': [
    'toast info Sequence started',
  ],
  'hostGui mountParked defaults': [
    'toast success Mount',
  ],
  'hostGui mountUnparked defaults': [
    'toast success Mount',
  ],
  'hostDaemon sequenceStarted defaults': [
    'toast info Sequence started',
  ],
  'hostDaemon sequenceCompleted defaults': [
    'toast success Sequence complete',
    'push Sequence complete [sequenceCompleted]',
  ],
  'hostDaemon sequenceFailed defaults': [
    'toast error Sequence failed',
    'push Sequence failed [sequenceFailed]',
  ],
  'hostDaemon sequenceFailed rowOff': [
    'push Critical · Sequencer [sequenceFailed]',
  ],
  'hostDaemon sequenceStopped defaults': [
    'toast info Sequence stopped',
    'push Sequence stopped [sequenceStopped]',
  ],
  'hostDaemon sequencePaused defaults': [
    'toast info Sequence paused',
  ],
  'hostDaemon sequenceResumed defaults': [
    'toast info Sequence resumed',
  ],
  'hostDaemon targetCompleted defaults': [
    'toast success Target complete: M31',
    'push Target complete: M31 [targetCompleted]',
  ],
  'hostDaemon meridianFlipPerformed defaults': [
    'toast info Meridian flip performed',
    'push Meridian flip performed [meridianFlipPerformed]',
  ],
  'hostDaemon autofocusCompleted defaults': [
    'toast success Autofocus complete',
  ],
  'hostDaemon autofocusContinued defaults': [
    'toast info Autofocus failed: continuing',
    'push Autofocus failed: continuing [autofocusContinued]',
  ],
  'hostDaemon frameRejected defaults': [
    'toast warning Frames being rejected',
  ],
  'hostDaemon problemNoticed defaults': [
    'toast warning Problem noticed: the run continues',
    'push Problem noticed: the run continues [problemNoticed]',
  ],
  'hostDaemon exposureFailed defaults': [
    'toast error Exposure failed',
    'push Exposure failed [exposureFailed]',
  ],
  'hostDaemon exposureFailed rowOff': [
    'push Critical · Imaging [exposureFailed]',
  ],
  'hostDaemon recoveryStarted defaults': [
    'toast warning Recovery started',
  ],
  'hostDaemon recoveryRecovered defaults': [
    'toast success Recovery succeeded',
  ],
  'hostDaemon recoveryGaveUp defaults': [
    'toast error Recovery gave up',
    'push Recovery gave up [recoveryGaveUp]',
  ],
  'hostDaemon recoveryGaveUp rowOff': [
    'push Critical · Sequencer [recoveryGaveUp]',
  ],
  'hostDaemon guidingLost defaults': [
    'toast error Guiding lost',
    'push Guiding lost [guidingLost]',
  ],
  'hostDaemon weatherUnsafe defaults': [
    'toast error Weather unsafe',
    'push Weather unsafe [weatherUnsafe]',
  ],
  'hostDaemon weatherUnsafe rowOff': [
    'push Critical · Safety [weatherUnsafe]',
  ],
  'hostDaemon weatherSafeAgain defaults': [
    'toast success Weather safe again',
  ],
  'hostDaemon mountFault defaults': [
    'toast error Mount fault',
    'push Mount fault [mountFault]',
  ],
  'hostDaemon mountFault rowOff': [
    'push Critical · Safety [mountFault]',
  ],
  'hostDaemon diskSpaceLow defaults': [
    'toast error Disk space low',
    'push Disk space low [diskSpaceLow]',
  ],
  'hostDaemon diskSpaceLow rowOff': [
    'push Critical · System [diskSpaceLow]',
  ],
  'hostDaemon equipmentDisconnected defaults': [
    'toast error Equipment disconnected',
  ],
  'hostDaemon triggerFired defaults': [
    'toast info Trigger fired',
  ],
  'hostDaemon equipmentLostNoMessage defaults': [
    'toast error Equipment disconnected',
  ],
  'hostDaemon equipmentConnectFailed defaults': [
    'toast error Camera Error',
  ],
  'hostDaemon mountSlewIdle defaults': [
    'toast success Mount',
  ],
  'hostDaemon mountSlewInRun defaults': [
    'toast info Sequence started',
  ],
  'hostDaemon mountSlewInRun rowOff': [
    'toast info Sequence started',
  ],
  'hostDaemon mountParked defaults': [
    'toast success Mount',
  ],
  'hostDaemon mountUnparked defaults': [
    'toast success Mount',
  ],
  'linkedDesktop sequenceStarted defaults': [
    'toast info Sequence started',
  ],
  'linkedDesktop sequenceStarted rowOff': [
    'toast info Sequence started',
  ],
  'linkedDesktop sequenceStarted routingOff': [
    'toast info Sequence started',
  ],
  'linkedDesktop sequenceCompleted defaults': [
    'toast success Sequence complete',
  ],
  'linkedDesktop sequenceCompleted rowOff': [
    'toast success Sequence complete',
  ],
  'linkedDesktop sequenceCompleted routingOff': [
    'toast success Sequence complete',
  ],
  'linkedDesktop sequenceFailed defaults': [
    'toast error Sequence failed',
  ],
  'linkedDesktop sequenceFailed rowOff': [
    'toast error Sequence failed',
  ],
  'linkedDesktop sequenceFailed routingOff': [
    'toast error Sequence failed',
  ],
  'linkedDesktop sequenceStopped defaults': [
    'toast info Sequence stopped',
  ],
  'linkedDesktop sequenceStopped rowOff': [
    'toast info Sequence stopped',
  ],
  'linkedDesktop sequenceStopped routingOff': [
    'toast info Sequence stopped',
  ],
  'linkedDesktop sequencePaused defaults': [
    'toast info Sequence paused',
  ],
  'linkedDesktop sequencePaused rowOff': [
    'toast info Sequence paused',
  ],
  'linkedDesktop sequencePaused routingOff': [
    'toast info Sequence paused',
  ],
  'linkedDesktop sequenceResumed defaults': [
    'toast info Sequence resumed',
  ],
  'linkedDesktop sequenceResumed rowOff': [
    'toast info Sequence resumed',
  ],
  'linkedDesktop sequenceResumed routingOff': [
    'toast info Sequence resumed',
  ],
  'linkedDesktop targetCompleted defaults': [
    'toast success Target complete: M31',
  ],
  'linkedDesktop targetCompleted rowOff': [
    'toast success Target complete: M31',
  ],
  'linkedDesktop targetCompleted routingOff': [
    'toast success Target complete: M31',
  ],
  'linkedDesktop meridianFlipPerformed defaults': [
    'toast info Meridian flip performed',
  ],
  'linkedDesktop meridianFlipPerformed rowOff': [
    'toast info Meridian flip performed',
  ],
  'linkedDesktop meridianFlipPerformed routingOff': [
    'toast info Meridian flip performed',
  ],
  'linkedDesktop autofocusCompleted defaults': [
    'toast success Autofocus complete',
  ],
  'linkedDesktop autofocusCompleted rowOff': [
    'toast success Autofocus complete',
  ],
  'linkedDesktop autofocusCompleted routingOff': [
    'toast success Autofocus complete',
  ],
  'linkedDesktop autofocusContinued defaults': [
    'toast info Autofocus failed: continuing',
  ],
  'linkedDesktop autofocusContinued rowOff': [
    'toast info Autofocus failed: continuing',
  ],
  'linkedDesktop autofocusContinued routingOff': [
    'toast info Autofocus failed: continuing',
  ],
  'linkedDesktop frameRejected defaults': [
    'toast warning Frames being rejected',
  ],
  'linkedDesktop frameRejected rowOff': [
    'toast warning Frames being rejected',
  ],
  'linkedDesktop frameRejected routingOff': [
    'toast warning Frames being rejected',
  ],
  'linkedDesktop problemNoticed defaults': [
    'toast warning Problem noticed: the run continues',
  ],
  'linkedDesktop problemNoticed rowOff': [
    'toast warning Problem noticed: the run continues',
  ],
  'linkedDesktop problemNoticed routingOff': [
    'toast warning Problem noticed: the run continues',
  ],
  'linkedDesktop exposureFailed defaults': [
    'toast error Exposure failed',
  ],
  'linkedDesktop exposureFailed rowOff': [
    'toast error Exposure failed',
  ],
  'linkedDesktop exposureFailed routingOff': [
    'toast error Exposure failed',
  ],
  'linkedDesktop recoveryStarted defaults': [
    'toast warning Recovery started',
  ],
  'linkedDesktop recoveryStarted rowOff': [
    'toast warning Recovery started',
  ],
  'linkedDesktop recoveryStarted routingOff': [
    'toast warning Recovery started',
  ],
  'linkedDesktop recoveryRecovered defaults': [
    'toast success Recovery succeeded',
  ],
  'linkedDesktop recoveryRecovered rowOff': [
    'toast success Recovery succeeded',
  ],
  'linkedDesktop recoveryRecovered routingOff': [
    'toast success Recovery succeeded',
  ],
  'linkedDesktop recoveryGaveUp defaults': [
    'toast error Recovery gave up',
  ],
  'linkedDesktop recoveryGaveUp rowOff': [
    'toast error Recovery gave up',
  ],
  'linkedDesktop recoveryGaveUp routingOff': [
    'toast error Recovery gave up',
  ],
  'linkedDesktop guidingLost defaults': [
    'toast error Guiding lost',
  ],
  'linkedDesktop guidingLost rowOff': [
    'toast error Guiding lost',
  ],
  'linkedDesktop guidingLost routingOff': [
    'toast error Guiding lost',
  ],
  'linkedDesktop weatherUnsafe defaults': [
    'toast error Weather unsafe',
  ],
  'linkedDesktop weatherUnsafe rowOff': [
    'toast error Weather unsafe',
  ],
  'linkedDesktop weatherUnsafe routingOff': [
    'toast error Weather unsafe',
  ],
  'linkedDesktop weatherSafeAgain defaults': [
    'toast success Weather safe again',
  ],
  'linkedDesktop weatherSafeAgain rowOff': [
    'toast success Weather safe again',
  ],
  'linkedDesktop weatherSafeAgain routingOff': [
    'toast success Weather safe again',
  ],
  'linkedDesktop mountFault defaults': [
    'toast error Mount fault',
  ],
  'linkedDesktop mountFault rowOff': [
    'toast error Mount fault',
  ],
  'linkedDesktop mountFault routingOff': [
    'toast error Mount fault',
  ],
  'linkedDesktop diskSpaceLow defaults': [
    'toast error Disk space low',
  ],
  'linkedDesktop diskSpaceLow rowOff': [
    'toast error Disk space low',
  ],
  'linkedDesktop diskSpaceLow routingOff': [
    'toast error Disk space low',
  ],
  'linkedDesktop equipmentDisconnected defaults': [
    'toast error Equipment disconnected',
  ],
  'linkedDesktop equipmentDisconnected rowOff': [
    'toast error Equipment disconnected',
  ],
  'linkedDesktop equipmentDisconnected routingOff': [
    'toast error Equipment disconnected',
  ],
  'linkedDesktop triggerFired defaults': [
    'toast info Trigger fired',
  ],
  'linkedDesktop triggerFired rowOff': [
    'toast info Trigger fired',
  ],
  'linkedDesktop triggerFired routingOff': [
    'toast info Trigger fired',
  ],
  'linkedDesktop equipmentLostNoMessage defaults': [
    'toast error Equipment disconnected',
  ],
  'linkedDesktop equipmentLostNoMessage rowOff': [
    'toast error Equipment disconnected',
  ],
  'linkedDesktop equipmentLostNoMessage routingOff': [
    'toast error Equipment disconnected',
  ],
  'linkedDesktop equipmentConnectFailed defaults': [
    'toast error Camera Error',
  ],
  'linkedDesktop equipmentConnectFailed rowOff': [
    'toast error Camera Error',
  ],
  'linkedDesktop equipmentConnectFailed routingOff': [
    'toast error Camera Error',
  ],
  'linkedDesktop equipmentWarning defaults': [
    'toast warning Camera Warning',
  ],
  'linkedDesktop equipmentWarning rowOff': [
    'toast warning Camera Warning',
  ],
  'linkedDesktop equipmentWarning routingOff': [
    'toast warning Camera Warning',
  ],
  'linkedDesktop mountSlewIdle defaults': [
    'toast success Mount',
  ],
  'linkedDesktop mountSlewIdle rowOff': [
    'toast success Mount',
  ],
  'linkedDesktop mountSlewIdle routingOff': [
    'toast success Mount',
  ],
  'linkedDesktop mountSlewInRun defaults': [
    'toast info Sequence started',
    'toast success Mount',
  ],
  'linkedDesktop mountSlewInRun rowOff': [
    'toast info Sequence started',
    'toast success Mount',
  ],
  'linkedDesktop mountSlewInRun routingOff': [
    'toast info Sequence started',
    'toast success Mount',
  ],
  'linkedDesktop mountParked defaults': [
    'toast success Mount',
  ],
  'linkedDesktop mountParked rowOff': [
    'toast success Mount',
  ],
  'linkedDesktop mountParked routingOff': [
    'toast success Mount',
  ],
  'linkedDesktop mountUnparked defaults': [
    'toast success Mount',
  ],
  'linkedDesktop mountUnparked rowOff': [
    'toast success Mount',
  ],
  'linkedDesktop mountUnparked routingOff': [
    'toast success Mount',
  ],
  'linkedPhone sequenceStarted defaults': [
    'toast info Sequence started',
  ],
  'linkedPhone sequenceStarted rowOff': [
    'toast info Sequence started',
  ],
  'linkedPhone sequenceStarted routingOff': [
    'toast info Sequence started',
  ],
  'linkedPhone sequenceCompleted defaults': [
    'toast success Sequence complete',
  ],
  'linkedPhone sequenceCompleted rowOff': [
    'toast success Sequence complete',
  ],
  'linkedPhone sequenceCompleted routingOff': [
    'toast success Sequence complete',
  ],
  'linkedPhone sequenceFailed defaults': [
    'toast error Sequence failed',
  ],
  'linkedPhone sequenceFailed rowOff': [
    'toast error Sequence failed',
  ],
  'linkedPhone sequenceFailed routingOff': [
    'toast error Sequence failed',
  ],
  'linkedPhone sequenceStopped defaults': [
    'toast info Sequence stopped',
  ],
  'linkedPhone sequenceStopped rowOff': [
    'toast info Sequence stopped',
  ],
  'linkedPhone sequenceStopped routingOff': [
    'toast info Sequence stopped',
  ],
  'linkedPhone sequencePaused defaults': [
    'toast info Sequence paused',
  ],
  'linkedPhone sequencePaused rowOff': [
    'toast info Sequence paused',
  ],
  'linkedPhone sequencePaused routingOff': [
    'toast info Sequence paused',
  ],
  'linkedPhone sequenceResumed defaults': [
    'toast info Sequence resumed',
  ],
  'linkedPhone sequenceResumed rowOff': [
    'toast info Sequence resumed',
  ],
  'linkedPhone sequenceResumed routingOff': [
    'toast info Sequence resumed',
  ],
  'linkedPhone targetCompleted defaults': [
    'toast success Target complete: M31',
  ],
  'linkedPhone targetCompleted rowOff': [
    'toast success Target complete: M31',
  ],
  'linkedPhone targetCompleted routingOff': [
    'toast success Target complete: M31',
  ],
  'linkedPhone meridianFlipPerformed defaults': [
    'toast info Meridian flip performed',
  ],
  'linkedPhone meridianFlipPerformed rowOff': [
    'toast info Meridian flip performed',
  ],
  'linkedPhone meridianFlipPerformed routingOff': [
    'toast info Meridian flip performed',
  ],
  'linkedPhone autofocusCompleted defaults': [
    'toast success Autofocus complete',
  ],
  'linkedPhone autofocusCompleted rowOff': [
    'toast success Autofocus complete',
  ],
  'linkedPhone autofocusCompleted routingOff': [
    'toast success Autofocus complete',
  ],
  'linkedPhone autofocusContinued defaults': [
    'toast info Autofocus failed: continuing',
  ],
  'linkedPhone autofocusContinued rowOff': [
    'toast info Autofocus failed: continuing',
  ],
  'linkedPhone autofocusContinued routingOff': [
    'toast info Autofocus failed: continuing',
  ],
  'linkedPhone frameRejected defaults': [
    'toast warning Frames being rejected',
  ],
  'linkedPhone frameRejected rowOff': [
    'toast warning Frames being rejected',
  ],
  'linkedPhone frameRejected routingOff': [
    'toast warning Frames being rejected',
  ],
  'linkedPhone problemNoticed defaults': [
    'toast warning Problem noticed: the run continues',
  ],
  'linkedPhone problemNoticed rowOff': [
    'toast warning Problem noticed: the run continues',
  ],
  'linkedPhone problemNoticed routingOff': [
    'toast warning Problem noticed: the run continues',
  ],
  'linkedPhone exposureFailed defaults': [
    'toast error Exposure failed',
  ],
  'linkedPhone exposureFailed rowOff': [
    'toast error Exposure failed',
  ],
  'linkedPhone exposureFailed routingOff': [
    'toast error Exposure failed',
  ],
  'linkedPhone recoveryStarted defaults': [
    'toast warning Recovery started',
  ],
  'linkedPhone recoveryStarted rowOff': [
    'toast warning Recovery started',
  ],
  'linkedPhone recoveryStarted routingOff': [
    'toast warning Recovery started',
  ],
  'linkedPhone recoveryRecovered defaults': [
    'toast success Recovery succeeded',
  ],
  'linkedPhone recoveryRecovered rowOff': [
    'toast success Recovery succeeded',
  ],
  'linkedPhone recoveryRecovered routingOff': [
    'toast success Recovery succeeded',
  ],
  'linkedPhone recoveryGaveUp defaults': [
    'toast error Recovery gave up',
  ],
  'linkedPhone recoveryGaveUp rowOff': [
    'toast error Recovery gave up',
  ],
  'linkedPhone recoveryGaveUp routingOff': [
    'toast error Recovery gave up',
  ],
  'linkedPhone guidingLost defaults': [
    'toast error Guiding lost',
  ],
  'linkedPhone guidingLost rowOff': [
    'toast error Guiding lost',
  ],
  'linkedPhone guidingLost routingOff': [
    'toast error Guiding lost',
  ],
  'linkedPhone weatherUnsafe defaults': [
    'toast error Weather unsafe',
  ],
  'linkedPhone weatherUnsafe rowOff': [
    'toast error Weather unsafe',
  ],
  'linkedPhone weatherUnsafe routingOff': [
    'toast error Weather unsafe',
  ],
  'linkedPhone weatherSafeAgain defaults': [
    'toast success Weather safe again',
  ],
  'linkedPhone weatherSafeAgain rowOff': [
    'toast success Weather safe again',
  ],
  'linkedPhone weatherSafeAgain routingOff': [
    'toast success Weather safe again',
  ],
  'linkedPhone mountFault defaults': [
    'toast error Mount fault',
  ],
  'linkedPhone mountFault rowOff': [
    'toast error Mount fault',
  ],
  'linkedPhone mountFault routingOff': [
    'toast error Mount fault',
  ],
  'linkedPhone diskSpaceLow defaults': [
    'toast error Disk space low',
  ],
  'linkedPhone diskSpaceLow rowOff': [
    'toast error Disk space low',
  ],
  'linkedPhone diskSpaceLow routingOff': [
    'toast error Disk space low',
  ],
  'linkedPhone equipmentDisconnected defaults': [
    'toast error Equipment disconnected',
  ],
  'linkedPhone equipmentDisconnected rowOff': [
    'toast error Equipment disconnected',
  ],
  'linkedPhone equipmentDisconnected routingOff': [
    'toast error Equipment disconnected',
  ],
  'linkedPhone triggerFired defaults': [
    'toast info Trigger fired',
  ],
  'linkedPhone triggerFired rowOff': [
    'toast info Trigger fired',
  ],
  'linkedPhone triggerFired routingOff': [
    'toast info Trigger fired',
  ],
  'linkedPhone equipmentLostNoMessage defaults': [
    'toast error Equipment disconnected',
  ],
  'linkedPhone equipmentLostNoMessage rowOff': [
    'toast error Equipment disconnected',
  ],
  'linkedPhone equipmentLostNoMessage routingOff': [
    'toast error Equipment disconnected',
  ],
  'linkedPhone equipmentConnectFailed defaults': [
    'toast error Camera Error',
  ],
  'linkedPhone equipmentConnectFailed rowOff': [
    'toast error Camera Error',
  ],
  'linkedPhone equipmentConnectFailed routingOff': [
    'toast error Camera Error',
  ],
  'linkedPhone equipmentWarning defaults': [
    'toast warning Camera Warning',
  ],
  'linkedPhone equipmentWarning rowOff': [
    'toast warning Camera Warning',
  ],
  'linkedPhone equipmentWarning routingOff': [
    'toast warning Camera Warning',
  ],
  'linkedPhone mountSlewIdle defaults': [
    'toast success Mount',
  ],
  'linkedPhone mountSlewIdle rowOff': [
    'toast success Mount',
  ],
  'linkedPhone mountSlewIdle routingOff': [
    'toast success Mount',
  ],
  'linkedPhone mountSlewInRun defaults': [
    'toast info Sequence started',
    'toast success Mount',
  ],
  'linkedPhone mountSlewInRun rowOff': [
    'toast info Sequence started',
    'toast success Mount',
  ],
  'linkedPhone mountSlewInRun routingOff': [
    'toast info Sequence started',
    'toast success Mount',
  ],
  'linkedPhone mountParked defaults': [
    'toast success Mount',
  ],
  'linkedPhone mountParked rowOff': [
    'toast success Mount',
  ],
  'linkedPhone mountParked routingOff': [
    'toast success Mount',
  ],
  'linkedPhone mountUnparked defaults': [
    'toast success Mount',
  ],
  'linkedPhone mountUnparked rowOff': [
    'toast success Mount',
  ],
  'linkedPhone mountUnparked routingOff': [
    'toast success Mount',
  ],
};
