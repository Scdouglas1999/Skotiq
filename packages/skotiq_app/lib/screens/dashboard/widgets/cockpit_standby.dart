import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../sequencer/widgets/smart_night_dialog.dart';
import 'smart_night_prompt_card.dart'
    show
        floatingPromptReservedHeightProvider,
        smartNightAutoPromptShowingProvider;
import 'standby/last_night_recap_card.dart';
import 'standby/moon_card.dart';
import 'standby/night_timeline.dart';
import 'standby/readiness_card.dart';
import 'standby/tonight_targets_card.dart';

/// Full-canvas **Night Briefing** shown on the Dashboard when nothing is
/// running.
///
/// The Dashboard doubles as the app home screen. Instead of a tiny "No run
/// active" placeholder floating in an empty canvas, the idle state is the
/// screen an astrophotographer wants before a session: a night timeline
/// (sunset → sunrise with the imaging window and a live "now" marker), the
/// moon, tonight's ranked targets, last night's recap, and an equipment +
/// storage readiness glance.
///
/// The branch that chooses standby vs. the live cockpit lives in
/// `dashboard_screen.dart`; this widget assumes it is only built while idle.
///
/// Layout is responsive: a centred max-width column on wide screens with a
/// two-column card grid beneath the full-width timeline; everything stacks into
/// one scroll column on phone widths. The whole briefing is wrapped in a scroll
/// view so it never overflows on small landscape phones.
class CockpitStandby extends ConsumerWidget {
  final SkotiqColors colors;

  const CockpitStandby({super.key, required this.colors});

  /// Below this the grid collapses to a single column and the header CTAs wrap.
  static const double _wideBreakpoint = 1100;
  static const double _maxContentWidth = 1180;

  /// Below this the live (clock-driven) astronomy widgets — the night timeline
  /// and the moon disc — are omitted. They watch skotiq_planetarium's
  /// `observationTimeProvider`, which spins up a 1 s clock the moment it is
  /// read; the dashboard command bar gates its own clock content on the same
  /// 900 px threshold, so standby follows suit. This keeps the briefing
  /// consistent on narrow phones (where a full timeline wouldn't fit anyway)
  /// and avoids leaking the clock into the cockpit-polish widget tests, which
  /// render standby at a compact width.
  static const double _liveAstroBreakpoint = 900;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;
        final liveAstro = constraints.maxWidth >= _liveAstroBreakpoint;
        // The floating "Build tonight's plan?" nudge is painted OVER this
        // briefing, and a floating overlay has to be paid for in the scroll
        // view it floats above. Standby scrolls here, not in
        // `DashboardScrollView`, so the reserve belongs here.
        final promptBand = ref.watch(floatingPromptReservedHeightProvider);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(SkotiqTokens.space2xl).add(
            EdgeInsets.only(bottom: promptBand),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child:
                  _Briefing(colors: colors, wide: wide, liveAstro: liveAstro),
            ),
          ),
        );
      },
    );
  }
}

/// One-shot fade/slide entrance, then static. Nothing loops — only the watched
/// observation-time tick drives the timeline's repaints.
class _Briefing extends StatefulWidget {
  final SkotiqColors colors;
  final bool wide;
  final bool liveAstro;

  const _Briefing({
    required this.colors,
    required this.wide,
    required this.liveAstro,
  });

  @override
  State<_Briefing> createState() => _BriefingState();
}

