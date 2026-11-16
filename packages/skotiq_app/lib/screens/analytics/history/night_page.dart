import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../router/analytics_route.dart';
import '../../../utils/darkroom_navigation.dart';
import '../../../utils/exported_file_reveal.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/run_status/run_status_presentation.dart';
import '../../sequencer/widgets/continue_run_button.dart';
import '../../sequencer/widgets/sequence_diff_dialog.dart';
import '../../sequencer/widgets/session_report_dialog.dart';
import '../analytics_exports.dart';
import 'night_entry.dart';
import 'night_views/frames_view.dart';
import 'night_views/review_view.dart';
import 'night_views/run_log_view.dart';
import 'night_views/summary_view.dart';

/// What each [NightView] is called on the page.
String nightViewLabel(NightView view) => switch (view) {
      NightView.summary => 'Summary',
      NightView.frames => 'Frames',
      NightView.log => 'Run log',
      NightView.report => 'Report',
      NightView.workbench => 'Workbench',
    };

/// One night of History as a page: what happened ([NightView.summary]), its
/// frames, the run's log, and the review of its subs and masters.
class NightPage extends ConsumerStatefulWidget {
  const NightPage({
    super.key,
    required this.night,
    required this.view,
    required this.onViewPicked,
    required this.onBack,
  });

  final NightRef night;

  /// The view the location asks for; null opens Summary.
  final NightView? view;
  final ValueChanged<NightView> onViewPicked;

  /// Returns to the History list.
  final VoidCallback onBack;

  @override
  ConsumerState<NightPage> createState() => _NightPageState();
}

class _NightPageState extends ConsumerState<NightPage> {
  /// Why the last action could not do what it offered.
  String? _refusal;

  @override
  void didUpdateWidget(NightPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.night != widget.night) _refusal = null;
  }

  NightEntry? _find(List<NightEntry> entries) {
    for (final entry in entries) {
      if (widget.night.sessionId != null &&
          entry.session?.id == widget.night.sessionId) {
        return entry;
      }
      if (widget.night.runId != null && entry.run?.id == widget.night.runId) {
        return entry;
      }
    }
    return null;
  }

  Future<void> _openInDarkroom(int sessionId) async {
    setState(() => _refusal = null);
    final target = await resolveDarkroomTargetForSession(ref, sessionId);
    if (!mounted) return;
    final masterId = target.masterId;
    if (masterId == null) {
      // The button was built on an older read of the night's masters.
      ref.invalidate(darkroomSessionTargetProvider(sessionId));
      setState(() => _refusal = target.unavailableReason);
      return;
    }
    openDarkroomForMaster(context, masterId);
  }

  Future<void> _export(
    int sessionId,
    SessionExportFormat format, {
    required String subject,
  }) async {
    try {
      final path = await ref
          .read(analyticsExportsProvider)
          .sessionExport(sessionId, format);
      if (!mounted) return;
      await revealExportedFile(context, path, subject: subject);
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Export failed: ${userFacingError(e)}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(allSessionsProvider);
    final runsAsync = ref.watch(sequenceRunsProvider);
    final error = sessionsAsync.error ?? runsAsync.error;
    if (error != null) {
      return EmptyState.error(
        title: 'This night did not load',
        body: userFacingError(error),
        onRetry: () {
          ref.invalidate(allSessionsProvider);
          ref.invalidate(sequenceRunsProvider);
        },
      );
    }
    final sessions = sessionsAsync.valueOrNull;
    final runs = runsAsync.valueOrNull;
    if (sessions == null || runs == null) {
      return const Center(
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
      );
    }
    final entry = _find(pairNightEntries(sessions, runs));
    if (entry == null) {
      return EmptyState(
        icon: LucideIcons.searchX,
        title: 'This night is not on record',
        body: 'It may have been deleted, or the link came from another '
            "computer's history.",
        action: SkotiqButton(
          label: 'Back to History',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: widget.onBack,
        ),
      );
    }

    final session = entry.session;
    final run = entry.run;
    final views = [
      NightView.summary,
      if (session != null) NightView.frames,
      if (run != null) NightView.log,
      if (session != null) NightView.report,
      if (session != null) NightView.workbench,
    ];
    final view = views.contains(widget.view) ? widget.view! : NightView.summary;
    final targetName = session?.targetId == null
        ? null
        : ref
            .watch(allDbTargetsProvider)
            .valueOrNull
            ?.where((target) => target.id == session!.targetId)
            .firstOrNull
            ?.name;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < BreakpointTokens.breakpointPhone;
        final padding = compact
            ? SkotiqTokens.screenPaddingCompact
            : SkotiqTokens.screenPadding;
        final refusal = _refusal;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                padding.left - SkotiqTokens.spaceSm,
                SkotiqTokens.spaceMd,
                padding.right,
                0,
              ),
              child: _NightHeader(
                entry: entry,
                compact: compact,
                views: views,
                view: view,
                onViewPicked: widget.onViewPicked,
                onBack: widget.onBack,
                onOpenInDarkroom: _openInDarkroom,
                onExport: _export,
              ),
            ),
            if (refusal != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  padding.left,
                  SkotiqTokens.spaceMd,
                  padding.right,
                  0,
                ),
                child: SkotiqBanner(
                  key: const ValueKey('night_refusal'),
                  title: refusal,
                  onDismiss: () => setState(() => _refusal = null),
                ),
              ),
            Expanded(
              child: switch (view) {
                NightView.summary => NightSummaryView(
                    entry: entry,
                    targetName: targetName,
                    padding: padding,
                    compact: compact,
                  ),
                NightView.frames =>
                  NightFramesView(entry: entry, padding: padding),
                NightView.log => NightRunLogView(
                    entry: entry,
                    targetName: targetName,
                    padding: padding,
                  ),
                NightView.report => NightReviewView(
                    sessionId: session!.id,
                    workbench: false,
                  ),
                NightView.workbench => NightReviewView(
                    sessionId: session!.id,
                    workbench: true,
                  ),
              },
            ),
          ],
        );
      },
    );
  }
}

