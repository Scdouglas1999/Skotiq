/// How the rest of the app opens the Darkroom.
///
/// The `/darkroom` route is scoped by ONE of two query parameters — `recipe`
/// for a saved recipe row and `master` for a linear master whose newest recipe
/// should be loaded. Every entry point goes through the builders here so the
/// parameter names live in one place: a link written by hand somewhere else
/// would resolve to the screen's empty state without ever saying why.
///
/// Screens that only hold a session id resolve it with
/// [resolveDarkroomTargetForSession], which reads the session's masters the
/// same way the dawn autopilot does and answers with the reason when there is
/// nothing to open. A "refine this" control that silently opened an empty
/// editor would be the cry-wolf defect class.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../screens/darkroom/darkroom_route.dart';
import 'snackbar_helper.dart';

export '../screens/darkroom/darkroom_route.dart' show DarkroomTab;

/// The Darkroom location for a saved recipe row.
String darkroomRecipeLocation(int recipeId) => '/darkroom?recipe=$recipeId';

/// The Darkroom location for a linear master; the screen loads its newest
/// recipe, or offers to compose one when the master has none.
String darkroomMasterLocation(int masterId) => '/darkroom?master=$masterId';

/// The Darkroom location for a pass, live while it runs and its record after.
String darkroomPassLocation(String runId) =>
    '/darkroom?pass=${Uri.encodeQueryComponent(runId)}';

/// The Darkroom opened on one of its tabs.
String darkroomTabLocation(DarkroomTab tab) => DarkroomRoute(tab: tab).location;

/// The Targets tab with [target] selected. [target] is the key the build
/// jobs use (`DarkroomBuildJob.target`).
String darkroomTargetLocation(String target) =>
    DarkroomRoute(target: target).location;

/// The framing check of [target]'s master build.
String darkroomFramingLocation(String target) => DarkroomRoute(
      target: target,
      view: DarkroomTargetView.framing,
    ).location;

/// The Edit tab opened on a registered image or a saved recipe.
String darkroomEditLocation({int? masterId, int? recipeId}) => DarkroomRoute(
      tab: DarkroomTab.edit,
      masterId: masterId,
      recipeId: recipeId,
    ).location;

/// The one sentence every Darkroom entry point refuses a remote client with.
///
/// Shared rather than repeated so two controls cannot answer the same question
/// in two different ways: the session-level "Refine in Darkroom" explained
/// itself inline while the master card's "Darkroom" navigated into the
/// host-only screen, and an operator pressing both learned two different things
/// about the same machine.
const String kDarkroomHostOnlyRefusal =
    'The Darkroom works on the imaging host, where the linear masters are '
    'stored. Open Skotiq there to refine this night.';

/// Why this machine cannot open the Darkroom, or null when it can.
///
/// Gated on the client ROLE ([isRemoteClientProvider]), not on the connection:
/// a desktop launched with `--remote-host` that has not reached its rig is
/// `Disconnected`, so `backend is NetworkBackend` reads false for the whole
/// pre-handshake window and after every drop — and during exactly that window
/// the client owns none of the host's masters.
String? darkroomHostOnlyRefusal(WidgetRef ref) =>
    ref.read(isRemoteClientProvider) ? kDarkroomHostOnlyRefusal : null;

/// The accessible NAME for a control [label] that is disabled for [reason].
///
/// The refusal has to be IN the name. Flutter's `tooltip:` publishes
/// `SemanticsProperties.tooltip`, and the Linux AT-SPI bridge does not fold
/// that into the accessible name, so a reason carried only by a tooltip
/// reaches a pointer and nothing else: the session dialog's Darkroom action
/// read `Refine on imaging host [DISABLED]` to a screen reader while the hover
/// tooltip carried the whole sentence, and the header buttons are icon-only,
/// so there was no visible reason either. The tooltip stays — it is what a
/// mouse user gets — and the same words go in the name for everyone else.
///
/// The em dash is the separator the rest of this build already uses for the
/// same job (`Compare — <reason>`, `Move Crop up — it is already first in the
/// stack (1 of 4)`), so the whole app states a refusal one way.
String unavailableControlName(String label, String reason) =>
    '$label — $reason';

/// [darkroomHostOnlyRefusal] for a control that is being BUILT rather than
/// pressed: the same answer, watched so the control follows the role.
///
/// Every Darkroom entry point asked the question inside its tap handler, so on
/// a remote client each of them was drawn live — full contrast, focusable,
/// nothing in the accessibility tree saying otherwise — and answered only after
/// the operator committed to the press. A control that looks available and then
/// refuses is the cry-wolf shape: it teaches the operator that the app's
/// enabled state means nothing. The refusal belongs ON the control, as its
/// disabled reason, before anybody reaches for it.
///
/// `watch`, not `read`: a control built while the role answer is one thing has
/// to be rebuilt when it becomes another — a desktop that is handed
/// `--remote-host` mid-session must not leave a live-looking button behind.
///
/// The after-press path in [openDarkroomForMasterRow] and
/// [openDarkroomForSession] stays, because a deep link — a notification tap, a
/// hand-typed route — reaches the Darkroom with no control to have disabled.
String? watchDarkroomHostOnlyRefusal(WidgetRef ref) =>
    ref.watch(isRemoteClientProvider) ? kDarkroomHostOnlyRefusal : null;

