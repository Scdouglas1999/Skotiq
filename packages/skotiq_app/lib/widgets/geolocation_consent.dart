import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// What the operator has already agreed may leave the machine.
///
/// Consent is per TIER, not a single flag, because the tiers send different
/// things: agreeing that a public IP may go to ipinfo.io is not agreeing that
/// the names of the networks around the house may go to a positioning
/// service. A remembered "yes" only covers a later lookup that asks for the
/// same tiers or fewer.
class GeolocationConsent {
  const GeolocationConsent({required this.wifiScan, required this.ip});

  final bool wifiScan;
  final bool ip;

  bool covers({required bool wifiScan, required bool ip}) =>
      (!wifiScan || this.wifiScan) && (!ip || this.ip);
}

/// Consent given during this run. Deliberately not persisted: an operator who
/// agreed once on a laptop at home has not agreed for the observatory network
/// they plug into next week.
final geolocationConsentProvider = StateProvider<GeolocationConsent?>(
  (ref) => null,
);

/// The Google Geolocation API key, when the operator has entered one under
/// Settings → Location → Advanced.
///
/// Lives beside the consent dialog because it is the only file both Settings
/// and the first-run wizard already import, and both need the key to pass it
/// to the same lookup. An empty string means "no key" — the key-free beaconDB
/// tier is what runs.
final googleGeolocationKeyProvider =
    AsyncNotifierProvider<GoogleGeolocationKeyNotifier, String>(
  GoogleGeolocationKeyNotifier.new,
);

const String _googleGeolocationKeySetting = 'location_google_geolocation_key';

class GoogleGeolocationKeyNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final dao = ref.read(settingsDaoProvider);
    return (await dao.getSetting(_googleGeolocationKeySetting))?.trim() ?? '';
  }

  Future<void> setKey(String key) async {
    final trimmed = key.trim();
    await ref.read(settingsDaoProvider).setSetting(
          _googleGeolocationKeySetting,
          trimmed,
        );
    state = AsyncData(trimmed);
  }
}

/// Ask before a location lookup is allowed to leave the machine, then
/// remember the answer for the rest of the session.
///
/// Every "find my location" affordance in the app funnels through
/// `GeolocationService.locate`, which walks three tiers and sends something
/// different at each one. Skotiq is routinely run on isolated observatory
/// networks, so an operator expects to be asked, and to be told which of the
/// three is about to happen. One shared entry point so Settings and the
/// first-run wizard cannot disagree about what is being sent, or fail to ask
/// at all.
///
/// [outcome] closes the dialog with what the caller will do with the answer,
/// because "replaces your saved site" and "shows you a suggestion" deserve
/// different consent.
Future<bool> ensureGeolocationConsent(
  BuildContext context,
  WidgetRef ref, {
  required String outcome,
  bool includeWifiScan = true,
  bool includeIpFallback = true,
  bool googleKeyPresent = false,
}) async {
  final granted = ref.read(geolocationConsentProvider);
  if (granted != null &&
      granted.covers(wifiScan: includeWifiScan, ip: includeIpFallback)) {
    return true;
  }

  final consented = await confirmGeolocationLookup(
    context,
    outcome: outcome,
    includeWifiScan: includeWifiScan,
    includeIpFallback: includeIpFallback,
    googleKeyPresent: googleKeyPresent,
  );
  if (!consented) return false;

  final previous = ref.read(geolocationConsentProvider);
  ref.read(geolocationConsentProvider.notifier).state = GeolocationConsent(
    wifiScan: includeWifiScan || (previous?.wifiScan ?? false),
    ip: includeIpFallback || (previous?.ip ?? false),
  );
  return true;
}

