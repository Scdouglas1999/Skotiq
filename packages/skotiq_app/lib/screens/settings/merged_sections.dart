import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'widgets/auto_save_settings.dart';
import 'widgets/autofocus_settings.dart';
import 'widgets/file_path_settings.dart';
import 'widgets/focus_model_settings.dart';
import 'widgets/predictive_af_settings.dart';
import 'widgets/settings_widgets.dart' show settingsPagePadding;

/// Stacks two existing settings widgets into one continuously-scrolling section.
///
/// Each child page is rendered in embedded mode (`SettingsPage.scrollable:
/// false`), so it contributes a bounded-height column instead of its own scroll
/// view. Both are then wrapped — with a labelled divider between them — in a
/// SINGLE outer scroll view: giving each child an [Expanded] scroll region
/// instead splits the page into two half-height, independently-scrolling panes.
class _MergedSection extends StatelessWidget {
  const _MergedSection({
    required this.isMobile,
    required this.title,
    required this.description,
    required this.firstLabel,
    required this.first,
    required this.secondLabel,
    required this.second,
    this.thirdLabel,
    this.third,
  });

  final bool isMobile;

  /// The page title, and the ONE lead line a Settings page is allowed
  /// (06 §Settings). A merged section is still a settings page: without these
  /// it was the only one in Settings that opened straight onto a band label,
  /// with nothing naming the screen.
  final String title;
  final String description;
  final String firstLabel;
  final Widget first;
  final String secondLabel;
  final Widget second;

  /// Optional third pane. Two was enough until `focus-model` turned out to be
  /// declared as merging into Autofocus without ever being mounted there.
  final String? thirdLabel;
  final Widget? third;

  @override
  Widget build(BuildContext context) {
    final third = this.third;
    final colors = SkotiqColors.of(context);
    final headerPadding = isMobile
        ? SkotiqTokens.paddingLg
        : EdgeInsets.fromLTRB(
            settingsPagePadding.left,
            settingsPagePadding.top,
            settingsPagePadding.right,
            SkotiqTokens.spaceLg,
          );
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The same title + one-line context every other settings page has.
          Padding(
            padding: headerPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SkotiqTypography.sectionTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  description,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          _SubHeader(label: firstLabel, isMobile: isMobile),
          first,
          _SubHeader(
              label: secondLabel, isMobile: isMobile, withTopBorder: true),
          second,
          if (third != null) ...[
            _SubHeader(
                label: thirdLabel ?? '',
                isMobile: isMobile,
                withTopBorder: true),
            third,
          ],
        ],
      ),
    );
  }
}

/// A labelled band that introduces one of the two stacked pages.
class _SubHeader extends StatelessWidget {
  const _SubHeader({
    required this.label,
    required this.isMobile,
    this.withTopBorder = false,
  });

  final String label;
  final bool isMobile;
  final bool withTopBorder;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? SkotiqTokens.space2xl : 32,
        vertical: SkotiqTokens.spaceMd,
      ),
      decoration: BoxDecoration(
        color: colors.well,
        border: Border(
          top: withTopBorder
              ? BorderSide(color: colors.border)
              : BorderSide.none,
          bottom: BorderSide(color: colors.border),
        ),
      ),
      child: Text(
        label,
        style: SkotiqTypography.overline.copyWith(
          color: colors.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// Files & Storage = file paths + auto-save (keys `file-paths` + `auto-save`).
class FilesAndStorageSettings extends StatelessWidget {
  const FilesAndStorageSettings({super.key, this.isMobile = false});

  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    return _MergedSection(
      isMobile: isMobile,
      title: 'Files & storage',
      description:
          'Where Skotiq writes captures, and how it backs your settings up.',
      firstLabel: 'FILE PATHS',
      first: FilePathSettings(isMobile: isMobile, embedded: true),
      secondLabel: 'AUTO-SAVE & BACKUPS',
      second: AutoSaveSettings(isMobile: isMobile, embedded: true),
    );
  }
}

/// Autofocus = autofocus + predictive AF + focus model
/// (keys `autofocus` + `predictive-af` + `focus-model`).
///
/// `focus-model` was in [kMergedSectionAliases] pointing here from the start,
/// and `kSettingsSectionIndex` lists it, but nothing ever mounted
/// [FocusModelSettings] — repo-wide its only references were its own
/// declaration. So a whole settings screen shipped with no route into it, and
/// the deep link resolved to an Autofocus pane that did not contain it. The
/// pane is remote-only and says so off-network, which matches how the other
/// appliance-backed sections behave rather than hiding itself.
class AutofocusMergedSettings extends StatelessWidget {
  const AutofocusMergedSettings({super.key, this.isMobile = false});

  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    return _MergedSection(
      isMobile: isMobile,
      title: 'Autofocus',
      description:
          'When Skotiq refocuses, how it predicts drift, and the focus '
          'model it learns.',
      firstLabel: 'AUTOFOCUS',
      first: AutofocusSettingsPage(isMobile: isMobile, embedded: true),
      secondLabel: 'PREDICTIVE AUTOFOCUS',
      second: PredictiveAfSettingsPage(isMobile: isMobile, embedded: true),
      thirdLabel: 'FOCUS MODEL',
      third: FocusModelSettings(isMobile: isMobile, embedded: true),
    );
  }
}