/// Push the Darkroom scoped to [masterId].
///
/// The raw push. Callers must have asked [darkroomHostOnlyRefusal] — directly
/// or through [resolveDarkroomTargetForSession] — before reaching it;
/// [openDarkroomForMasterRow] is the entry point that does both.
void openDarkroomForMaster(BuildContext context, int masterId) {
  context.push(darkroomMasterLocation(masterId));
}

/// Open the Darkroom on [masterId] from a control that names the master row
/// itself, or refuse where the operator pressed.
///
/// The master library's "Darkroom" button called [openDarkroomForMaster]
/// directly, so on a client it navigated into the host-only screen while the
/// session-level control on the same launch refused inline. One resolver, one
/// behaviour: no Darkroom control on a client lands on a gate screen.
void openDarkroomForMasterRow(
  BuildContext context,
  WidgetRef ref,
  int masterId,
) {
  final refusal = darkroomHostOnlyRefusal(ref);
  if (refusal != null) {
    context.showInfoSnackBar(refusal);
    return;
  }
  openDarkroomForMaster(context, masterId);
}

/// What a session resolves to for the Darkroom: a master to open, or the
/// sentence explaining why the night has none.
///
/// Exactly one of the two is non-null, so a caller cannot navigate and explain
/// at the same time.
class DarkroomSessionTarget {
  /// The `integrated_masters.id` to open, or null when there is none.
  final int? masterId;

  /// Why the session cannot be opened, in the words the user reads.
  final String? unavailableReason;

  const DarkroomSessionTarget.master(int this.masterId)
      : unavailableReason = null;

  const DarkroomSessionTarget.unavailable(String this.unavailableReason)
      : masterId = null;
}

/// Resolve the linear master the Darkroom should open for [sessionId].
///
/// The resolution is the dawn autopilot's own ([DawnMasterResolver]), so the
/// master this opens is the master the night's draft was made from rather than
/// a second, differently-derived answer to the same question.
///
/// Host-only by construction: the resolver reads the local database and the
/// master's pixels live on the imaging host's disk, so a remote client is told
/// where to open it instead of being handed a path it cannot read.
///
/// The refusal is [darkroomHostOnlyRefusal] — the same words, from the same
/// role question, that every other Darkroom entry point uses.
///
/// This is the AFTER-PRESS form, for a deep link and for the moment of the tap.
/// A control that is being BUILT asks [watchDarkroomSessionRefusal] instead, so
/// the same answer is on it before anybody reaches for it.
Future<DarkroomSessionTarget> resolveDarkroomTargetForSession(
  WidgetRef ref,
  int sessionId,
) {
  return _resolveDarkroomTarget(
    refusal: darkroomHostOnlyRefusal(ref),
    resolver: ref.read(dawnMasterResolverProvider),
    sessionId: sessionId,
  );
}

/// [resolveDarkroomTargetForSession] for a control being built.
///
/// One provider so the answer painted on the control and the answer the press
/// acts on come from the same resolution, and `autoDispose` so a night that has
/// since been integrated is re-read the next time a control asks rather than
/// carrying a stale refusal for the life of the process.
final darkroomSessionTargetProvider = FutureProvider.autoDispose
    .family<DarkroomSessionTarget, int>((ref, sessionId) {
  return _resolveDarkroomTarget(
    refusal:
        ref.watch(isRemoteClientProvider) ? kDarkroomHostOnlyRefusal : null,
    resolver: ref.watch(dawnMasterResolverProvider),
    sessionId: sessionId,
  );
});

/// What a session-scoped Darkroom control says instead of opening, or null when
/// it can open.
///
/// Both predicates, on the control, before the press. The ROLE half was already
/// answered here by [watchDarkroomHostOnlyRefusal]; the MASTER half was asked
/// only inside the tap handler, so on a night that was never integrated the
/// control was drawn live — full contrast, focusable, nothing in the
/// accessibility tree saying otherwise — and the sentence explaining that there
/// is nothing to open arrived after the operator had committed to the press.
/// That is the cry-wolf shape this library exists to name, one predicate short.
///
/// The role is answered FIRST and short-circuits: a client owns none of the
/// host's masters, so reading its own database to find out would answer a
/// question about the wrong machine.
///
/// While the read is in flight the control is disabled and says so. "Not yet
/// known" is not "available": a control enabled on the way to an answer is
/// live for exactly as long as it would take to press it wrongly.
String? watchDarkroomSessionRefusal(WidgetRef ref, int sessionId) {
  final role = watchDarkroomHostOnlyRefusal(ref);
  if (role != null) return role;
  return switch (ref.watch(darkroomSessionTargetProvider(sessionId))) {
    AsyncData(:final value) => value.unavailableReason,
    AsyncError(:final error) =>
      'This session\'s masters could not be read: $error',
    _ => kDarkroomMastersReadingReason,
  };
}

