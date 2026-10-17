/// The ONE place an autofocus launch is intercepted to offer a backlash
/// measurement.
///
/// Four surfaces start autofocus (the focuser control strip, the imaging focus
/// panel, the dashboard quick action and the focus-model card's empty state).
/// The interception lives here so the offer cannot drift into four different
/// promises, and so there is one place to read what it does.
///
/// The rules it enforces:
///   * The offer is an OFFER. Declining runs the focus operation immediately —
///     it must never block an imaging run.
///   * "Skip and focus now" and "Don't ask again" are different promises and
///     are never conflated. The first is one session, the second is persisted
///     through `declineOffer(never: true)`.
///   * Nothing is offered unless a focuser is connected and
///     [focuserBacklashOfferProvider] says a measurement is due, so app launch
///     with no hardware is silent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'focuser_backlash_calibration_dialog.dart';

/// Runs [proceed], offering the backlash measurement first if one is due.
///
/// Returns when [proceed] has completed, exactly as calling it directly would,
/// so a caller's in-flight/finally bookkeeping is unchanged.
Future<void> runWithBacklashOffer(
  BuildContext context,
  WidgetRef ref, {
  required Future<void> Function() proceed,
}) async {
  await offerBacklashCalibrationIfDue(context, ref);
  await proceed();
}

/// Makes the offer if one is due, then returns so the caller can proceed.
///
/// The seam for callers whose own in-flight bookkeeping straddles the launch
/// (the dashboard quick action holds an operation generation across it) and
/// which therefore cannot hand the run over as a closure. Same offer, same
/// promises; the caller re-checks `mounted` afterwards as it would across any
/// await.
Future<void> offerBacklashCalibrationIfDue(
  BuildContext context,
  WidgetRef ref,
) async {
  if (!shouldOfferBacklashCalibration(ref)) return;

  final offers = ref.read(focuserBacklashOfferSessionProvider.notifier);
  final choice = await FocuserBacklashOfferDialog.show(context);

  // The launching surface can go away while the offer is open (screen change,
  // device disconnect). The focus operation itself does not need the context,
  // but opening the wizard does.
  if (choice == BacklashOfferChoice.measureFirst && context.mounted) {
    await FocuserBacklashCalibrationDialog.show(context);
    // Nothing saved means the measurement was refused, cancelled or discarded.
    // Offering again on the very next focus attempt of the same session would
    // be nagging; the offer comes back next session, or from the Equipment
    // screen whenever they want it.
    if (!ref.read(focuserBacklashCalibrationProvider).isSaved) {
      await offers.declineOffer(never: false);
    }
  } else {
    // Barrier dismissal and Escape carry the mildest promise available, the
    // same as skipping: they are not a permanent opt-out.
    await offers.declineOffer(never: choice == BacklashOfferChoice.never);
  }
}

/// Whether the offer should be made right now.
///
/// [focuserBacklashOfferProvider] owns the whole decision — never measured, not
/// opted out, focuser AND camera connected, not already waved away this session
/// — which is what keeps a first launch with no hardware silent. Read through
/// this one function so every launch surface asks the same question.
bool shouldOfferBacklashCalibration(WidgetRef ref) =>
    ref.read(focuserBacklashOfferProvider);

enum BacklashOfferChoice {
  /// Measure now; the focus operation follows immediately afterwards.
  measureFirst,

  /// Not this time. The offer may come back.
  skip,

  /// Persisted opt-out.
  never,
}

/// The offer itself.
///
/// Resolves to null when dismissed by the barrier or Escape, which
/// [runWithBacklashOffer] treats as [BacklashOfferChoice.skip].
class FocuserBacklashOfferDialog extends ConsumerWidget {
  const FocuserBacklashOfferDialog({super.key});

  static Future<BacklashOfferChoice?> show(BuildContext context) {
    return showDialog<BacklashOfferChoice>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const FocuserBacklashOfferDialog(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final effective = ref.watch(effectiveFocuserBacklashProvider);

    return SkotiqDialog(
      title: 'Measure backlash first?',
      icon: LucideIcons.gitCompare,
      width: 560,
      actions: [
        SkotiqButton(
          label: "Don't ask again",
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(context).pop(BacklashOfferChoice.never),
        ),
        SkotiqButton(
          label: 'Skip and focus now',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(context).pop(BacklashOfferChoice.skip),
        ),
        SkotiqButton(
          label: 'Measure first',
          icon: LucideIcons.gauge,
          size: ButtonSize.small,
          onPressed: () =>
              Navigator.of(context).pop(BacklashOfferChoice.measureFirst),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SkotiqBanner(
            tone: BannerTone.info,
            title: 'A perfect-looking curve can still land on donuts.',
            message:
                'Autofocus samples the curve moving one way, then makes its '
                'final move — often the other way. If your focuser has '
                'backlash and Skotiq does not know it, that last move '
                'lands short of focus even though every sampled point was '
                'good. Measuring it takes a few minutes, once.',
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Text(
            effective.hasFigure
                ? 'Right now autofocus compensates ${effective.steps} steps, '
                    '${effective.provenance}.'
                : 'Backlash compensation is off: ${effective.provenance}.',
            style: SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Text(
            'Measuring first runs the focus operation you asked for straight '
            'afterwards. Skipping focuses now and leaves the offer for next '
            "time; \"Don't ask again\" stops it for good — you can still "
            'measure from the Equipment screen whenever you want.',
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}
