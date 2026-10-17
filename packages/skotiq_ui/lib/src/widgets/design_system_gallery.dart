import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '_design_showcase_primitives.dart';
import '../components/skotiq_button.dart';
import '../components/skotiq_checkbox.dart';
import '../components/skotiq_dropdown.dart';
import '../components/skotiq_switch.dart';
import '../components/skotiq_switch_row.dart';
import '../components/skotiq_text_field.dart';
import '../components/status_dot.dart';
// Observatory wave 1
import '../components/instrument_pill.dart';
import '../components/page_header.dart';
import '../tokens/shell_chrome_metrics.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
// Observatory wave 2
import '../components/adaptive_tab_bar.dart';
import '../components/candidate_row.dart';
import '../components/checklist.dart';
import '../components/form_row.dart';
import '../components/glass.dart';
import '../components/list_rows.dart';
import '../components/night_band.dart';
import '../components/skotiq_banner.dart';
import '../components/skotiq_chip.dart';
import '../components/skotiq_icon_button.dart';
import '../components/skotiq_panel.dart';
import '../components/skotiq_toolbar.dart';
import '../components/readout.dart';
import '../components/section_title.dart';
import '../components/segmented_control.dart';
import '../dialogs/skotiq_dialog.dart';
import '../layout/side_panel.dart';
import 'empty_state.dart';

/// Renderable design-system gallery for release visual QA and widget snapshots.
class SkotiqDesignSystemGallery extends StatefulWidget {
  const SkotiqDesignSystemGallery({super.key});

  @override
  State<SkotiqDesignSystemGallery> createState() =>
      _SkotiqDesignSystemGalleryState();
}

class _SkotiqDesignSystemGalleryState extends State<SkotiqDesignSystemGallery> {
  int _actionCount = 0;

