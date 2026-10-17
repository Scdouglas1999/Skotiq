import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../mosaic/mosaic_contribute_sheet.dart';

/// App-side Riverpod surface for the unified Collaborative Sky screen. It
/// composes live co-imaging, collaborative mosaics and the shared calibration
/// library on top of the SAME self-hosted hub credentials Constellation
/// resolves through `constellationConfiguredProvider` /
/// `constellationHubInfoProvider`.
///
/// Each list fails closed (an auth/network [ConstellationException]) exactly
/// like the constellation providers, so the screen renders an inline error
/// card rather than crashing.

/// Active collaborative mosaics advertised on the configured hub. Empty
/// until a club publishes a mosaic; surfaces the panel grid as claimable work.
final collaborativeMosaicsProvider = FutureProvider<List<CollabMosaic>>((ref) {
  return ref.watch(collaborativeMosaicServiceProvider).listMosaics();
});

/// The LOCAL mosaic project mirroring a hub mosaic, or null when this device
/// has neither published nor joined it. Keyed by the hub mosaic id, which is
/// the join key `mosaic_projects.hub_mosaic_id` stores.
///
/// The collaborative detail screen needs this to tell a stranger's mosaic from
/// one this rig already owns: without it, the owner of a mosaic they had just
/// published was offered a "Join mosaic" button for their own project.
final localMosaicProjectForHubProvider =
    FutureProvider.family<MosaicProject?, String>((ref, mosaicId) {
  return ref.watch(mosaicProjectsDaoProvider).getByHubMosaicId(mosaicId);
});

/// Every provider that caches hub-side collaborative-mosaic state.
///
/// They are plain (non-`autoDispose`) `FutureProvider`s, so the first answer
/// sticks for the life of the container: a rig that opened Collaborative Sky
/// before publishing kept being told "No collaborative mosaics on this hub yet"
/// about a mosaic it had just published itself. EVERY code path that changes
/// hub-side state — publish, claim, release, upload, assemble, join — has to
/// drop these, not just the screen header's manual refresh button.
List<ProviderOrFamily> get collaborativeMosaicStateProviders => [
      collaborativeMosaicsProvider,
      collaborativeMosaicDetailProvider,
      collaborativeMosaicAttributionProvider,
      // Joining/publishing creates the local mirror this resolves, so the
      // "join vs open your own project" branch must be re-read too.
      localMosaicProjectForHubProvider,
    ];

/// Drop [collaborativeMosaicStateProviders] from a provider body / notifier.
void invalidateCollaborativeMosaicState(Ref ref) {
  for (final provider in collaborativeMosaicStateProviders) {
    ref.invalidate(provider);
  }
}

/// Drop [collaborativeMosaicStateProviders] from a widget callback.
void invalidateCollaborativeMosaicStateFor(WidgetRef ref) {
  for (final provider in collaborativeMosaicStateProviders) {
    ref.invalidate(provider);
  }
}

/// The detailed state of one collaborative mosaic (its per-panel grid, claim
/// status, and contributor attribution), keyed by the hub mosaic id. The list
/// endpoint returns mosaics WITHOUT their panels (a deliberately cheap browse
/// payload), so the cards watch this to populate real combined panel-progress
/// and per-panel credit.
final collaborativeMosaicDetailProvider =
    FutureProvider.family<CollabMosaic, String>((ref, mosaicId) {
  return ref.watch(collaborativeMosaicServiceProvider).getMosaic(mosaicId);
});

/// The authoritative contributor credits for one collaborative mosaic, read back
/// from the hub's `GET /v1/attribution` rather than reconstructed from the
/// browse payload. The hub resolves each display name consent-aware (a withheld
/// contributor renders as "Anonymous contributor"), so the UI never has to
/// trust a local copy. Fails
/// closed like the other collaborative providers; the cards fall back to the
/// embedded owner/panel names while it loads or when the hub is unreachable.
final collaborativeMosaicAttributionProvider =
    FutureProvider.family<ArtifactAttribution, String>((ref, mosaicId) {
  return ref
      .watch(collaborativeMosaicServiceProvider)
      .fetchMosaicAttribution(mosaicId);
});

/// The authoritative contributor credits for one live co-imaging session, read
/// back from the hub's `GET /v1/attribution` rather than reconstructed
/// from the participant roster. Consent-aware (withheld rigs render anonymously)
/// and fails closed; the card falls back to the participant display names while
/// it loads or when the hub is unreachable.
final coImagingAttributionProvider =
    FutureProvider.family<ArtifactAttribution, String>((ref, sessionId) {
  return ref.watch(coImagingSessionServiceProvider).fetchAttribution(sessionId);
});

/// A read-only summary of this device's participation in the shared calibration
/// library: how many local masters the user has PUBLISHED to the hub, and
/// how many remote masters the user has PULLED down and merged. Both are read
/// from the durable local library — no hub round-trip — so the card renders
/// instantly and honestly even when the hub is briefly unreachable.
class SharedLibrarySummary {
  /// Local masters the user has shared out to the hub (`publishedRemoteId` set).
  final int publishedCount;

  /// Remote masters the user has accepted into the local library (carry an
  /// authoritative `sharedBy` credit but are no longer an inbound candidate).
  final int pulledCount;

  const SharedLibrarySummary({
    required this.publishedCount,
    required this.pulledCount,
  });

  int get total => publishedCount + pulledCount;

  bool get isEmpty => total == 0;
}

/// Summarises shared-calibration participation from the durable local library.
final sharedLibrarySummaryProvider =
    FutureProvider<SharedLibrarySummary>((ref) async {
  final records = await ref
      .watch(calibrationLibraryServiceProvider)
      .listMasters(enrichFromHeaders: false);
  var published = 0;
  var pulled = 0;
  for (final r in records) {
    if (r.publishedRemoteId != null) {
      published++;
    } else if (r.sharedBy != null && r.remoteId == null) {
      // A pulled-in remote master: it carries an authoritative producer credit
      // but is NOT a not-yet-downloaded inbound candidate (those still hold a
      // `remoteId`). Those are the masters this rig saved instead of re-shooting.
      pulled++;
    }
  }
  return SharedLibrarySummary(publishedCount: published, pulledCount: pulled);
});

/// Whether this rig's completed subs would actually co-add into a session's
/// combined stack.
///
/// Membership and contribution are separate facts: joining points the mount at
/// a framing slot, but the auto-contribute egress fails closed unless the
/// operator has an UNATTENDED contribution consent on record (the same
/// `MosaicUploadConsent.autoUpload` the mosaic path persists). A card that
/// reports pooling from membership alone tells a user who declined the consent
/// sheet that their photons are being shared when nothing is leaving the
/// device.
final coImagingSharingEnabledProvider = FutureProvider<bool>((ref) async {
  final consent = await ref.watch(mosaicUploadConsentProvider.future);
  return consent != null && consent.autoUpload;
});
