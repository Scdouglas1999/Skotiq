import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'depthlock_selection.dart';

/// `app_settings` key recording that the operator has dismissed the DepthLock
/// introduction, or created a goal and therefore does not need it.
///
/// An arbitrary settings key rather than a field on the typed settings model:
/// this is a one-shot piece of UI state, not a preference anyone will look for
/// in Settings, and it follows the same shape as `notes.prompt_after_run`.
const String kDepthLockHintDismissedKey = 'imaging.depthlock_hint_dismissed';

/// Whether the DepthLock introduction has already been shown and dismissed.
///
/// Defaults to false when the key has never been written — a fresh install
/// should see the hint once.
final depthLockHintDismissedProvider = StreamProvider<bool>((ref) {
  final dao = ref.watch(settingsDaoProvider);
  return dao.watchSetting(kDepthLockHintDismissedKey).map((raw) {
    if (raw == null) return false;
    return raw.toLowerCase() == 'true';
  });
});

/// Records the dismissal: in this app's settings, so it survives a restart,
/// and in the shared acknowledgments, so the other end of a link hides the
/// tip too.
final depthLockHintDismisserProvider = Provider<Future<void> Function()>((ref) {
  final dao = ref.watch(settingsDaoProvider);
  return () {
    _shareDismissal(ref);
    return dao.setSetting(kDepthLockHintDismissedKey, 'true');
  };
});

void _shareDismissal(Ref ref) {
  final acks = ref.read(noticeAcknowledgmentsProvider.notifier);
  acks.state = acks.state.dismissingTip(depthLockHintTipId);
}

/// Keeps the two records of the dismissal together. A dismissal stored in
/// this app's settings is shared with the other end of a link, and one that
/// arrives from there is stored here, so a restart on either end does not
/// bring the tip back.
final depthLockHintDismissalSyncProvider = Provider<void>((ref) {
  final dao = ref.watch(settingsDaoProvider);
  // Scheduled: a provider must not change another one while it is built.
  void reconcile() => Future.microtask(() {
        final stored = ref.read(depthLockHintDismissedProvider).valueOrNull;
        final shared = ref
            .read(noticeAcknowledgmentsProvider)
            .tipDismissed(depthLockHintTipId);
        if (stored == true && !shared) _shareDismissal(ref);
        if (shared && stored == false) {
          dao.setSetting(kDepthLockHintDismissedKey, 'true');
        }
      });
  ref.listen<AsyncValue<bool>>(
    depthLockHintDismissedProvider,
    (_, __) => reconcile(),
    fireImmediately: true,
  );
  ref.listen<bool>(
    noticeAcknowledgmentsProvider.select(
      (acks) => acks.tipDismissed(depthLockHintTipId),
    ),
    (_, __) => reconcile(),
    fireImmediately: true,
  );
});

/// Whether the DepthLock hint should be on screen right now.
///
/// Three conditions, all of them about whether the operator could act on it:
/// a frame that could anchor a region is displayed, no goal exists yet, and
/// they have not dismissed it before, in this window or in the other one of
/// a link. A hint that appears next to a goal the
/// operator already made is noise, and one that appears over an unsolvable
/// frame is an invitation to a dead end.
final depthLockHintVisibleProvider = Provider<bool>((ref) {
  ref.watch(depthLockHintDismissalSyncProvider);
  final shared = ref.watch(
    noticeAcknowledgmentsProvider.select(
      (acks) => acks.tipDismissed(depthLockHintTipId),
    ),
  );
  if (shared) return false;
  final dismissed = ref.watch(depthLockHintDismissedProvider).valueOrNull;
  if (dismissed ?? true) return false;
  final goals = ref.watch(depthLockGoalsProvider).valueOrNull;
  if (goals == null || goals.isNotEmpty) return false;
  return ref.watch(depthLockSelectionProvider).canSelect;
});

/// The one-time introduction, as a dismissable strip above the canvas.
///
/// It takes no room at all once dismissed, and it is a banner rather than a
/// toast because it is an offer the operator may want to sit with for a
/// moment rather than a notice that has already happened.
class DepthLockHint extends ConsumerWidget {
  const DepthLockHint({super.key, this.onMarkRegion});

  /// Enters the region tool. Null renders the hint without its action, which
  /// is what a layout with no tool to enter should do.
  final VoidCallback? onMarkRegion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(depthLockHintVisibleProvider)) {
      return const SizedBox.shrink();
    }
    Future<void> dismiss() => ref.read(depthLockHintDismisserProvider)();

    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      child: SkotiqBanner(
        title: 'Chasing something faint?',
        message: 'Mark it and Skotiq will keep track of how much deeper it '
            'still needs to go.',
        tone: BannerTone.info,
        icon: SkotiqIcons.target,
        action: onMarkRegion == null
            ? null
            : SkotiqButton(
                label: 'Mark a region',
                icon: SkotiqIcons.crosshair,
                size: ButtonSize.small,
                variant: ButtonVariant.secondary,
                onPressed: () {
                  // Taking the offer is also an answer: the hint has done its
                  // job and must not come back on the next frame.
                  dismiss();
                  onMarkRegion!();
                },
              ),
        onDismiss: dismiss,
      ),
    );
  }
}