/// What a session-scoped Darkroom control reads while its masters are being
/// read.
const String kDarkroomMastersReadingReason =
    'Reading this night\'s masters — the Darkroom opens as soon as they '
    'answer.';

/// The one resolution both entry points run.
///
/// Written once so the control's disabled reason and the sentence a press
/// produces cannot drift into two different accounts of the same night.
Future<DarkroomSessionTarget> _resolveDarkroomTarget({
  required String? refusal,
  required DawnMasterResolver resolver,
  required int sessionId,
}) async {
  if (refusal != null) {
    return DarkroomSessionTarget.unavailable(refusal);
  }

  final DawnMasterSet set;
  try {
    set = await resolver.resolve(sessionId);
  } catch (error) {
    return DarkroomSessionTarget.unavailable(
      'This session\'s masters could not be read: $error',
    );
  }

  if (set.masters.isNotEmpty) {
    // The resolver lists a master holding a color composite first, so a
    // night whose filters were combined opens on its color draft.
    return DarkroomSessionTarget.master(set.masters.first.masterId);
  }

  // Name the reason the resolver gave when it has one: a master that is still
  // accumulating has grown without writing a FITS, which is a different problem
  // from a night that was never integrated at all.
  final blocked = set.withoutFile.isEmpty ? null : set.withoutFile.first;
  return DarkroomSessionTarget.unavailable(
    blocked == null
        ? 'This session has no integrated master yet. Integrate it in Session '
            'Review first, then refine it here.'
        : '${blocked.name}: ${blocked.reason}.',
  );
}

/// The imaging session a master's pixels came from, or null when the fold
/// record cannot name one.
///
/// The reverse of [resolveDarkroomTargetForSession], and it goes through the
/// same record: a master is joined to a session only by the frames folded into
/// it, so this walks the fold list newest-first and answers with the first
/// frame that still names a session. Null is a real answer — a master whose
/// folded frames are gone, or whose frames were imported with no session, has
/// no review to open, and a control that claimed otherwise would land the
/// operator on a review of a night that is not this master's.
///
/// Bounded rather than exhaustive: the walk stops at [_sessionScanLimit] frames
/// because it runs one query per frame and a master can carry thousands. A
/// master whose newest 32 folds all name no session is one this cannot answer
/// for, and it says so instead of reading the whole table to be sure.
Future<int?> resolveSessionForDarkroomMaster(
    WidgetRef ref, int masterId) async {
  final frames =
      await ref.read(integratedMastersDaoProvider).getFramesForMaster(masterId);
  final images = ref.read(imagesDaoProvider);
  var scanned = 0;
  for (final frame in frames) {
    if (scanned++ >= _sessionScanLimit) break;
    final image = await images.getImageById(frame.imageId);
    final sessionId = image?.sessionId;
    if (sessionId != null) return sessionId;
  }
  return null;
}

/// How many fold records [resolveSessionForDarkroomMaster] reads before it
/// answers "cannot say".
const int _sessionScanLimit = 32;

/// The session review location for [sessionId].
String sessionReviewLocation(int sessionId) =>
    '/session-review?session=$sessionId';

/// Resolve [sessionId] and push the Darkroom onto its master, or say why there
/// is nothing to open.
///
/// For callers that are a screen rather than a dialog: it navigates without
/// dismissing anything. A dialog resolves with
/// [resolveDarkroomTargetForSession] instead, so it can close itself before
/// pushing.
Future<void> openDarkroomForSession(
  BuildContext context,
  WidgetRef ref,
  int sessionId,
) async {
  final target = await resolveDarkroomTargetForSession(ref, sessionId);
  if (!context.mounted) return;
  final masterId = target.masterId;
  if (masterId == null) {
    context.showInfoSnackBar(target.unavailableReason!);
    return;
  }
  openDarkroomForMaster(context, masterId);
}

/// Leave the Edit tab's editor the way it was entered.
///
/// Popping is what a pushed route deserves: it returns to the screen the image
/// was opened from. An editor reached with nothing to pop to — a notification,
/// a link from inside the Darkroom, a branch switch — returns to the Targets
/// tab on [target], the Darkroom's own home for the image.
void leaveDarkroomEdit(BuildContext context, {String? target}) {
  final router = GoRouter.of(context);
  if (router.canPop()) {
    router.pop();
    return;
  }
  router.go(
    target == null
        ? darkroomTabLocation(DarkroomTab.targets)
        : darkroomTargetLocation(target),
  );
}

/// Where [leaveDarkroomEdit] goes, in words, for the Back control's name.
String darkroomEditBackDestination(BuildContext context, {String? target}) {
  final canPop = GoRouter.maybeOf(context)?.canPop() ?? false;
  if (canPop) return 'Back to where this image was opened from';
  return target == null
      ? 'Back to the Darkroom targets'
      : 'Back to $target in the Darkroom targets';
}
