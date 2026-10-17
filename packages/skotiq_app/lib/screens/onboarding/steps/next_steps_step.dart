import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
// Outside the core barrel by design (name collision with
// `cameraPresetsProvider`); imported by source path, as the optics step does.
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'optical_train_step.dart';

/// Terminal "what's next" step shown after the equipment profile is created.
///
/// By the time this renders the rig already exists and is the active profile —
/// [OnboardingNotifier.complete] ran on the summary step. This step celebrates
/// that, summarizes the rig the user just built, and offers the three natural
/// next actions: capture first light, take the first-night walkthrough, or
/// review the readiness checklist.
///
/// Every action routes through [onNavigate], which retires the wizard
/// (marks the tutorial complete, wipes the draft, flips the bootstrap gate) and
/// then navigates. That keeps the "finish exactly once" logic in the wizard
/// shell rather than duplicating it per card.
class OnboardingNextStepsStep extends ConsumerWidget {
  const OnboardingNextStepsStep({super.key, required this.onNavigate});

  /// Finalizes onboarding and navigates to the given route. Supplied by
  /// [OnboardingScreen]; see [OnboardingNotifier.finishNextSteps].
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(onboardingDraftProvider);
    final colors = SkotiqColors.of(context);

    final profileName = (draft.profileName ?? '').trim().isNotEmpty
        ? draft.profileName!.trim()
        : 'My First Rig';
    final imageScale = draft.imageScaleArcsecPerPixel;

    // The observing site is a global setting, not part of the draft. lat/lon
    // both 0.0 is the "null island" default — treat that as "not set" so the
    // user gets nudged to fill it in.
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final siteSet = settings != null && settings.hasObserverLocation;
    final siteValue = siteSet
        ? '${settings.latitude.toStringAsFixed(4)}°, '
            '${settings.longitude.toStringAsFixed(4)}°'
        : null;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The step panel is the container; a card inside it would be a
          // panel inside a panel.
          const SectionTitle(
            icon: LucideIcons.rocket,
            title: "You're all set",
          ),
          Text(
            '$profileName is active and ready to image.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Container(
            decoration: SkotiqDecorations.well(colors),
            padding: SkotiqTokens.paddingMd,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your rig'.toUpperCase(),
                  style: SkotiqTypography.eyebrow.copyWith(
                    color: colors.textMuted,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                _SummaryLine(
                  label: 'Telescope',
                  // The optics step marks a library scope whose numbers were
                  // edited as "— edited". Carrying that marker here keeps the
                  // wizard's closing statement about the rig from pairing a
                  // model name with an image scale computed from a focal
                  // length that model does not have.
                  value: telescopeSummaryLabel(
                    draft,
                    ref.watch(hardwarePresetsServiceProvider).allTelescopes(),
                  ),
                ),
                _SummaryLine(label: 'Camera', value: draft.cameraName),
                _SummaryLine(
                  label: 'Image scale',
                  value: imageScale != null
                      ? '${imageScale.toStringAsFixed(2)} "/px'
                      : null,
                  mono: true,
                ),
                _SummaryLine(label: 'Site', value: siteValue),
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.space2xl),
          const SectionTitle(title: 'Where to next?'),
          _NextStepCard(
            icon: SkotiqIcons.sparkle,
            title: 'Capture your first light',
            subtitle:
                'Connect your camera and take your very first exposure, guided step by step.',
            onTap: () => onNavigate('/imaging?firstLight=1'),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _NextStepCard(
            icon: SkotiqIcons.book,
            title: 'Take the first-night walkthrough',
            subtitle:
                'A short tour of the imaging, sequencing, and guiding workflow.',
            onTap: () => onNavigate('/tutorial/first-night'),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _NextStepCard(
            icon: SkotiqIcons.checklist,
            title: 'Review readiness checklist',
            subtitle:
                'Confirm your gear connects and everything is configured before you head out.',
            onTap: () => onNavigate('/equipment'),
          ),
          // Only shown when the user skipped the site step. `/settings?section=
          // location` is the same deep link the weather screen uses to jump to
          // the location editor.
          if (!siteSet) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            _NextStepCard(
              icon: LucideIcons.mapPin,
              title: 'Set your observing site',
              subtitle:
                  'Your location powers Tonight, the planner, meridian flips, and the weather radar.',
              onTap: () => onNavigate('/settings?section=location'),
            ),
          ],
        ],
      ),
    );
  }
}

/// One labelled fact in the rig summary. An absent value renders as an em dash
/// in muted type rather than hiding the row, so the user sees the complete
/// shape of their profile.
class _SummaryLine extends StatelessWidget {
  const _SummaryLine({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String? value;

  /// True when the value is a measurement and takes the mono ramp.
  final bool mono;

  /// Width of the key column.
  static const double _keyWidth = 132;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final hasValue = value != null && value!.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: SkotiqTokens.spaceXs / 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _keyWidth,
            child: Text(
              label,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              hasValue ? value! : '\u2014',
              style: !hasValue
                  ? SkotiqTypography.bodySm.copyWith(
                      color: colors.textMuted,
                    )
                  : (mono
                          ? SkotiqTypography.readoutSm
                          : SkotiqTypography.bodySm)
                      .copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tappable next-step row: glyph + title + one line + chevron.
///
/// A row, not a card: a tappable container inside a panel is a row (05 §9),
/// and the icon takes `textMuted` rather than a per-row tint — status colours
/// mean status, and none of these four is a status.
class _NextStepCard extends StatefulWidget {
  const _NextStepCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<_NextStepCard> createState() => _NextStepCardState();
}

class _NextStepCardState extends State<_NextStepCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          label: '${widget.title}. ${widget.subtitle}',
          child: ExcludeSemantics(
            child: AnimatedContainer(
              duration: SkotiqTokens.durationFast,
              curve: SkotiqTokens.curveStandard,
              padding: SkotiqTokens.paddingMd,
              decoration: BoxDecoration(
                color: _hovered ? colors.surfaceHover : colors.well,
                borderRadius: SkotiqTokens.borderRadiusSm,
              ),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    color: colors.textMuted,
                    size: SkotiqTokens.iconMd,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: SkotiqTypography.bodyStrong.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          widget.subtitle,
                          style: SkotiqTypography.bodySm.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Icon(
                    SkotiqIcons.chevronRight,
                    size: SkotiqTokens.iconSm,
                    color: colors.textMuted,
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