class _BriefingState extends State<_Briefing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: SkotiqTokens.durationSlow,
    )..forward();
    _fade = CurvedAnimation(
      parent: _controller,
      curve: SkotiqTokens.curveStandard,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.015),
      end: Offset.zero,
    ).animate(_fade);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(colors: colors, wide: widget.wide),
            const SizedBox(height: SkotiqTokens.spaceLg),
            if (widget.liveAstro) ...[
              NightTimeline(colors: colors),
              const SizedBox(height: SkotiqTokens.spaceLg),
            ],
            _CardGrid(
              colors: colors,
              wide: widget.wide,
              liveAstro: widget.liveAstro,
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  final SkotiqColors colors;
  final bool wide;

  const _Header({required this.colors, required this.wide});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.text('dbBriefingOverline'),
          style:
              SkotiqTypography.overline.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              l10n.text('dbNoRunActive'),
              style:
                  SkotiqTypography.h3.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Flexible(
              child: Text(
                _today(context, ref.watch(clockProvider)),
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );

    final ctas = _Ctas(colors: colors);

    // Wide: title left, CTAs right on one row. Narrow: stack so the buttons
    // get full width and never overflow on a landscape phone.
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: title),
          const SizedBox(width: SkotiqTokens.spaceLg),
          ctas,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        const SizedBox(height: SkotiqTokens.spaceMd),
        ctas,
      ],
    );
  }

  /// Today's date in the reader's language. The hard-coded English
  /// abbreviation tables this replaced also read `DateTime.now()`, so the
  /// briefing dated itself on the host rather than on the site the operator
  /// chose in Settings → Location → Timezone.
  static String _today(BuildContext context, Clock clock) {
    // MaterialLocalizations, not intl's DateFormat: the Global*Localizations
    // delegates the app already installs guarantee this locale's date symbols
    // are loaded, while a bare DateFormat('…', 'es') throws unless
    // initializeDateFormatting has been called.
    return MaterialLocalizations.of(context).formatMediumDate(clock.now());
  }
}

class _Ctas extends ConsumerWidget {
  final SkotiqColors colors;

  const _Ctas({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // One primary action. "Image tonight" launches the opinionated one-tap
    // auto-imaging flow; "Plan Tonight" is the quiet ghost that opens the
    // Smart Night wizard so you build a plan you can see and edit. Same verb
    // ("Plan Tonight") as every other Smart Night entrance in the app, with a
    // tooltip that says how it differs from the one-tap primary.
    //
    // Suppress this ghost while the floating Smart Night auto-prompt is on
    // screen: that prompt is already a louder "Plan Tonight" affordance, so
    // showing both at once is a redundant double-CTA. The primary "Image
    // tonight" stays; the prompt remains the plan-it path until dismissed.
    final l10n = context.l10n;
    final autoPromptShowing = ref.watch(smartNightAutoPromptShowingProvider);
    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SkotiqButton(
          label: l10n.text('dbImageTonight'),
          icon: LucideIcons.moonStar,
          variant: ButtonVariant.primary,
          onPressed: () => context.go('/tonight'),
        ),
        if (!autoPromptShowing)
          Tooltip(
            message: l10n.text('dbPlanTonightTooltip'),
            child: SkotiqButton(
              label: l10n.text('dbPlanTonight'),
              icon: LucideIcons.sparkles,
              variant: ButtonVariant.ghost,
              onPressed: () => showSmartNightDialog(context),
            ),
          ),
      ],
    );
  }
}

/// The four briefing cards. Wide screens lay them out in two columns
/// (targets + moon on the left, recap + readiness on the right) using an
/// IntrinsicHeight-free Row of Expanded columns; narrow screens stack them.
class _CardGrid extends StatelessWidget {
  final SkotiqColors colors;
  final bool wide;
  final bool liveAstro;

  const _CardGrid({
    required this.colors,
    required this.wide,
    required this.liveAstro,
  });

  @override
  Widget build(BuildContext context) {
    // The moon disc watches the planetarium clock, so it's only shown alongside
    // the live timeline (>= 900 px). See `_liveAstroBreakpoint`.
    final moon = liveAstro ? MoonCard(colors: colors) : null;
    final targets = TonightTargetsCard(colors: colors);
    final recap = LastNightRecapCard(colors: colors);
    final readiness = ReadinessCard(colors: colors);

    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          targets,
          const SizedBox(height: SkotiqTokens.spaceLg),
          if (moon != null) ...[
            moon,
            const SizedBox(height: SkotiqTokens.spaceLg),
          ],
          recap,
          const SizedBox(height: SkotiqTokens.spaceLg),
          readiness,
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              targets,
              if (moon != null) ...[
                const SizedBox(height: SkotiqTokens.spaceLg),
                moon,
              ],
            ],
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceLg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              readiness,
              const SizedBox(height: SkotiqTokens.spaceLg),
              recap,
            ],
          ),
        ),
      ],
    );
  }
}