enum _NightMenu { report, diff, json, csv, html, share }

/// The night's name, date and outcome, the view switch, and what can be done
/// with the night.
class _NightHeader extends ConsumerWidget {
  const _NightHeader({
    required this.entry,
    required this.compact,
    required this.views,
    required this.view,
    required this.onViewPicked,
    required this.onBack,
    required this.onOpenInDarkroom,
    required this.onExport,
  });

  final NightEntry entry;
  final bool compact;
  final List<NightView> views;
  final NightView view;
  final ValueChanged<NightView> onViewPicked;
  final VoidCallback onBack;
  final ValueChanged<int> onOpenInDarkroom;
  final Future<void> Function(
    int sessionId,
    SessionExportFormat format, {
    required String subject,
  }) onExport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final session = entry.session;
    final run = entry.run;
    final name = entry.name ?? l10n.text('analyticsUnnamedSession');
    final started = entry.startedAt.toLocal();
    final ended = (session?.endTime ?? run?.endedAt)?.toLocal();
    final when = '${ClockFormat.weekdayMonthDayYear(started)} · '
        '${ClockFormat.hm(started)}'
        '${ended == null ? '' : ' to ${ClockFormat.hm(ended)}'}';
    final status = session != null
        ? SkotiqChip(
            label: sessionStatusLabel(session.status),
            tone: sessionStatusTone(session.status),
          )
        : SkotiqChip(
            label: runStatusTokenLabel(run!.status),
            tone: runStatusTone(run.runStatus),
          );

    final darkroomRefusal =
        session == null ? null : watchDarkroomSessionRefusal(ref, session.id);
    final reviewing = view == NightView.report || view == NightView.workbench;

