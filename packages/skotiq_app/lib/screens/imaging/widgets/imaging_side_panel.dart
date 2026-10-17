import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/filter_wheel_selector.dart';
import '../../../widgets/tutorial_keys/imaging_keys.dart';
import '../tabs/mount_tab.dart';
import 'annotation_panel.dart';
import 'calibration_section.dart';
import 'camera_panel.dart';
import 'capture_panel.dart';
import 'depthlock/depthlock_panel.dart';
import 'focus_panel.dart';
import 'guiding_panel.dart';
import 'rotator_panel.dart';

/// The Imaging screen's right column (06 §Imaging, 05 §15).
///
/// The eight controls that used to live behind a 4 × 2 grid of pill tabs are
/// now sections on a [SidePanel]'s 44 px icon strip. The bodies are the same
/// widgets as before; only the way one is chosen changed.
///
/// The strip follows `mockups/imaging.html` rather than the sentence in 06 that
/// calls it "the eight current tabs": 06 promotes the live stacker to a
/// top-level tab in the same paragraph, so Stack leaves the strip and Filter
/// wheel — which the deleted bottom banner used to carry — takes the free slot.
class ImagingSidePanel extends ConsumerWidget {
  const ImagingSidePanel({
    super.key,
    required this.colors,
    required this.selectedSection,
    required this.onSectionSelected,
    this.collapsed = false,
  });

  final SkotiqColors colors;

  /// Index into [sections], stored in `selectedImagingPanelProvider` so the
  /// choice survives navigating away and back.
  final int selectedSection;

  final ValueChanged<int> onSectionSelected;

  /// Animated shut by the page header's `panel-right` button.
  final bool collapsed;

  /// Index of the Annotations section, used by the on-canvas object chips to
  /// reveal the object list.
  static const int annotationsSectionIndex = 7;

  /// The strip, in order. Tooltips are sentence case (06 "Copy rules").
  static const List<SidePanelSection> sections = <SidePanelSection>[
    SidePanelSection(icon: SkotiqIcons.camera, tooltip: 'Capture'),
    SidePanelSection(icon: SkotiqIcons.temperature, tooltip: 'Camera'),
    SidePanelSection(icon: SkotiqIcons.focuser, tooltip: 'Focus'),
    SidePanelSection(icon: SkotiqIcons.guider, tooltip: 'Guiding'),
    SidePanelSection(icon: SkotiqIcons.mount, tooltip: 'Mount'),
    SidePanelSection(icon: SkotiqIcons.filterWheel, tooltip: 'Filter wheel'),
    SidePanelSection(icon: SkotiqIcons.rotator, tooltip: 'Rotator'),
    SidePanelSection(icon: SkotiqIcons.tag, tooltip: 'Annotations'),
    SidePanelSection(
      icon: SkotiqIcons.target,
      // The strip is glyphs only, and a target reticle says nothing about
      // what DepthLock is. The tooltip is the only place the section can
      // introduce itself.
      tooltip: 'DepthLock — goals for faint detail',
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SidePanel(
      sections: sections,
      selectedSection: selectedSection,
      onSectionSelected: onSectionSelected,
      collapsed: collapsed,
      child: ImagingSectionBody(colors: colors, section: selectedSection),
    );
  }
}

/// The body of one strip section. Shared with the narrow bottom sheet, which
/// picks its section from a horizontal chip strip instead of the icon rail.
class ImagingSectionBody extends StatelessWidget {
  const ImagingSectionBody({
    super.key,
    required this.colors,
    required this.section,
  });

  final SkotiqColors colors;
  final int section;

  @override
  Widget build(BuildContext context) {
    // IndexedStack keeps every section's own state (a half-typed field, a
    // guiding graph's history) alive while another one is on screen, exactly
    // as the tab panel did.
    return IndexedStack(
      index: section,
      children: <Widget>[
        CapturePanel(colors: colors),
        _CameraSection(colors: colors),
        FocusPanel(key: ImagingTutorialKeys.focusTab, colors: colors),
        GuidingPanel(colors: colors),
        MountTab(key: ImagingTutorialKeys.mountTab),
        _FilterWheelSection(colors: colors),
        RotatorPanel(colors: colors),
        AnnotationTabPanel(colors: colors),
        DepthLockPanel(colors: colors),
      ],
    );
  }
}

/// Cooling controls and the calibration builder share ONE scroll view so the
/// cooling rows keep their natural height (see the note this replaces on
/// `_CameraTabContent`).
class _CameraSection extends StatelessWidget {
  const _CameraSection({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CameraPanel(colors: colors, scrollable: false),
          const SizedBox(height: SkotiqTokens.spaceLg),
          CalibrationSection(colors: colors),
        ],
      ),
    );
  }
}

/// The filter wheel's positions. The capture bar carries the same selection as
/// a one-line dropdown; this section is where the whole wheel is visible.
class _FilterWheelSection extends ConsumerWidget {
  const _FilterWheelSection({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filterState = ref.watch(filterWheelStateProvider);
    final connected =
        filterState.connectionState == DeviceConnectionState.connected;

    if (!connected || filterState.filterNames.isEmpty) {
      return const EmptyState.compact(
        icon: SkotiqIcons.filterWheel,
        title: 'No filter wheel',
        body: 'Connect a filter wheel to choose a filter for each frame.',
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionTitle(
            icon: SkotiqIcons.filterWheel,
            title: 'Filter wheel',
          ),
          FilterWheelSelector(
            style: FilterSelectorStyle.buttons,
            // The wheel is the screen's only filter-position control, so the
            // exposure settings mirror has to follow the selection or every
            // reader of `exposureSettings.filter` contradicts the header the
            // next frame is written with.
            onFilterSelected: (int position, String name) {
              final settings = ref.read(exposureSettingsProvider);
              ref
                  .read(manualExposureSettingsUpdaterProvider)
                  .update(settings.copyWith(filter: name));
            },
          ),
        ],
      ),
    );
  }
}
