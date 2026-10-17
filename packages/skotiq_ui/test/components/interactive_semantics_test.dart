import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The A11Y-STATE contract for every shared interactive component.
///
/// AT-SPI derives "disabled" from the ABSENCE of the enabled flag, and Flutter
/// publishes that flag only when a widget passes `enabled:` explicitly. So a
/// control that merely carries a tap action — a bare `InkWell`, a
/// `GestureDetector`, Material's own dropdown — reaches a screen reader as an
/// inert, disabled panel while it works perfectly for a mouse. The same defect
/// recurs on every screen that hand-rolls a control, which is why it is pinned
/// here at the components rather than per screen.
///
/// [assertOperableNodes] walks the whole semantics tree, so it also catches the
/// second half of the family: a widget that publishes TWO nodes, one named and
/// one operable, leaving assistive tech with no node that is both.
void main() {
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
      // A node merged into its parent never reaches the platform: the owner
      // drops it from the update and the ancestor it merged into carries its
      // flags and its actions instead. Judging one on its own would fail a
      // control that merges DELIBERATELY — [SkotiqDropdown] publishes the
      // button role above the node that carries the value's words, and that
      // inner node is merged away — over a node no screen reader can reach.
      if (node.isMergedIntoParent) return;
      final data = node.getSemanticsData();
      final isRole =
          data.hasFlag(SemanticsFlag.isButton) ||
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

  SemanticsNode nodeOf(WidgetTester tester, Finder finder) =>
      tester.getSemantics(finder);

  group('declares role and enabled state', () {
    final cases = <String, Widget>{
      'SkotiqButton': SkotiqButton(label: 'Start', onPressed: () {}),
      'SkotiqChip': SkotiqChip(label: 'Ha', onTap: () {}),
      'SkotiqCard': SkotiqCard(onTap: () {}, child: const Text('Card')),
      'SkotiqCheckbox': SkotiqCheckbox(value: true, onChanged: (_) {}),
      'SkotiqSwitch': SkotiqSwitch(value: true, onChanged: (_) {}),
      'SkotiqSwitchRow': SkotiqSwitchRow(
        label: 'Regulated cooling',
        value: true,
        onChanged: (_) {},
      ),
      'SkotiqTextField': const SkotiqTextField(label: 'Name'),
      'SkotiqStepper': SkotiqStepper(value: 3, onChanged: (_) {}),
      'StatusPill': StatusPill(
        icon: LucideIcons.thermometer,
        label: 'Sensor Temp',
        value: '-10.0°C',
        onTap: () {},
      ),
      'SubTabButton': SubTabButton(
        label: 'Overview',
        isSelected: true,
        onTap: () {},
      ),
      'NavItem': NavItem(
        icon: LucideIcons.home,
        label: 'Tonight',
        isSelected: true,
        isExpanded: true,
        onTap: () {},
      ),
      'ScienceInfoButton': const ScienceInfoButton(
        title: 'Optical diagnostics',
        body: 'What the numbers mean.',
      ),
      'AccessibleIconButton': AccessibleIconButton(
        icon: LucideIcons.bell,
        label: 'Alerts',
        onPressed: () {},
      ),
      'SkotiqAlert': SkotiqAlert(
        message: 'Cooler is warming',
        onDismiss: () {},
      ),
    };

    for (final entry in cases.entries) {
      testWidgets(entry.key, (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(host(entry.value));
        await tester.pump();
        assertOperableNodes(tester, what: entry.key);
        handle.dispose();
      });
    }

    testWidgets('AdaptiveTabBar', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 600,
            child: AdaptiveTabBar(
              tabs: const [
                AdaptiveTab(label: 'Session', icon: LucideIcons.play),
                AdaptiveTab(label: 'History', icon: LucideIcons.history),
              ],
              selectedIndex: 0,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      assertOperableNodes(tester, what: 'AdaptiveTabBar');
      handle.dispose();
    });
  });

  group('SkotiqDropdown', () {
    testWidgets('the closed control is one enabled button node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          SkotiqDropdown(
            value: 'Light',
            items: const ['Light', 'Dark', 'Flat'],
            onChanged: (_) {},
          ),
        ),
      );

      assertOperableNodes(tester, what: 'SkotiqDropdown closed');
      final node = nodeOf(tester, find.byType(SkotiqDropdown));
      final data = node.getSemanticsData();
      expect(data.label, 'Light');
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
      // The closed control shows the chosen item; it must not inherit that
      // item's selected state and announce itself as a menu entry.
      expect(data.hasFlag(SemanticsFlag.hasSelectedState), isFalse);
      handle.dispose();
    });

    testWidgets('a disabled control says so instead of staying silent', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          const SkotiqDropdown(value: 'Light', items: ['Light', 'Dark']),
        ),
      );

      final data = nodeOf(
        tester,
        find.byType(SkotiqDropdown),
      ).getSemanticsData();
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
          SkotiqDropdown(
            value: 'Dark',
            items: const ['Light', 'Dark', 'Red night'],
            onChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.byType(SkotiqDropdown));
      await tester.pumpAndSettle();

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

      expect(entries.keys, containsAll(['Light', 'Dark', 'Red night']));
      for (final entry in entries.entries) {
        expect(
          entry.value.hasFlag(SemanticsFlag.isEnabled),
          isTrue,
          reason: '${entry.key} is live but announces itself as disabled',
        );
        expect(
          entry.value.hasFlag(SemanticsFlag.isSelected),
          entry.key == 'Dark',
          reason: '${entry.key} reports the wrong selected state',
        );
        // NEW-C4: a live tree dump of the open Theme / Frame Type / sort menus
        // showed three bare `button:` entries and nothing marking the current
        // one. AT-SPI's SELECTED is not what a menu consumer reads; CHECKED is,
        // and it is the state a radio-style menu is meant to publish.
        expect(
          entry.value.hasFlag(SemanticsFlag.hasCheckedState),
          isTrue,
          reason:
              '${entry.key} offers no checked state, so nothing in the '
              'menu says which option is in force',
        );
        expect(
          entry.value.hasFlag(SemanticsFlag.isChecked),
          entry.key == 'Dark',
          reason: '${entry.key} reports the wrong checked state',
        );
      }
      handle.dispose();
    });

    // The export sheet's "After a step" picker is this shape: a hint for the
    // state before a step is chosen, and a value once one is. Material decides
    // whether to publish the button role from whether a hint EXISTS, not from
    // what is on screen, so with both it published none at all and the live
    // control reached AT-SPI as ROLE_PANEL — a screen reader was told the step
    // was "4. Stretch" and never that it could choose another.
    testWidgets('a picker with a hint AND a value is still a button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          SkotiqDropdown(
            value: '4. Stretch',
            hint: 'Choose the step to stop after',
            items: const ['1. Crop', '4. Stretch'],
            isExpanded: true,
            onChanged: (_) {},
          ),
        ),
      );

      assertOperableNodes(tester, what: 'SkotiqDropdown hint + value');
      final data = nodeOf(
        tester,
        find.byType(SkotiqDropdown),
      ).getSemanticsData();
      expect(data.label, '4. Stretch');
      expect(
        data.hasFlag(SemanticsFlag.isButton),
        isTrue,
        reason:
            'the closed picker publishes no role, so nothing tells a '
            'screen reader the step is choosable',
      );
      expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });

    testWidgets('a hint with no value is one node, named and operable', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          SkotiqDropdown(
            hint: 'Choose the step to stop after',
            items: const ['1. Crop', '4. Stretch'],
            onChanged: (_) {},
          ),
        ),
      );

      assertOperableNodes(tester, what: 'SkotiqDropdown hint only');
      final data = nodeOf(
        tester,
        find.byType(SkotiqDropdown),
      ).getSemanticsData();
      // Both halves on ONE node: the hint used to be named on a node with no
      // tap and operable on a node with no name, which leaves assistive tech
      // with nothing it can both read out and activate.
      expect(data.label, 'Choose the step to stop after');
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });

    testWidgets('a merging host announces the value exactly once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // The shape every settings dropdown ships in: `SettingRow` merges its
      // title and its control into one node, which is what hid the missing
      // role for so long. The role must not arrive twice now that the
      // component carries one of its own.
      await tester.pumpWidget(
        host(
          MergeSemantics(
            key: const Key('row'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Theme'),
                SkotiqDropdown(
                  value: 'Dark',
                  items: const ['Light', 'Dark'],
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      );

      assertOperableNodes(tester, what: 'SkotiqDropdown in a merging host');
      final data = nodeOf(
        tester,
        find.byKey(const Key('row')),
      ).getSemanticsData();
      expect(data.label, 'Theme\nDark');
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
      handle.dispose();
    });
  });

  group('state is carried, not just painted', () {
    testWidgets('a selectable chip announces its selection', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(SkotiqChip(label: 'Failed', selected: true, onTap: () {})),
      );
      expect(
        nodeOf(
          tester,
          find.byType(SkotiqChip),
        ).getSemanticsData().hasFlag(SemanticsFlag.isSelected),
        isTrue,
      );
      handle.dispose();
    });

    testWidgets('a switch row names the setting it toggles', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          SkotiqSwitchRow(
            label: 'Start cooling when the camera connects',
            value: true,
            onChanged: (_) {},
          ),
        ),
      );
      final data = nodeOf(
        tester,
        find.byType(SkotiqSwitch),
      ).getSemanticsData();
      expect(data.label, 'Start cooling when the camera connects');
      expect(data.hasFlag(SemanticsFlag.isToggled), isTrue);
      handle.dispose();
    });

    testWidgets('a labelled field carries its label on the field node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(const SkotiqTextField(label: 'Step size')),
      );
      expect(
        nodeOf(tester, find.byType(TextFormField)).getSemanticsData().label,
        'Step size',
      );
      handle.dispose();
    });

    testWidgets('an icon button is one node that is both named and operable', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var pressed = 0;
      await tester.pumpWidget(
        host(
          AccessibleIconButton(
            icon: LucideIcons.settings,
            label: 'Settings',
            onPressed: () => pressed++,
          ),
        ),
      );

      final node = nodeOf(tester, find.byType(AccessibleIconButton));
      final data = node.getSemanticsData();
      expect(data.label, 'Settings');
      expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);

      tester.binding.pipelineOwner.semanticsOwner!.performAction(
        node.id,
        SemanticsAction.tap,
      );
      expect(pressed, 1);
      handle.dispose();
    });
  });
}