    final actions = <Widget>[
      if (run != null)
        ContinueRunButton(
          sequenceName: run.sequenceName,
          startedAt: run.startedAt,
          endedAt: run.endedAt,
        ),
      if (reviewing && session != null)
        NightReviewActions(
          sessionId: session.id,
          workbench: view == NightView.workbench,
        )
      else if (session != null && !compact)
        _openInDarkroom(session.id, darkroomRefusal),
    ];
    final menu = _menu(context, ref, colors, darkroomRefusal);

    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SkotiqTypography.sectionTitle
                    .copyWith(color: colors.textPrimary),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            status,
          ],
        ),
        const SizedBox(height: ListRow.lineGap),
        Text(
          when,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
      ],
    );
    final back = SkotiqIconButton(
      icon: SkotiqIcons.arrowLeft,
      tooltip: 'Back to History',
      onPressed: onBack,
    );
    final switcher = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedControl(
        segments: [for (final view in views) nightViewLabel(view)],
        selectedIndex: views.indexOf(view),
        onSelected: (index) => onViewPicked(views[index]),
        semanticLabel: 'Night view',
      ),
    );
    Widget spaced(List<Widget> children) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final child in children) ...[
              const SizedBox(width: SkotiqTokens.spaceSm),
              child,
            ],
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            back,
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(child: title),
            if (!compact) spaced(actions),
            if (menu != null) menu,
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Padding(
          padding: const EdgeInsets.only(left: SkotiqTokens.spaceSm),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    switcher,
                    if (actions.isNotEmpty)
                      Padding(
                        padding:
                            const EdgeInsets.only(top: SkotiqTokens.spaceSm),
                        child: Wrap(
                          spacing: SkotiqTokens.spaceSm,
                          runSpacing: SkotiqTokens.spaceSm,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: actions,
                        ),
                      ),
                  ],
                )
              : switcher,
        ),
      ],
    );
  }

  /// The Darkroom on this night's master. A night with no master, and any
  /// night seen from a linked client, shows the button disabled with the
  /// reason in its tooltip and in its accessible name.
  Widget _openInDarkroom(int sessionId, String? refusal) {
    const label = 'Open in Darkroom';
    final button = SkotiqButton(
      key: const ValueKey('night_open_darkroom'),
      label: label,
      icon: SkotiqIcons.aperture,
      variant: ButtonVariant.ghost,
      size: ButtonSize.small,
      onPressed: refusal == null ? () => onOpenInDarkroom(sessionId) : null,
    );
    if (refusal == null) return button;
    return Tooltip(
      message: refusal,
      child: Semantics(
        container: true,
        button: true,
        enabled: false,
        label: unavailableControlName(label, refusal),
        excludeSemantics: true,
        child: button,
      ),
    );
  }

  /// Everything else the night can do, behind one named button; null when
  /// there is nothing else.
  Widget? _menu(
    BuildContext context,
    WidgetRef ref,
    SkotiqColors colors,
    String? darkroomRefusal,
  ) {
    final l10n = context.l10n;
    final session = entry.session;
    final run = entry.run;
    PopupMenuItem<T> item<T>(
      T value,
      IconData icon,
      String label, {
      String? unavailableReason,
    }) {
      final enabled = unavailableReason == null;
      final row = Row(
        children: [
          Icon(
            icon,
            size: SkotiqTokens.iconSm,
            color: enabled ? colors.textSecondary : colors.textMuted,
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Flexible(
            child: Text(
              label,
              style: SkotiqTypography.bodySm.copyWith(
                color: enabled ? colors.textPrimary : colors.textMuted,
              ),
            ),
          ),
        ],
      );
      return PopupMenuItem<T>(
        value: value,
        enabled: enabled,
        child: enabled
            ? row
            : Tooltip(
                message: unavailableReason,
                child: Semantics(
                  label: unavailableControlName(label, unavailableReason),
                  excludeSemantics: true,
                  child: row,
                ),
              ),
      );
    }

    final items = <PopupMenuEntry<Object>>[
      if (compact && session != null)
        item<Object>(
          #darkroom,
          SkotiqIcons.aperture,
          'Open in Darkroom',
          unavailableReason: darkroomRefusal,
        ),
      if (session != null)
        item<Object>(
          _NightMenu.report,
          LucideIcons.fileBarChart,
          'Session report',
        ),
      if (run?.sequenceId != null)
        item<Object>(
          _NightMenu.diff,
          LucideIcons.gitCompare,
          'Compare with the previous run',
        ),
      if (session != null) ...[
        item<Object>(
          _NightMenu.json,
          LucideIcons.fileJson,
          l10n.text('analyticsExportJson'),
        ),
        item<Object>(
          _NightMenu.csv,
          LucideIcons.fileSpreadsheet,
          l10n.text('analyticsExportCsv'),
        ),
        item<Object>(
          _NightMenu.html,
          LucideIcons.fileText,
          l10n.text('analyticsExportHtml'),
        ),
        // Share exists only where the OS has a share sheet.
        if (Platform.isAndroid || Platform.isIOS)
          item<Object>(_NightMenu.share, LucideIcons.share, l10n.text('share')),
      ],
    ];
    if (items.isEmpty) return null;

    return PopupMenuButton<Object>(
      key: const ValueKey('night_actions_menu'),
      tooltip: 'Night actions',
      color: colors.surfaceElevated,
      icon: Icon(
        SkotiqIcons.more,
        size: SkotiqTokens.iconRail,
        color: colors.textSecondary,
        semanticLabel: 'Night actions',
      ),
      onSelected: (choice) {
        if (choice == #darkroom) {
          onOpenInDarkroom(session!.id);
          return;
        }
        switch (choice as _NightMenu) {
          case _NightMenu.report:
            SessionReportDialog.show(context, session!.id, runId: run?.id);
          case _NightMenu.diff:
            SequenceDiffDialog.showForRun(context, ref, run: run!);
          case _NightMenu.json:
            onExport(
              session!.id,
              SessionExportFormat.json,
              subject: 'Skotiq session data',
            );
          case _NightMenu.csv:
            onExport(
              session!.id,
              SessionExportFormat.csv,
              subject: 'Skotiq session data',
            );
          case _NightMenu.html:
            onExport(
              session!.id,
              SessionExportFormat.html,
              subject: 'Skotiq session report',
            );
          case _NightMenu.share:
            onExport(
              session!.id,
              SessionExportFormat.csv,
              subject: 'Session data for ${entry.name ?? 'session'}',
            );
        }
      },
      itemBuilder: (context) => items,
    );
  }
}
