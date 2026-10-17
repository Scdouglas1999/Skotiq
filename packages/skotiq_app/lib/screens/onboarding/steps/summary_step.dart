import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Summary + Save step.
///
/// Reviews the draft, lets the user name the profile, then commits it on
/// "Save profile". The Save action is wired in [OnboardingScreen]; here
/// we only render the review UI plus the name field.
class OnboardingSummaryStep extends ConsumerStatefulWidget {
  const OnboardingSummaryStep({super.key});

  @override
  ConsumerState<OnboardingSummaryStep> createState() =>
      _OnboardingSummaryStepState();
}

class _OnboardingSummaryStepState extends ConsumerState<OnboardingSummaryStep> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    final draft = ref.read(onboardingDraftProvider);
    _nameController = TextEditingController(
      text: draft.profileName ?? 'My First Rig',
    );
    // Push the seeded name into the draft so the Save action picks it up
    // even if the user never modifies the field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(onboardingDraftProvider).profileName == null ||
          ref.read(onboardingDraftProvider).profileName!.trim().isEmpty) {
        ref
            .read(onboardingDraftProvider.notifier)
            .setProfileName(_nameController.text);
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(onboardingDraftProvider);
    final colors = SkotiqColors.of(context);

    final imageScale = draft.imageScaleArcsecPerPixel;

    // The observing site lives in app settings (not the draft) because it is a
    // global observer setting. lat/lon both 0.0 is the "null island" default,
    // which we surface as "—" rather than a bogus 0/0 coordinate.
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
          const SectionTitle(
            icon: LucideIcons.clipboardCheck,
            title: 'Review and save',
          ),
          Text(
            'This creates your first equipment profile. You can edit any of '
            'these later.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          FormRow(
            label: 'Profile name',
            child: SkotiqTextField(
              controller: _nameController,
              hint: 'My First Rig',
              onChanged: (value) {
                ref
                    .read(onboardingDraftProvider.notifier)
                    .setProfileName(value);
              },
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _ReviewGroup(
            label: 'Equipment',
            rows: [
              ('Camera', draft.cameraName),
              ('Mount', draft.mountName),
              ('Focuser', draft.focuserName),
              ('Filter wheel', draft.filterWheelName),
              if (draft.filterNames.isNotEmpty)
                ('Filters', draft.filterNames.join(', ')),
              ('Guider', draft.guiderName),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _ReviewGroup(
            label: 'Optics',
            mono: true,
            rows: [
              (
                'Focal length',
                draft.focalLengthMm != null
                    ? '${draft.focalLengthMm!.toStringAsFixed(1)} mm '
                        '\u00d7 ${draft.reducerFactor.toStringAsFixed(2)}'
                    : null,
              ),
              (
                'Aperture',
                draft.apertureMm != null
                    ? '${draft.apertureMm!.toStringAsFixed(1)} mm'
                    : null,
              ),
              (
                'Image scale',
                imageScale != null
                    ? '${imageScale.toStringAsFixed(2)} "/px'
                    : null,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          // The camera-defaults step's set-points go straight into the
          // profile, so a review screen that omitted them was hiding a whole
          // step's worth of decisions from the last look the user gets before
          // the rig is created.
          _ReviewGroup(
            label: 'Capture',
            rows: [
              ('Capture defaults', _captureDefaults(draft)),
              ('Capture folder', draft.captureDirectory),
              ('Site', siteValue),
            ],
          ),
        ],
      ),
    );
  }

  /// The acquisition set-points as one line, listing only what is actually on
  /// record. Returns null (rendered "—") when the user supplied
  /// nothing, rather than printing invented gain/offset numbers the profile does
  /// not carry.
  static String? _captureDefaults(OnboardingDraft draft) {
    final parts = <String>[
      if (draft.defaultGain != null) 'gain ${draft.defaultGain}',
      if (draft.defaultOffset != null) 'offset ${draft.defaultOffset}',
      if (draft.defaultBinX != null || draft.defaultBinY != null)
        'bin ${draft.defaultBinX ?? 1}×${draft.defaultBinY ?? 1}',
      if (draft.defaultCoolingTempC != null)
        '${draft.defaultCoolingTempC!.toStringAsFixed(0)} °C',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// One labelled block of the review: an eyebrow over key/value rows, in a
/// `well` inside the step panel.
///
/// A value the user never supplied renders as an em dash in muted type, never
/// as a sentence pretending to be a value.
class _ReviewGroup extends StatelessWidget {
  const _ReviewGroup({
    required this.label,
    required this.rows,
    this.mono = false,
  });

  final String label;

  /// Key/value pairs in reading order; a null value renders "—".
  final List<(String, String?)> rows;

  /// True when the values are measurements and take the mono ramp.
  final bool mono;

  /// Width of the key column.
  static const double _keyWidth = 132;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      decoration: SkotiqDecorations.well(colors),
      padding: SkotiqTokens.paddingMd,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: SkotiqTypography.eyebrow.copyWith(
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          for (final (key, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: SkotiqTokens.spaceXs / 2,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _keyWidth,
                    child: Text(
                      key,
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(
                    child: Text(
                      value == null || value.trim().isEmpty ? '—' : value,
                      style: value == null || value.trim().isEmpty
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
            ),
        ],
      ),
    );
  }
}
