// A linked client reads every host-owned setting from the imaging host and
// writes edits back to it; only presentation preferences stay on the client.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/models/backend/host_mutation_event.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart' as models;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/host_settings/host_settings_providers.dart';
import 'package:skotiq_core/src/providers/sequence/sequencer_defaults.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import '../../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// The imaging host as the client sees it over the API.
class _Host {
  _Host({
    required this.settings,
    Map<String, String>? store,
    this.servesStore = true,
  }) : store = store ?? {};

  models.AppSettings settings;
  final Map<String, String> store;
  final bool servesStore;
  final Map<String, String> science = {};
  final Map<String, String> smartNight = {};
  int storeFetches = 0;
  final List<Map<String, String>> storeWrites = [];
  final List<models.AppSettings> typedWrites = [];
  final events = StreamController<SkotiqEvent>.broadcast();

  NetworkBackend backend() {
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(() => backend.getSettings()).thenAnswer((_) async => settings);
    when(() => backend.getSettingsStore()).thenAnswer((_) async {
      storeFetches++;
      return servesStore ? Map.of(store) : null;
    });
    when(
      () => backend.updateSettingsStore(any(), remove: any(named: 'remove')),
    ).thenAnswer((invocation) async {
      final rows = invocation.positionalArguments.first as Map<String, String>;
      final remove = invocation.namedArguments[#remove] as List<String>;
      storeWrites.add(Map.of(rows));
      store.addAll(rows);
      remove.forEach(store.remove);
    });
    when(
      () => backend.updateSettingsWithCommandId(
        any(),
        commandId: any(named: 'commandId'),
      ),
    ).thenAnswer((invocation) async {
      final written =
          invocation.positionalArguments.first as models.AppSettings;
      typedWrites.add(written);
      settings = written;
    });
    when(() => backend.getScienceSettings()).thenAnswer((_) async => science);
    when(
      () => backend.getSmartNightSettings(),
    ).thenAnswer((_) async => smartNight);
    when(() => backend.updateScienceSettings(any())).thenAnswer((
      invocation,
    ) async {
      science.addAll(
        invocation.positionalArguments.first as Map<String, String>,
      );
    });
    return backend;
  }

  void announceStoreChange() {
    events.add(
      buildHostMutationEvent(
        entityType: HostMutationEntity.settings,
        action: HostMutationAction.updated,
        extra: const {'namespace': 'store'},
      ),
    );
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  setUpAll(() => registerFallbackValue(const models.AppSettings()));

  late _Host host;
  late ProviderContainer container;

  /// This computer's own database, read without the routing DAO.
  SettingsDao localRows() => SettingsDao(container.read(databaseProvider));

  Future<void> connect(
    _Host h, {
    Map<String, String> localRowsBefore = const {},
  }) async {
    host = h;
    addTearDown(host.events.close);
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, host.backend()),
        ),
      ],
    );
    addTearDown(container.dispose);
    if (localRowsBefore.isNotEmpty) {
      await localRows().setSettings(localRowsBefore);
    }
    await container.read(appSettingsProvider.future);
  }

  test('host-owned rows come from the host, not this computer', () async {
    await connect(
      _Host(
        settings: const models.AppSettings(),
        store: {
          'sequencer_dither_pixels': '9.5',
          'sequencer_autofocus_interval_frames': '12',
        },
      ),
      localRowsBefore: {'sequencer_dither_pixels': '1.0'},
    );

    final dao = container.read(settingsDaoProvider);
    expect(dao, isA<RemoteSettingsDao>());
    expect(await dao.getSetting('sequencer_dither_pixels'), '9.5');

    await container.read(sequencerDefaultsProvider.notifier).ensureLoaded();
    final defaults = container.read(sequencerDefaultsProvider);
    expect(defaults.ditherPixels, 9.5);
    expect(defaults.autofocusIntervalFrames, 12);
  });

  test(
    'an edit writes through to the host and leaves the local row alone',
    () async {
      await connect(
        _Host(
          settings: const models.AppSettings(),
          store: {'sequencer_dither_pixels': '9.5'},
        ),
        localRowsBefore: {'sequencer_dither_pixels': '1.0'},
      );

      final dao = container.read(settingsDaoProvider);
      await dao.setSetting('sequencer_dither_pixels', '4.0');

      expect(host.storeWrites, [
        {'sequencer_dither_pixels': '4.0'},
      ]);
      expect(host.store['sequencer_dither_pixels'], '4.0');
      expect(await dao.getSetting('sequencer_dither_pixels'), '4.0');
      expect(await localRows().getSetting('sequencer_dither_pixels'), '1.0');
    },
  );

  test('presentation preferences stay on this computer', () async {
    await connect(
      _Host(
        settings: const models.AppSettings(),
        store: {'sequencer_density_v1': 'spacious'},
      ),
      localRowsBefore: {'sequencer_density_v1': 'compact'},
    );

    final dao = container.read(settingsDaoProvider);
    expect(await dao.getSetting('sequencer_density_v1'), 'compact');

    await dao.setSetting('sequencer_density_v1', 'comfortable');
    await dao.setSetting('theme', 'light');

    expect(host.storeWrites, isEmpty);
    expect(host.typedWrites, isEmpty);
    expect(await localRows().getSetting('sequencer_density_v1'), 'comfortable');
    expect(await localRows().getSetting('theme'), 'light');
  });

  test(
    'rows of the typed settings model go through the host\'s typed model',
    () async {
      await connect(
        _Host(settings: const models.AppSettings(ditherEveryFrames: 7)),
        localRowsBefore: {'dither_every_frames': '3'},
      );

      final dao = container.read(settingsDaoProvider);
      expect(await dao.getSetting('dither_every_frames'), '7');

      await dao.setSetting('dither_every_frames', '5');

      expect(host.typedWrites.single.ditherEveryFrames, 5);
      expect(host.storeWrites, isEmpty);
      expect(
        container.read(appSettingsProvider).requireValue.ditherEveryFrames,
        5,
      );
      expect(await localRows().getSetting('dither_every_frames'), '3');
    },
  );

  test(
    'a host change reaches the providers that read it; a repeat does not',
    () async {
      await connect(
        _Host(
          settings: const models.AppSettings(),
          store: {'sequencer_dither_pixels': '9.5'},
        ),
      );
      await container.read(sequencerDefaultsProvider.notifier).ensureLoaded();
      expect(container.read(sequencerDefaultsProvider).ditherPixels, 9.5);
      final revisionBefore = container.read(settingsStoreRevisionProvider);

      // Past the refresh interval that the connect-time fetch started.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      host.store['sequencer_dither_pixels'] = '2.5';
      host.announceStoreChange();
      await _settle();

      expect(container.read(settingsStoreRevisionProvider), revisionBefore + 1);
      await container.read(sequencerDefaultsProvider.notifier).ensureLoaded();
      expect(container.read(sequencerDefaultsProvider).ditherPixels, 2.5);

      // The host announces settings activity it did not change: no rebuild.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      host.announceStoreChange();
      await _settle();
      expect(container.read(settingsStoreRevisionProvider), revisionBefore + 1);
    },
  );

  test(
    'settings with no typed-model field read and write the host store',
    () async {
      await connect(
        _Host(
          settings: const models.AppSettings(),
          store: {
            'mount_site_sync_mode': 'never',
            'focuser_backlash_offer_mode': 'never',
          },
        ),
      );

      final state = container.read(appSettingsProvider).requireValue;
      expect(state.mountSiteSyncMode, 'never');
      expect(state.focuserBacklashOfferMode, 'never');

      await container
          .read(appSettingsProvider.notifier)
          .setMountSiteSyncMode('computerToMount');

      expect(host.storeWrites, [
        {'mount_site_sync_mode': 'computerToMount'},
      ]);
      expect(host.typedWrites, isEmpty);
      expect(
        container.read(appSettingsProvider).requireValue.mountSiteSyncMode,
        'computerToMount',
      );
    },
  );

  group('a host too old to serve its key/value store', () {
    test('science and Smart Night rows still mirror', () async {
      final h = _Host(settings: const models.AppSettings(), servesStore: false)
        ..science['science.overlay.opacity'] = '0.8';
      await connect(h, localRowsBefore: {'science.overlay.opacity': '0.35'});

      final dao = container.read(settingsDaoProvider);
      expect(await dao.getSetting('science.overlay.opacity'), '0.8');
      await dao.setSetting('science.overlay.opacity', '0.5');
      expect(host.science['science.overlay.opacity'], '0.5');
      expect(
        await container.read(hostSettingsStoreSupportProvider.future),
        HostSettingsStoreSupport.legacy,
      );
    });

    test('other rows fall back to this computer and are reported', () async {
      await connect(
        _Host(settings: const models.AppSettings(), servesStore: false),
        localRowsBefore: {'sequencer_dither_pixels': '1.0'},
      );

      final dao = container.read(settingsDaoProvider);
      expect(await dao.getSetting('sequencer_dither_pixels'), '1.0');
      expect(
        container.read(hostSettingsStoreProvider)!.unsharedKeys,
        contains('sequencer_dither_pixels'),
      );
    });

    test('a row with no typed-model field refuses the edit', () async {
      await connect(
        _Host(settings: const models.AppSettings(), servesStore: false),
      );

      await expectLater(
        container
            .read(appSettingsProvider.notifier)
            .setMountSiteSyncMode('never'),
        throwsA(isA<HostSettingUnavailableError>()),
      );
    });
  });

  test('refreshes coalesce to one request per interval', () async {
    await connect(_Host(settings: const models.AppSettings()));
    final store = container.read(hostSettingsStoreProvider)!;
    await store.ensureLoaded();
    final before = host.storeFetches;

    for (var i = 0; i < 20; i++) {
      host.announceStoreChange();
    }
    await _settle();

    expect(host.storeFetches - before, lessThanOrEqualTo(1));
  });
}
