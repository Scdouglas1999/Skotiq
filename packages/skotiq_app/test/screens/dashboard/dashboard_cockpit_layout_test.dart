import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout_provider.dart';
import 'package:skotiq_app/screens/dashboard/widgets/dashboard_widget_registry.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The settings key the dashboard layout persists under. Mirrors the private
/// `_dashboardLayoutKey` in dashboard_layout_provider.dart.
const _dashboardLayoutKey = 'dashboard_layout_v1';

/// The cockpit panel ids — the two merged density-pass tiles plus the 14
/// individual panels.
const _cockpitIds = <DashboardWidgetId>[
  DashboardWidgetId.cockpitNowImaging,
  DashboardWidgetId.cockpitFrames,
  DashboardWidgetId.cockpitTargetHeader,
  DashboardWidgetId.cockpitLiveFrame,
  DashboardWidgetId.cockpitExposureProgress,
  DashboardWidgetId.cockpitRecentFrames,
  DashboardWidgetId.cockpitFilterIntegration,
  DashboardWidgetId.cockpitEquipmentTelemetry,
  DashboardWidgetId.cockpitGuiding,
  DashboardWidgetId.cockpitWeatherSafety,
  DashboardWidgetId.cockpitSessionWarnings,
  DashboardWidgetId.cockpitTriggerFeed,
  DashboardWidgetId.cockpitScheduler,
  DashboardWidgetId.cockpitCloudMotion,
  DashboardWidgetId.cockpitAdaptiveConditions,
  DashboardWidgetId.cockpitLightCurve,
  DashboardWidgetId.cockpitQuality,
  DashboardWidgetId.cockpitSessionVitals,
  DashboardWidgetId.cockpitSkyContext,
  DashboardWidgetId.cockpitForensics,
  DashboardWidgetId.cockpitNarrator,
];

/// The cockpit tiles the Observatory Tonight grid replaces (v7). Present in the
/// layout and in the widget picker, off by default.
const _replacedByTonight = <DashboardWidgetId>[
  DashboardWidgetId.cockpitNowImaging,
  DashboardWidgetId.cockpitFrames,
  DashboardWidgetId.cockpitGuiding,
  DashboardWidgetId.cockpitEquipmentTelemetry,
  DashboardWidgetId.cockpitWeatherSafety,
  DashboardWidgetId.cockpitQuality,
  DashboardWidgetId.cockpitTriggerFeed,
  DashboardWidgetId.cockpitLightCurve,
];