  void _recordAction() {
    setState(() => _actionCount += 1);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Design System Gallery',
                    style: SkotiqTypography.h2.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  Text(
                    'Sample actions: $_actionCount',
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceLg),
                  ShowcaseSection.plain(
                    title: 'Color Palette',
                    child: Wrap(
                      spacing: SkotiqTokens.spaceMd,
                      runSpacing: SkotiqTokens.spaceMd,
                      children: [
                        ShowcaseSwatch.gallery(
                          label: 'Primary',
                          color: colors.primary,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Accent',
                          color: colors.accent,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Background',
                          color: colors.background,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Surface',
                          color: colors.surface,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Well',
                          color: colors.well,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Success',
                          color: colors.success,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Warning',
                          color: colors.warning,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Error',
                          color: colors.error,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Info',
                          color: colors.info,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Text Primary',
                          color: colors.textPrimary,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Text Secondary',
                          color: colors.textSecondary,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Text Muted',
                          color: colors.textMuted,
                        ),
                        ShowcaseSwatch.gallery(
                          label: 'Border',
                          color: colors.border,
                        ),
                      ],
                    ),
                  ),
                  ShowcaseSection.plain(
                    title: 'Typography',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TypographySpecimen(
                          label: 'display — the Tonight hero line',
                          sample: 'M51 Whirlpool Galaxy',
                          style: SkotiqTypography.display,
                          colors: colors,
                        ),
                        _TypographySpecimen(
                          label: 'pageTitle — the screen title',
                          sample: 'Sequencer',
                          style: SkotiqTypography.pageTitle,
                          colors: colors,
                        ),
                        _TypographySpecimen(
                          label: 'sectionTitle — panels, dialogs, empty states',
                          sample: 'Sequence run',
                          style: SkotiqTypography.sectionTitle,
                          colors: colors,
                        ),
                        _TypographySpecimen(
                          label: 'eyebrow — panel and column labels',
                          sample: 'EQUIPMENT',
                          style: SkotiqTypography.eyebrow,
                          colors: colors,
                          muted: true,
                        ),
                        _TypographySpecimen(
                          label: 'body — default text',
                          sample: 'Connect your camera and mount.',
                          style: SkotiqTypography.body,
                          colors: colors,
                        ),
                        _TypographySpecimen(
                          label: 'bodyStrong — names in lists',
                          sample: 'Simulated camera',
                          style: SkotiqTypography.bodyStrong,
                          colors: colors,
                        ),
                        _TypographySpecimen(
                          label: 'bodySm — dense lists and table cells',
                          sample: 'Per-frame countdown and sequence totals',
                          style: SkotiqTypography.bodySm,
                          colors: colors,
                        ),
                        _TypographySpecimen(
                          label: 'caption — hints and timestamps',
                          sample: 'Last frame 22:41:08',
                          style: SkotiqTypography.caption,
                          colors: colors,
                          muted: true,
                        ),
                        _TypographySpecimen(
                          label: 'readoutLg — hero numbers',
                          sample: '02:45',
                          style: SkotiqTypography.readoutLg,
                          colors: colors,
                        ),
                        _TypographySpecimen(
                          label: 'readoutMd — the standard readout',
                          sample: '-10.0',
                          style: SkotiqTypography.readoutMd,
                          colors: colors,
                        ),
                        _TypographySpecimen(
                          label: 'readoutSm — dense rows and key/value lists',
                          sample: '18 min',
                          style: SkotiqTypography.readoutSm,
                          colors: colors,
                        ),
                        _TypographySpecimen(
                          label: 'readoutLabel — the label under a readout',
                          sample: 'SENSOR',
                          style: SkotiqTypography.readoutLabel,
                          colors: colors,
                          muted: true,
                        ),
                        _TypographySpecimen(
                          label: 'monoCaption — legends, kbd hints, tags',
                          sample: 'RA 05h 35m 17s',
                          style: SkotiqTypography.monoCaption,
                          colors: colors,
                          muted: true,
                        ),
                        _TypographySpecimen(
                          label: 'button — buttons, tabs, rail labels',
                          sample: 'Start sequence',
                          style: SkotiqTypography.button,
                          colors: colors,
                        ),
                      ],
                    ),
                  ),
                  // Observatory wave 2
                  const _ObservatorySections(),

                  // Observatory wave 1
                  ShowcaseSection.plain(
                    title: 'Instrument bar',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: ShellChromeMetrics.statusBarHeight,
                          decoration: BoxDecoration(
                            color: colors.surface,
                            border: Border(
                              top: BorderSide(color: colors.border),
                            ),
                          ),
                          // The specimen scrolls the way the real bar's left
                          // group does, so a narrow gallery viewport shows a
                          // cut strip rather than an overflow stripe.
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(
                              horizontal: SkotiqTokens.spaceMd,
                            ),
                            children: [
                              InstrumentPill(
                                key: const ValueKey('gallery-instrument-pill'),
                                dotTone: InstrumentTone.success,
                                value: 'Running',
                                live: true,
                                onTap: _recordAction,
                              ),
                              const InstrumentSeparator(),
                              InstrumentPill(
                                icon: LucideIcons.camera,
                                dotTone: InstrumentTone.success,
                                value: 'ASI2600MM',
                                onTap: _recordAction,
                              ),
                              InstrumentPill(
                                icon: LucideIcons.mountain,
                                dotTone: InstrumentTone.success,
                                value: 'EQ6-R',
                                onTap: _recordAction,
                              ),
                              InstrumentPill(
                                icon: LucideIcons.crosshair,
                                dotTone: InstrumentTone.idle,
                                value: 'No guider',
                                onTap: _recordAction,
                              ),
                              const SizedBox(width: SkotiqTokens.space3xl),
                              const InstrumentPill(
                                icon: LucideIcons.thermometer,
                                value: '-10.0\u00B0C',
                                mono: true,
                              ),
                              const InstrumentSeparator(),
                              const InstrumentPill(
                                icon: LucideIcons.clock,
                                value: '22:41:08',
                                mono: true,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  ShowcaseSection.plain(
                    title: 'Page header',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        PageHeader(
                          title: 'Sequencer',
                          icon: LucideIcons.listOrdered,
                          actions: [
                            SkotiqButton(
                              label: 'Start',
                              size: ButtonSize.small,
                              onPressed: _recordAction,
                            ),
                          ],
                        ),
                        const SizedBox(height: SkotiqTokens.spaceLg),
                        const PageHeader(
                          title: 'Equipment',
                          icon: LucideIcons.plug,
                          context: 'My Equipment',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypographySpecimen extends StatelessWidget {
  final String label;
  final String sample;
  final TextStyle style;
  final SkotiqColors colors;
  final bool muted;

  const _TypographySpecimen({
    required this.label,
    required this.sample,
    required this.style,
    required this.colors,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            sample,
            style: style.copyWith(
              color: muted ? colors.textMuted : colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Observatory wave 2
// ---------------------------------------------------------------------------

/// Every component added or changed by 05-components.md, in one block.
///
/// Appended rather than woven into the sections above so the pre-overhaul
/// gallery keeps its evidence markers (the `design_system_gallery_missing`
/// audit rule reads this file for them) while the new kit gets a golden of its
/// own.
class _ObservatorySections extends StatefulWidget {
  const _ObservatorySections();

  @override
  State<_ObservatorySections> createState() => _ObservatorySectionsState();
}

class _ObservatorySectionsState extends State<_ObservatorySections> {
  /// How many sample controls have been pressed.
  ///
  /// The sheet's buttons need a REAL callback, not `() {}`: an empty callback
  /// is a dead control, `ui_consistency_audit`'s `empty_callback` rule counts
  /// every one of them, and a gallery that ships dead controls is teaching the
  /// pattern it exists to prevent.
  int _actions = 0;
  void _act() => setState(() => _actions += 1);

  int _segment = 0;
  int _underlineTab = 0;
  int _stripSection = 1;
  bool _chipSelected = true;
  String? _frameType = 'Light';
  bool _autosave = true;
  bool _cooling = true;

  static final DateTime _sunset = DateTime(2026, 9, 9, 19, 12);
  static final DateTime _astroDark = DateTime(2026, 9, 9, 20, 48);
  static final DateTime _astroDawn = DateTime(2026, 9, 10, 4, 51);
  static final DateTime _sunrise = DateTime(2026, 9, 10, 6, 24);
  static final DateTime _now = DateTime(2026, 9, 9, 22, 41);

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
          child: Text(
            'Observatory sample actions: $_actions',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
        ShowcaseSection.plain(
          title: 'Panels and wells',
          child: Wrap(
            spacing: SkotiqTokens.spaceMd,
            runSpacing: SkotiqTokens.spaceMd,
            children: [
              SizedBox(
                width: 260,
                child: SkotiqPanel(
                  head: const PanelHead(
                    label: 'Equipment',
                    icon: LucideIcons.activity,
                  ),
                  child: Container(
                    height: 48,
                    alignment: Alignment.center,
                    decoration: SkotiqDecorations.well(colors),
                    child: Text(
                      'well inside a panel (max depth)',
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 260,
                child: SkotiqPanel(
                  selected: true,
                  head: const PanelHead(label: 'Selected panel'),
                  child: Text(
                    'A primary ring at 50%, not a tinted fill.',
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 260,
                child: SkotiqPanel(
                  key: const ValueKey('gallery-panel-dashed'),
                  dashed: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.plus,
                        size: SkotiqTokens.iconRail,
                        color: colors.textMuted,
                      ),
                      const SizedBox(height: SkotiqTokens.spaceSm),
                      Text(
                        'Empty slot — add a device',
                        style: SkotiqTypography.bodySm.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 260,
                child: Container(
                  padding: SkotiqTokens.paddingLg,
                  decoration: SkotiqDecorations.panelTinted(
                    colors,
                    tone: colors.warning,
                  ),
                  child: Text(
                    'A tinted panel, for the rare block whose TONE is the '
                    'message.',
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const ShowcaseSection.plain(
          title: 'Readouts',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkotiqPanel(
                child: ReadoutRow(
                  children: [
                    Readout(
                      value: '-10.0',
                      unit: '°C',
                      label: 'Sensor',
                      size: ReadoutSize.lg,
                    ),
                    Readout(
                      value: '2.49',
                      unit: 'px',
                      label: 'HFR',
                      size: ReadoutSize.lg,
                    ),
                    Readout(value: '0.42', unit: '"', label: 'RMS'),
                    Readout(value: '25000', label: 'Position'),
                    Readout(
                      value: '13h 29m 54s',
                      label: 'RA',
                      size: ReadoutSize.sm,
                    ),
                    Readout(value: null, label: 'Guide star'),
                    // No label and no row reserved for one: the value is the
                    // whole widget, for a number that already has a label
                    // beside it (the centre of a progress ring).
                    Readout(value: '61%', size: ReadoutSize.sm),
                  ],
                ),
              ),
              SizedBox(height: SkotiqTokens.spaceMd),
              SkotiqPanel(
                child: KeyValueList(
                  rows: [
                    ('Clouds', '4%'),
                    ('Wind', '6 km/h'),
                    ('Dew point margin', '5.3°'),
                  ],
                ),
              ),
            ],
          ),
        ),
        ShowcaseSection.plain(
          title: 'Underline tabs',
          child: SizedBox(
            height: 40,
            child: AdaptiveTabBar(
              horizontalPadding: 0,
              tabs: const [
                AdaptiveTab(label: 'Builder'),
                AdaptiveTab(label: 'Templates'),
                AdaptiveTab(label: 'Saved'),
                AdaptiveTab(label: 'History', count: '3'),
              ],
              selectedIndex: _underlineTab,
              onSelected: (i) => setState(() => _underlineTab = i),
            ),
          ),
        ),
        ShowcaseSection.plain(
          title: 'Segmented control',
          child: SegmentedControl(
            segments: const ['Nodes', 'Snippets', 'Queue'],
            selectedIndex: _segment,
            onSelected: (i) => setState(() => _segment = i),
          ),
        ),
        ShowcaseSection.plain(
          title: 'Buttons and icon buttons',
          child: Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SkotiqButton(
                key: const ValueKey('gallery-button-primary'),
                label: 'Primary',
                icon: LucideIcons.play,
                onPressed: _act,
              ),
              SkotiqButton(
                key: const ValueKey('gallery-button-secondary'),
                label: 'Secondary',
                variant: ButtonVariant.secondary,
                onPressed: _act,
              ),
              SkotiqButton(
                key: const ValueKey('gallery-button-badge'),
                label: 'Preflight',
                variant: ButtonVariant.secondary,
                badge: '2',
                badgeSemanticsLabel: '2 issues',
                badgeTone: ChipTone.warning,
                onPressed: _act,
              ),
              SkotiqButton(
                label: 'Ghost',
                variant: ButtonVariant.ghost,
                onPressed: _act,
              ),
              SkotiqButton(
                label: 'Stop',
                icon: LucideIcons.square,
                variant: ButtonVariant.destructive,
                onPressed: _act,
              ),
              SkotiqButton(
                label: 'Start',
                icon: LucideIcons.play,
                variant: ButtonVariant.start,
                onPressed: _act,
              ),
              const SkotiqButton(label: 'Disabled'),
              SkotiqButton(
                label: 'Small',
                size: ButtonSize.small,
                variant: ButtonVariant.secondary,
                onPressed: _act,
              ),
              SkotiqButton(
                label: 'Large',
                size: ButtonSize.large,
                variant: ButtonVariant.secondary,
                onPressed: _act,
              ),
              SkotiqIconButton(
                icon: LucideIcons.settings,
                tooltip: 'Settings',
                onPressed: _act,
              ),
              SkotiqIconButton(
                icon: LucideIcons.layers,
                tooltip: 'Layers',
                selected: true,
                onPressed: _act,
              ),
            ],
          ),
        ),
        ShowcaseSection.plain(
          title: 'Toolbar',
          child: SkotiqToolbar(
            overflowIcon: LucideIcons.moreHorizontal,
            onOverflowPressed: _act,
            overflow: [
              SkotiqIconButton(
                icon: LucideIcons.share2,
                tooltip: 'Share',
                size: IconButtonSize.sm,
                onPressed: _act,
              ),
              SkotiqIconButton(
                icon: LucideIcons.download,
                tooltip: 'Export',
                size: IconButtonSize.sm,
                onPressed: _act,
              ),
            ],
            groups: [
              [
                SkotiqIconButton(
                  icon: LucideIcons.undo2,
                  tooltip: 'Undo',
                  size: IconButtonSize.sm,
                  onPressed: _act,
                ),
                SkotiqIconButton(
                  icon: LucideIcons.redo2,
                  tooltip: 'Redo',
                  size: IconButtonSize.sm,
                  onPressed: _act,
                ),
              ],
              [
                SkotiqButton(
                  label: 'Timeline',
                  icon: LucideIcons.clock,
                  size: ButtonSize.small,
                  variant: ButtonVariant.ghost,
                  onPressed: _act,
                ),
                SkotiqButton(
                  label: 'Map',
                  icon: LucideIcons.map,
                  size: ButtonSize.small,
                  variant: ButtonVariant.ghost,
                  onPressed: _act,
                ),
              ],
            ],
          ),
        ),
        ShowcaseSection.plain(
          title: 'Fields and form rows',
          // The gallery is rendered at 390px wide in one of its tests; the
          // fixed-width specimens scroll rather than overflow.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 360,
              child: Column(
                children: [
                  const FormRow(
                    label: 'Exposure',
                    child: SkotiqTextField(
                      initialValue: '120',
                      suffix: 's',
                      mono: true,
                    ),
                  ),
                  const SizedBox(height: FormRow.rowGap),
                  FormRow(
                    label: 'Frame type',
                    child: SkotiqDropdown(
                      key: const ValueKey('gallery-dropdown'),
                      value: _frameType,
                      items: const ['Light', 'Dark', 'Flat', 'Bias'],
                      onChanged: (value) => setState(() => _frameType = value),
                    ),
                  ),
                  const SizedBox(height: FormRow.rowGap),
                  const FormRow(
                    label: 'Search',
                    child: SkotiqTextField(
                      hint: 'Search nodes…',
                      prefixIcon: LucideIcons.search,
                    ),
                  ),
                  const SizedBox(height: FormRow.rowGap),
                  FormRow(
                    label: 'Autosave',
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SkotiqCheckbox(
                        value: _autosave,
                        onChanged: (value) =>
                            setState(() => _autosave = value ?? false),
                      ),
                    ),
                  ),
                  const SizedBox(height: FormRow.rowGap),
                  FormRow(
                    label: 'Cooling',
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SkotiqSwitch(
                        key: const ValueKey('gallery-switch'),
                        value: _cooling,
                        onChanged: (value) => setState(() => _cooling = value),
                      ),
                    ),
                  ),
                  const SizedBox(height: FormRow.rowGap),
                  // The same row in a 150px pane: the label column gives way
                  // rather than overflowing, which is what a side panel does
                  // on every frame of its 220ms open.
                  const SizedBox(
                    width: 150,
                    child: FormRow(
                      key: ValueKey('gallery-formrow-narrow'),
                      label: 'Exposure',
                      child: SkotiqTextField(
                        initialValue: '120',
                        suffix: 's',
                        mono: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: FormRow.rowGap),
                  SkotiqSwitchRow(
                    label: 'Dew heater',
                    subtitle: 'A row that carries its own explanation',
                    value: _cooling,
                    onChanged: (value) => setState(() => _cooling = value),
                  ),
                ],
              ),
            ),
          ),
        ),
        ShowcaseSection.plain(
          title: 'Chips and status dots',
          child: Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const SkotiqChip(
                label: 'Connected',
                tone: ChipTone.success,
                dot: true,
              ),
              const SkotiqChip(
                label: 'Session only',
                tone: ChipTone.warning,
                dot: true,
              ),
              const SkotiqChip(
                label: 'Disconnected',
                tone: ChipTone.error,
                dot: true,
              ),
              SkotiqChip(
                label: 'Transit 01:08',
                tone: ChipTone.primary,
                selected: _chipSelected,
                onTap: () => setState(() => _chipSelected = !_chipSelected),
              ),
              const SkotiqChip(label: '27 nodes'),
              SkotiqFilterChip(
                label: 'Type: any',
                trailingIcon: LucideIcons.chevronDown,
                onTap: _act,
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusDot(color: colors.success, live: true),
                  const SizedBox(width: SkotiqChip.innerGap),
                  Text(
                    'Live dot',
                    style: SkotiqChip.textStyle().copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        ShowcaseSection.plain(
          title: 'Banner',
          child: Column(
            children: [
              SkotiqBanner(
                title: 'Catalogs not installed.',
                message:
                    'Annotations and plate solving need HYG + OpenNGC (60 MB).',
                action: SkotiqButton(
                  label: 'Download',
                  size: ButtonSize.small,
                  onPressed: _act,
                ),
                onDismiss: _act,
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              const SkotiqBanner(
                title: 'Ends after astro dawn.',
                message: 'Reduce count to 32 to finish by 04:51.',
                tone: BannerTone.warning,
              ),
            ],
          ),
        ),
        ShowcaseSection.plain(
          title: 'Empty state',
          // A MINIMUM, not a fixed height: the sentence wraps to three lines at
          // the 390px width the gallery is also tested at, and a fixed box
          // would clip it there.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 170),
            child: SkotiqPanel(
              child: EmptyState(
                icon: LucideIcons.folderOpen,
                title: 'Nothing captured yet',
                body:
                    'Start a capture or a sequence and this fills in as frames '
                    'arrive.',
                action: SkotiqButton(
                  label: 'Go to Imaging',
                  size: ButtonSize.small,
                  variant: ButtonVariant.secondary,
                  onPressed: _act,
                ),
              ),
            ),
          ),
        ),
        ShowcaseSection.plain(
          title: 'Dialog',
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: SkotiqDialog.widthConfirm,
              child: SkotiqDialogSurface(
                framed: true,
                title: 'Replace the current sequence?',
                showCloseButton: false,
                actions: [
                  SkotiqButton(
                    label: 'Cancel',
                    variant: ButtonVariant.ghost,
                    onPressed: _act,
                  ),
                  SkotiqButton(
                    label: 'Save first',
                    variant: ButtonVariant.secondary,
                    onPressed: _act,
                  ),
                  SkotiqButton(label: 'Replace', onPressed: _act),
                ],
                child: Text(
                  'Loading “Mono LRGB M51” discards 3 unsaved changes '
                  'to “Untitled sequence”.',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
        ShowcaseSection.plain(
          title: 'Glass',
          child: SizedBox(
            height: 120,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: SkotiqColors.dark.background,
                borderRadius: SkotiqTokens.borderRadiusLg,
              ),
              child: Stack(
                children: [
                  const Positioned(
                    left: SkotiqTokens.spaceMd,
                    bottom: SkotiqTokens.spaceMd,
                    child: Glass(
                      child: ReadoutRow(
                        gap: DeviceRow.readoutGap,
                        children: [
                          Readout(value: '2.49', unit: 'px', label: 'HFR'),
                          Readout(value: '43', label: 'Stars'),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    right: SkotiqTokens.spaceMd,
                    top: SkotiqTokens.spaceMd,
                    child: Glass(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StatusDot(color: colors.success, live: true),
                          const SizedBox(width: SkotiqTokens.spaceSm),
                          Text(
                            'Exposing 42 / 120 s',
                            style: SkotiqTypography.caption.copyWith(
                              color: SkotiqColors.dark.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ShowcaseSection.plain(
          title: 'Side panel',
          child: SizedBox(
            height: 280,
            child: Row(
              children: [
                const Spacer(),
                SidePanel(
                  sections: const [
                    SidePanelSection(
                      icon: LucideIcons.sliders,
                      tooltip: 'Capture',
                    ),
                    SidePanelSection(
                      icon: LucideIcons.target,
                      tooltip: 'Target',
                    ),
                    SidePanelSection(
                      icon: LucideIcons.history,
                      tooltip: 'History',
                    ),
                  ],
                  selectedSection: _stripSection,
                  onSectionSelected: (i) => setState(() => _stripSection = i),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SectionTitle(
                        title: 'Target',
                        icon: LucideIcons.target,
                      ),
                      ListRow(
                        title: 'M51 Whirlpool',
                        icon: LucideIcons.star,
                        trailing: '22:41',
                        onTap: _act,
                      ),
                      ListRow(
                        title: 'NGC 7000',
                        icon: LucideIcons.star,
                        trailing: '23:04',
                        onTap: _act,
                      ),
                      const SizedBox(height: SidePanel.sectionGap),
                      const SectionTitle(
                        title: 'Devices',
                        icon: LucideIcons.aperture,
                      ),
                      DeviceRow(
                        name: 'Simulated camera',
                        leading: StatusDot(color: colors.success),
                        readouts: const [
                          Readout(
                            value: '-10.0',
                            unit: '°C',
                            label: 'Temp',
                            size: ReadoutSize.sm,
                          ),
                        ],
                      ),
                      // A device with nothing to report says so in a word,
                      // rather than in a row of em dashes.
                      DeviceRow(
                        name: 'Mount',
                        leading: StatusDot(color: colors.textMuted),
                        trailing: Text(
                          'Not connected',
                          style: SkotiqTypography.bodySm.copyWith(
                            color: colors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        ShowcaseSection.plain(
          title: 'Candidate',
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 560,
              child: Candidate(
                score: '94',
                name: 'M51 Whirlpool Galaxy',
                detail: 'Galaxy · 11.2 arcmin · mag 8.4',
                readouts: const [
                  Readout(value: '61', unit: '°', label: 'Alt'),
                  Readout(value: '01:08', label: 'Transit'),
                ],
                window: const CandidateWindow(start: 0.2, end: 0.8, now: 0.45),
                action: SkotiqButton(
                  label: 'Plan',
                  size: ButtonSize.small,
                  variant: ButtonVariant.secondary,
                  onPressed: _act,
                ),
              ),
            ),
          ),
        ),
        ShowcaseSection.plain(
          title: 'Checklist',
          child: SkotiqPanel(
            child: Checklist(
              steps: [
                const ChecklistStep(
                  title: 'Set your observing site',
                  detail: 'Boston, 42.36 / -71.06',
                  state: ChecklistStepState.done,
                ),
                ChecklistStep(
                  title: 'Connect a camera and a mount',
                  detail: 'Nothing is connected yet.',
                  state: ChecklistStepState.next,
                  action: SkotiqButton(
                    label: 'Open Equipment',
                    size: ButtonSize.small,
                    variant: ButtonVariant.secondary,
                    onPressed: _act,
                  ),
                ),
                const ChecklistStep(
                  title: 'Install the catalogs',
                  detail: 'HYG + OpenNGC, 60 MB.',
                ),
              ],
            ),
          ),
        ),
        ShowcaseSection.plain(
          title: 'Night band',
          child: NightBand(
            sunset: _sunset,
            astroDark: _astroDark,
            astroDawn: _astroDawn,
            sunrise: _sunrise,
            now: _now,
            targetAltitudeCurve: const [
              0.1,
              0.3,
              0.55,
              0.74,
              0.86,
              0.9,
              0.82,
              0.63,
              0.4,
              0.18,
              0.05,
            ],
            imageableWindow: NightBandWindow(
              start: _astroDark,
              end: DateTime(2026, 9, 10, 3, 10),
            ),
            events: [
              NightBandEvent(time: _sunset, label: '19:12 sunset'),
              NightBandEvent(time: _astroDark, label: '20:48 astro dark'),
              NightBandEvent(time: _astroDawn, label: '04:51 astro dawn'),
              NightBandEvent(time: _sunrise, label: '06:24 sunrise'),
            ],
          ),
        ),
      ],
    );
  }
}
