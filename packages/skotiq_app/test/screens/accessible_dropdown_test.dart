import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/accessible_dropdown.dart';
import 'package:skotiq_app/screens/sequencer/widgets/secondary_rig_card.dart';
import 'package:skotiq_app/screens/settings/widgets/element_refresh_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

/// The A11Y-STATE contract for the screen dropdowns.
///
/// Material's dropdown publishes `button: true` on every menu entry and never
/// an enabled state; AT-SPI reads an absent enabled flag as "disabled", so a
/// live Frame Type / Filter / Schedule menu announced every one of its entries
/// as unusable, and none of them as the one in force. `SkotiqDropdown`
/// fixed that for the shared component; these pins hold the same contract for
/// the 42 raw `DropdownButton` call sites under `lib/screens/`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) => MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: Center(child: child)),
      );

  /// Every node that can be activated must declare a role and its enabled
  /// state; every node that declares a role must be operable.
  void assertOperableNodes(WidgetTester tester, {required String what}) {
    final root =
        tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
    final failures = <String>[];

    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      final isRole = data.hasFlag(SemanticsFlag.isButton) ||
          data.hasFlag(SemanticsFlag.hasCheckedState) ||
          data.hasFlag(SemanticsFlag.hasToggledState) ||
          data.hasFlag(SemanticsFlag.isSlider) ||
          data.hasFlag(SemanticsFlag.isTextField);
      final tappable = data.hasAction(SemanticsAction.tap);
      if (isRole || tappable) {
        if (!data.hasFlag(SemanticsFlag.hasEnabledState)) {
          failures.add('"${data.label}" has no enabled state');
        }
        if (tappable && !isRole) {
          failures.add('"${data.label}" is tappable but declares no role');
        }
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(root);
    expect(failures, isEmpty, reason: '$what: ${failures.join('; ')}');
  }

  /// Every node in the tree that carries a selected state, by label.
  Map<String, SemanticsData> selectableNodes(WidgetTester tester) {
    final entries = <String, SemanticsData>{};
    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.hasFlag(SemanticsFlag.hasSelectedState)) {
        entries[data.label] = data;
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    return entries;
  }

  group('AccessibleDropdown', () {
    List<DropdownMenuItem<String>> filterItems() => const [
          DropdownMenuItem(value: 'Ha', child: Text('Ha')),
          DropdownMenuItem(value: 'OIII', child: Text('OIII')),
          DropdownMenuItem(value: 'SII', child: Text('SII')),
        ];

    testWidgets('the closed control is one enabled button node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          AccessibleDropdown<String>(
            value: 'Ha',
            items: filterItems(),
            onChanged: (_) {},
          ),
        ),
      );

      assertOperableNodes(tester, what: 'AccessibleDropdown closed');
      final data = tester
          .getSemantics(find.byType(DropdownButton<String>))
          .getSemanticsData();
      expect(data.label, 'Ha');
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
      // The closed control shows the chosen item; it must not inherit that
      // item's selected state and announce itself as a menu entry.
      expect(data.hasFlag(SemanticsFlag.hasSelectedState), isFalse);
      handle.dispose();
    });

    testWidgets('a control showing a hint is still a button', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          AccessibleDropdown<String>(
            hint: const Text('Filter'),
            items: filterItems(),
            onChanged: (_) {},
          ),
        ),
      );

      assertOperableNodes(tester, what: 'AccessibleDropdown hint');
      handle.dispose();
    });

    testWidgets('a hinted control that HAS a selection is still a button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          AccessibleDropdown<String>(
            hint: const Text('Filter'),
            value: 'OIII',
            items: filterItems(),
            onChanged: (_) {},
          ),
        ),
      );

      assertOperableNodes(tester, what: 'AccessibleDropdown hint + value');
      final data = tester
          .getSemantics(find.byType(DropdownButton<String>))
          .getSemanticsData();
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
      expect(data.hasFlag(SemanticsFlag.hasSelectedState), isFalse);
      handle.dispose();
    });

    testWidgets('a disabled control says so instead of staying silent', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          AccessibleDropdown<String>(
            value: 'Ha',
            items: filterItems(),
            onChanged: null,
          ),
        ),
      );

      final data = tester
          .getSemantics(find.byType(DropdownButton<String>))
          .getSemanticsData();
      expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
      expect(data.hasFlag(SemanticsFlag.isEnabled), isFalse);
      handle.dispose();
    });

    testWidgets('every menu entry is enabled and marks the chosen one', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          AccessibleDropdown<String>(
            value: 'OIII',
            items: filterItems(),
            onChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();

      final entries = selectableNodes(tester);
      expect(entries.keys, containsAll(['Ha', 'OIII', 'SII']));
      for (final entry in entries.entries) {
        expect(
          entry.value.hasFlag(SemanticsFlag.isEnabled),
          isTrue,
          reason: '${entry.key} is live but announces itself as disabled',
        );
        expect(
          entry.value.hasFlag(SemanticsFlag.isSelected),
          entry.key == 'OIII',
          reason: '${entry.key} reports the wrong selected state',
        );
        // `SkotiqDropdown` publishes BOTH selected and checked, and AT-SPI
        // carries the two differently — a tree dump prints [ON]/[off] from
        // checked/checkable, so a family that sets only `selected` announces no
        // state at all where its sibling announces one, leaving the current row
        // highlighted on screen and silent to AT.
        expect(
          entry.value.hasFlag(SemanticsFlag.hasCheckedState),
          isTrue,
          reason: '${entry.key} publishes no checked state, so a reader '
              'cannot say which entry is in force',
        );
        expect(
          entry.value.hasFlag(SemanticsFlag.isChecked),
          entry.key == 'OIII',
          reason: '${entry.key} reports the wrong checked state',
        );
      }
      handle.dispose();
    });

    testWidgets('the closed control keeps the item layout it replaces', (
      tester,
    ) async {
      // The selectedItemBuilder reproduces _DropdownMenuItemContainer, so the
      // control must measure exactly as the raw DropdownButton does.
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 300,
            child: DropdownButton<String>(
              value: 'Ha',
              items: filterItems(),
              onChanged: (_) {},
            ),
          ),
        ),
      );
      final raw = tester.getSize(find.byType(DropdownButton<String>));
      final rawLabel = tester.getRect(find.text('Ha'));

      await tester.pumpWidget(
        host(
          SizedBox(
            width: 300,
            child: AccessibleDropdown<String>(
              value: 'Ha',
              items: filterItems(),
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(DropdownButton<String>)), raw);
      expect(tester.getRect(find.text('Ha')), rawLabel);
    });
  });

  // The same contract, on two of the real screens the clusters were filed
  // against: one plain DropdownButton and one DropdownButtonFormField.

  testWidgets('the element-refresh schedule menu is operable', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAppScreen(
      tester,
      const ElementRefreshCard(),
      extraOverrides: [
        elementRefreshServiceProvider.overrideWithValue(_FakeRefresh()),
      ],
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final dropdown = find.byType(DropdownButton<ElementRefreshSchedule>);
    expect(dropdown, findsOneWidget);
    expect(
      tester.getSemantics(dropdown).getSemanticsData().hasFlag(
            SemanticsFlag.isEnabled,
          ),
      isTrue,
      reason: 'the live schedule control announces itself as disabled',
    );

    await tester.tap(dropdown);
    await tester.pumpAndSettle();

    final entries = selectableNodes(tester);
    expect(entries.keys, contains('Weekly'));
    for (final entry in entries.entries) {
      expect(
        entry.value.hasFlag(SemanticsFlag.isEnabled),
        isTrue,
        reason: '${entry.key} is live but announces itself as disabled',
      );
    }
    handle.dispose();
  });

  testWidgets('the secondary-camera form field menu is operable', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secondaryRigConfigProvider.overrideWith(
            (ref) => _SeededRigConfig('secondary-camera'),
          ),
          cameraStateProvider.overrideWith(_PrimaryCameraNotifier.new),
          availableCamerasProvider.overrideWith(
            (ref) async => const [
              DeviceInfo(
                id: 'primary-camera',
                name: 'Primary camera',
                deviceType: DeviceType.camera,
                driverType: DriverType.simulator,
                description: '',
                driverVersion: '',
              ),
              DeviceInfo(
                id: 'secondary-camera',
                name: 'Secondary camera',
                deviceType: DeviceType.camera,
                driverType: DriverType.simulator,
                description: '',
                driverVersion: '',
              ),
            ],
          ),
          secondaryRigStatusProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SecondaryRigCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();

    final entries = selectableNodes(tester);
    expect(entries.keys, contains('Secondary camera'));
    expect(
      entries['Secondary camera']!.hasFlag(SemanticsFlag.isEnabled),
      isTrue,
      reason: 'a selectable camera announces itself as disabled',
    );
    handle.dispose();
  });

  // The sweep itself: no screen may reach for Material's dropdown directly,
  // because doing so silently reintroduces the whole family.

  test('no screen builds a raw Material dropdown', () {
    final screens = Directory('lib/screens');
    expect(screens.existsSync(), isTrue, reason: 'run from the package root');

    final raw = RegExp(r'\bDropdownButton(FormField)?\s*<');
    final offenders = <String>[];
    for (final entity in screens.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('accessible_dropdown.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final code = line.split('//').first;
        if (raw.hasMatch(code)) {
          offenders.add('${entity.path}:${i + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'use AccessibleDropdown / AccessibleDropdownFormField — Material\'s '
          'dropdown announces every live entry as disabled and marks none as '
          'selected:\n${offenders.join('\n')}',
    );
  });
}

class _FakeRefresh extends ElementRefreshService {
  _FakeRefresh() : super(cacheDirectory: Directory.systemTemp.path);

  ElementRefreshConfig _config = const ElementRefreshConfig();

  @override
  Future<ElementRefreshConfig> loadConfig() async => _config;

  @override
  Future<RefreshedElements> loadCached() async => const RefreshedElements();

  @override
  bool isStale(RefreshedElements cached, ElementRefreshConfig cfg) => false;

  @override
  Future<RefreshedElements> refresh({ElementRefreshConfig? config}) async =>
      const RefreshedElements();

  @override
  Future<void> saveConfig(ElementRefreshConfig cfg) async => _config = cfg;
}

class _SeededRigConfig extends SecondaryRigConfigNotifier {
  _SeededRigConfig(String cameraId) {
    setCamera(cameraId);
  }
}

class _PrimaryCameraNotifier extends CameraStateNotifier {
  _PrimaryCameraNotifier(super.ref) {
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'primary-camera',
      deviceName: 'Primary camera',
    );
  }
}