/// The dialog itself. Use [ensureGeolocationConsent] from app code; this is
/// separate so its copy can be pinned by a test without a provider scope.
@visibleForTesting
Future<bool> confirmGeolocationLookup(
  BuildContext context, {
  required String outcome,
  bool includeWifiScan = true,
  bool includeIpFallback = true,
  bool googleKeyPresent = false,
}) async {
  final consented = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Detect this site’s location?'),
      // Without a width constraint this AlertDialog sizes to the window: on
      // the 1600 px desktop it rendered ~1520 px wide, one unbroken line of
      // body text edge to edge, while every other dialog in the app (the
      // sequence-issues list, the unwritable-folder confirm) sits at the
      // 480 px design width. Same constraint helper they use.
      // The Align is load-bearing, not decoration: AlertDialog stretches its
      // content to the dialog's own width, which arrives as a TIGHT
      // constraint, and a ConstrainedBox can only narrow a loose one. Align
      // loosens it, so the body honours the 480 px cap even when the action
      // row is what decides how wide the dialog ends up.
      content: Align(
        alignment: AlignmentDirectional.centerStart,
        // Sized to the paragraphs, not to the loose height AlertDialog hands
        // down: an Align with no heightFactor fills whatever it is given, and
        // the shared constraints cap height at 85% of the viewport, so two
        // short paragraphs rendered as a ~680 px dialog with the text floating
        // between 230 px of empty space above and 225 px below.
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            dialogContext,
            designMaxWidth: 480,
          ),
          child: SingleChildScrollView(
            child: Text(
              geolocationConsentBody(
                outcome: outcome,
                includeWifiScan: includeWifiScan,
                includeIpFallback: includeIpFallback,
                googleKeyPresent: googleKeyPresent,
              ),
            ),
          ),
        ),
      ),
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.pop(dialogContext, false),
        ),
        SkotiqButton(
          label: 'Detect location',
          variant: ButtonVariant.primary,
          size: ButtonSize.small,
          onPressed: () => Navigator.pop(dialogContext, true),
        ),
      ],
    ),
  );
  return consented == true;
}

/// The dialog's body: one line per tier that is actually allowed, naming what
/// that tier sends and to whom, in the order they will be tried.
///
/// Pure so the copy is assertable without pumping a dialog, and so a tier
/// that is switched off can never leave its disclosure on screen.
String geolocationConsentBody({
  required String outcome,
  required bool includeWifiScan,
  required bool includeIpFallback,
  bool googleKeyPresent = false,
}) {
  final steps = <String>[
    'This device’s own location service, if it has one. Nothing leaves the '
        'machine.',
    if (includeWifiScan)
      googleKeyPresent
          ? 'The names and signal strengths of nearby Wi-Fi networks, sent to '
              'Google (your Geolocation API key), and to beaconDB (an open '
              'positioning service) if Google cannot place them. This is '
              'the step that finds your yard rather than your town. The '
              'networks are used for this one request and never saved.'
          : 'The names and signal strengths of nearby Wi-Fi networks, sent to '
              'beaconDB (an open positioning service). This is the step '
              'that finds your yard rather than your town. The networks are '
              'used for this one request and never saved.',
    if (includeIpFallback)
      'Your public IP address, sent to ipinfo.io over HTTPS (falling back to '
          'ipwho.is). That only locates your internet provider — city level, '
          'tens of kilometres.',
  ];

  final buffer = StringBuffer(
    'Skotiq will try these in order and stop as soon as one of them '
    'places you precisely:\n',
  );
  for (final step in steps) {
    buffer.write('\n• $step\n');
  }
  buffer.write('\n$outcome');
  return buffer.toString();
}

/// Closing paragraph for a lookup that writes straight to the observing site.
const String kGeolocationWritesSiteOutcome =
    'Neither source reports elevation. Latitude and longitude are '
    'replaced; the elevation is kept only if the new position is near '
    'the current one, and is otherwise cleared for you to enter.';

/// Closing paragraph for a lookup that only *offers* a starting point.
const String kGeolocationOffersEstimateOutcome =
    'The result is only shown as a suggested starting point — nothing is '
    'saved to your observing site until you accept it.';