/// The four individual cockpit panels superseded by the merged tiles. Present
/// in the layout but disabled by default in v5.
const _supersededIds = <DashboardWidgetId>[
  DashboardWidgetId.cockpitTargetHeader,
  DashboardWidgetId.cockpitLiveFrame,
  DashboardWidgetId.cockpitExposureProgress,
  DashboardWidgetId.cockpitRecentFrames,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DashboardWidgetId storage round-trip', () {
    test('storageKey/fromStorageKey round-trips for every id (incl. cockpit)',
        () {
      // If a new enum value is added without extending both switches, one of
      // these calls throws — this is the guard that keeps saved layouts safe.
      for (final id in DashboardWidgetId.values) {
        final key = id.storageKey;
        expect(DashboardWidgetIdX.fromStorageKey(key), id,
            reason: 'storageKey "$key" must round-trip back to $id.');
      }
    });

    test('each cockpit id has a unique, non-empty storage key', () {
      final keys = <String>{};
      for (final id in _cockpitIds) {
        final key = id.storageKey;
        expect(key, isNotEmpty);
        expect(keys.add(key), isTrue,
            reason: 'Cockpit storage key "$key" must be unique.');
      }
    });

    test('fromStorageKey throws on an unknown id', () {
      expect(
        () => DashboardWidgetIdX.fromStorageKey('definitelyNotAWidget'),
        throwsFormatException,
      );
    });

    test('the Night Narrator id round-trips through the string maps', () {
      const id = DashboardWidgetId.cockpitNarrator;
      expect(id.storageKey, 'cockpitNarrator');
      expect(DashboardWidgetIdX.fromStorageKey('cockpitNarrator'), id);
      expect(DashboardWidgetIdX.fromStorageKey(id.storageKey), id);
      expect(DashboardZoneX.defaultForWidget(id), DashboardZone.secondary);
    });
  });

  group('Night Narrator cockpit tile', () {
    test('is registered self-chromed in the secondary zone', () {
      final def = dashboardWidgetRegistry.firstWhere(
        (d) => d.id == DashboardWidgetId.cockpitNarrator,
        orElse: () => fail('cockpitNarrator must have a registry definition.'),
      );
      expect(def.title, 'Night narrator');
      expect(
          def.subtitle, "Live interpretation of your session's science data");
      expect(def.icon, LucideIcons.sparkles);
      expect(def.defaultZone, DashboardZone.secondary);
      expect(def.selfChromed, isTrue);
    });

    test('ships present-but-disabled in the default layout', () {
      final layout = DashboardLayout.defaultLayout();
      final tile = layout.tiles.firstWhere(
        (t) => t.widgetId == DashboardWidgetId.cockpitNarrator,
        orElse: () => fail('cockpitNarrator must be present in the default.'),
      );
      expect(tile.enabled, isFalse,
          reason: 'Night Narrator ships opt-in (disabled by default).');
      expect(tile.zone, DashboardZone.secondary);
    });
  });

  group('DashboardLayout.defaultLayout (v7 Observatory Tonight grid)', () {
    test('is version 7', () {
      expect(DashboardLayout.currentVersion, 7);
      expect(DashboardLayout.defaultLayout().version, 7);
    });

    test('enables exactly the five Observatory Tonight panels', () {
      final layout = DashboardLayout.defaultLayout();
      final enabledIds =
          layout.tiles.where((t) => t.enabled).map((t) => t.widgetId).toSet();

      // 06 §Tonight: live preview c8, then equipment / guiding / progress /
      // safety at c4. Every cockpit tile they replace, every opt-in extra and
      // every legacy card is off.
      expect(
        enabledIds,
        unorderedEquals(<DashboardWidgetId>{
          DashboardWidgetId.tonightPreview,
          DashboardWidgetId.tonightEquipment,
          DashboardWidgetId.tonightGuiding,
          DashboardWidgetId.tonightProgress,
          DashboardWidgetId.tonightSafety,
        }),
      );
    });

    test('the Tonight panels lead the layout in the mockup\'s reading order',
        () {
      final layout = DashboardLayout.defaultLayout();
      DashboardTileConfig tileFor(DashboardWidgetId id) =>
          layout.tiles.firstWhere((t) => t.widgetId == id);

      expect(tileFor(DashboardWidgetId.tonightPreview).order, 0);
      expect(tileFor(DashboardWidgetId.tonightEquipment).order, 1);
      expect(tileFor(DashboardWidgetId.tonightGuiding).order, 2);
      expect(tileFor(DashboardWidgetId.tonightProgress).order, 3);
      expect(tileFor(DashboardWidgetId.tonightSafety).order, 4);
    });

    test('the live preview is c8 and the rest are c4', () {
      final layout = DashboardLayout.defaultLayout();
      DashboardTileConfig tileFor(DashboardWidgetId id) =>
          layout.tiles.firstWhere((t) => t.widgetId == id);

      expect(tileFor(DashboardWidgetId.tonightPreview).size.columnSpan, 8);
      for (final id in const <DashboardWidgetId>[
        DashboardWidgetId.tonightEquipment,
        DashboardWidgetId.tonightGuiding,
        DashboardWidgetId.tonightProgress,
        DashboardWidgetId.tonightSafety,
      ]) {
        expect(tileFor(id).size.columnSpan, 4, reason: '$id is a c4 panel.');
      }
    });

    test('the new v6 opt-in panels are present but disabled by default', () {
      final layout = DashboardLayout.defaultLayout();
      const optIn = <DashboardWidgetId>[
        DashboardWidgetId.cockpitSessionVitals,
        DashboardWidgetId.cockpitSkyContext,
        DashboardWidgetId.cockpitForensics,
      ];
      for (final id in optIn) {
        final tile = layout.tiles.firstWhere((t) => t.widgetId == id,
            orElse: () => fail('v6 panel $id must be present.'));
        expect(tile.enabled, isFalse,
            reason: 'v6 panel $id ships disabled by default.');
      }
    });

    test('keeps the four superseded panels present but disabled', () {
      final layout = DashboardLayout.defaultLayout();
      for (final id in _supersededIds) {
        final tile = layout.tiles.firstWhere((t) => t.widgetId == id,
            orElse: () => fail('Superseded id $id must remain present.'));
        expect(tile.enabled, isFalse,
            reason: 'Superseded panel $id is disabled in the v5 default.');
      }
    });

    test('keeps every legacy card present but disabled by default', () {
      final layout = DashboardLayout.defaultLayout();
      const legacyIds = <DashboardWidgetId>[
        DashboardWidgetId.livePreview,
        DashboardWidgetId.captureSettings,
        DashboardWidgetId.sequenceStatus,
        DashboardWidgetId.guiding,
        DashboardWidgetId.mountControl,
        DashboardWidgetId.equipmentStatus,
        DashboardWidgetId.weather,
        DashboardWidgetId.focus,
        DashboardWidgetId.alerts,
        DashboardWidgetId.quickActions,
        DashboardWidgetId.quickStats,
        DashboardWidgetId.tonight,
        DashboardWidgetId.storage,
      ];
      for (final id in legacyIds) {
        final tile =
            layout.tiles.firstWhere((t) => t.widgetId == id, orElse: () {
          fail('Legacy id $id must remain present in the default layout.');
        });
        expect(tile.enabled, isFalse,
            reason: 'Legacy card $id must be disabled by default in v4.');
      }
    });

    test('every tile has a unique order', () {
      final layout = DashboardLayout.defaultLayout();
      final orders = layout.tiles.map((t) => t.order).toList();
      expect(orders.toSet().length, orders.length,
          reason: 'Tile orders must be unique.');
    });

    test('the Tonight hero panel uses the large tile size', () {
      final layout = DashboardLayout.defaultLayout();
      final preview = layout.tiles
          .firstWhere((t) => t.widgetId == DashboardWidgetId.tonightPreview);
      expect(preview.size, DashboardTileSize.large);
    });

    test('the cockpit tiles the Tonight grid replaces are off by default', () {
      final layout = DashboardLayout.defaultLayout();
      for (final id in _replacedByTonight) {
        final tile = layout.tiles.firstWhere((t) => t.widgetId == id,
            orElse: () => fail('Replaced id $id must remain present.'));
        expect(tile.enabled, isFalse,
            reason: '$id is superseded by a Tonight panel in v7.');
      }
    });

    test('recent-frames is no longer enabled by default', () {
      final layout = DashboardLayout.defaultLayout();
      final recent = layout.tiles.firstWhere(
          (t) => t.widgetId == DashboardWidgetId.cockpitRecentFrames);
      expect(recent.enabled, isFalse,
          reason:
              'Recent-frames is folded into cockpitFrames and off by default.');
    });
  });

  group('DashboardWidgetDefinition.selfChromed', () {
    final registry = {for (final d in dashboardWidgetRegistry) d.id: d};

    test('every cockpit panel definition is self-chromed', () {
      for (final id in _cockpitIds) {
        final def = registry[id];
        expect(def, isNotNull,
            reason: 'Cockpit id $id must have a registry definition.');
        expect(def!.selfChromed, isTrue,
            reason: 'Cockpit panel $id provides its own chrome.');
      }
    });

    test('legacy card definitions default selfChromed to false', () {
      const legacyIds = <DashboardWidgetId>[
        DashboardWidgetId.livePreview,
        DashboardWidgetId.captureSettings,
        DashboardWidgetId.sequenceStatus,
        DashboardWidgetId.guiding,
        DashboardWidgetId.mountControl,
        DashboardWidgetId.equipmentStatus,
        DashboardWidgetId.weather,
        DashboardWidgetId.focus,
        DashboardWidgetId.alerts,
        DashboardWidgetId.quickActions,
        DashboardWidgetId.quickStats,
        DashboardWidgetId.tonight,
        DashboardWidgetId.storage,
      ];
      for (final id in legacyIds) {
        expect(registry[id]!.selfChromed, isFalse,
            reason: 'Legacy card $id must not claim its own chrome.');
      }
    });

    test('a definition without selfChromed defaults to false', () {
      const def = DashboardWidgetDefinition(
        id: DashboardWidgetId.livePreview,
        title: 't',
        subtitle: 's',
        icon: LucideIcons.image,
        defaultZone: DashboardZone.primary,
        builder: _noopBuilder,
      );
      expect(def.selfChromed, isFalse);
    });
  });

  group('v3/v4/v5/v6 -> v7 migration', () {
    late SkotiqDatabase database;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    /// Persist an older-version layout under the dashboard key, then read
    /// [dashboardLayoutProvider] which must migrate it to v6.
    Future<DashboardLayout> migrate(Map<String, dynamic> stored) async {
      await SettingsDao(database)
          .setSetting(_dashboardLayoutKey, jsonEncode(stored));

      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      return container.read(dashboardLayoutProvider.future);
    }

    test('moves the user onto the Observatory default and bumps to v7',
        () async {
      // A representative v3 layout: the previous shipped default (live preview +
      // capture enabled, quick stats disabled).
      final storedV3 = {
        'version': 3,
        'secondaryZoneWidth': 0.4,
        'tiles': [
          {
            'id': 'livePreview',
            'size': 'large',
            'enabled': true,
            'order': 0,
            'zone': 'primary',
          },
          {
            'id': 'captureSettings',
            'size': 'medium',
            'enabled': true,
            'order': 1,
            'zone': 'primary',
          },
          {
            'id': 'guiding',
            'size': 'medium',
            'enabled': false,
            'order': 2,
            'zone': 'secondary',
          },
        ],
      };

      final migrated = await migrate(storedV3);

      expect(migrated.version, DashboardLayout.currentVersion);

      // The Tonight panels were never in the v3 layout, so they take their
      // default enabled state — the Observatory grid is now live.
      bool enabled(DashboardWidgetId id) =>
          migrated.tiles.any((t) => t.widgetId == id && t.enabled);
      expect(enabled(DashboardWidgetId.tonightPreview), isTrue);
      expect(enabled(DashboardWidgetId.tonightEquipment), isTrue);
      expect(enabled(DashboardWidgetId.tonightGuiding), isTrue);
      expect(enabled(DashboardWidgetId.tonightProgress), isTrue);
      expect(enabled(DashboardWidgetId.tonightSafety), isTrue);
    });

    test('force-disables the cockpit tiles a v6 user had enabled', () async {
      // The v6 dense default, stored. Migrating it must not leave the old
      // panels rendering beside the Tonight panels that say the same things.
      final storedV6 = {
        'version': 6,
        'secondaryZoneWidth': 0.4,
        'tiles': [
          for (final key in <String>[
            'cockpitNowImaging',
            'cockpitFrames',
            'cockpitGuiding',
            'cockpitEquipmentTelemetry',
            'cockpitWeatherSafety',
            'cockpitQuality',
            'cockpitTriggerFeed',
            'cockpitLightCurve',
          ])
            {
              'id': key,
              'size': 'medium',
              'enabled': true,
              'order': 0,
              'zone': 'primary',
            },
        ],
      };

      final migrated = await migrate(storedV6);

      expect(migrated.version, DashboardLayout.currentVersion);
      for (final id in _replacedByTonight) {
        expect(
          migrated.tiles.firstWhere((t) => t.widgetId == id).enabled,
          isFalse,
          reason: '$id must be force-disabled by the v7 migration.',
        );
      }
      expect(
        migrated.tiles
            .firstWhere((t) => t.widgetId == DashboardWidgetId.tonightPreview)
            .enabled,
        isTrue,
      );
    });

    test(
        'force-disables the four superseded panels even when a v4 user had '
        'them enabled', () async {
      // A v4 layout where all four superseded cockpit panels were enabled.
      // The migration must turn them OFF so the merged tiles don't double up.
      final storedV4 = {
        'version': 4,
        'secondaryZoneWidth': 0.4,
        'tiles': [
          {
            'id': 'cockpitTargetHeader',
            'size': 'large',
            'enabled': true,
            'order': 0,
            'zone': 'primary',
          },
          {
            'id': 'cockpitLiveFrame',
            'size': 'large',
            'enabled': true,
            'order': 1,
            'zone': 'primary',
          },
          {
            'id': 'cockpitExposureProgress',
            'size': 'medium',
            'enabled': true,
            'order': 2,
            'zone': 'primary',
          },
          {
            'id': 'cockpitRecentFrames',
            'size': 'large',
            'enabled': true,
            'order': 3,
            'zone': 'primary',
          },
        ],
      };

      final migrated = await migrate(storedV4);

      expect(migrated.version, DashboardLayout.currentVersion);

      DashboardTileConfig tileFor(DashboardWidgetId id) =>
          migrated.tiles.firstWhere((t) => t.widgetId == id);
      for (final id in _supersededIds) {
        expect(tileFor(id).enabled, isFalse,
            reason: 'Superseded panel $id must be force-disabled in v5.');
      }

      // And the Tonight panels come in enabled from the defaults.
      expect(tileFor(DashboardWidgetId.tonightPreview).enabled, isTrue);
      expect(tileFor(DashboardWidgetId.tonightEquipment).enabled, isTrue);
    });

    test('preserves the user enabled flag where ids overlap the default',
        () async {
      // User had storage explicitly OFF and tonight explicitly ON in v3. The
      // default has both OFF in v5; the migration must keep the user's choices.
      final storedV3 = {
        'version': 3,
        'secondaryZoneWidth': 0.4,
        'tiles': [
          {
            'id': 'storage',
            'size': 'small',
            'enabled': false,
            'order': 0,
            'zone': 'tertiary',
          },
          {
            'id': 'tonight',
            'size': 'small',
            'enabled': true,
            'order': 1,
            'zone': 'tertiary',
          },
        ],
      };

      final migrated = await migrate(storedV3);

      DashboardTileConfig tileFor(DashboardWidgetId id) =>
          migrated.tiles.firstWhere((t) => t.widgetId == id);

      expect(tileFor(DashboardWidgetId.storage).enabled, isFalse,
          reason: 'User had storage OFF; migration must keep it OFF.');
      expect(tileFor(DashboardWidgetId.tonight).enabled, isTrue,
          reason: 'User had tonight ON; migration must keep it ON.');
    });

    test('force-disables quick stats even if the user had it on', () async {
      final storedV3 = {
        'version': 3,
        'secondaryZoneWidth': 0.4,
        'tiles': [
          {
            'id': 'quickStats',
            'size': 'small',
            'enabled': true,
            'order': 0,
            'zone': 'tertiary',
          },
        ],
      };

      final migrated = await migrate(storedV3);

      final quickStats = migrated.tiles
          .firstWhere((t) => t.widgetId == DashboardWidgetId.quickStats);
      expect(quickStats.enabled, isFalse,
          reason: 'Quick Stats is force-disabled during migration.');
    });
  });
}

Widget _noopBuilder(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const SizedBox.shrink();
}
