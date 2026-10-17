// First-run onboarding and the profile-mismatch banner.
part of '../equipment_screen.dart';

/// The first-run state: no profile exists yet, so the Devices tab is one
/// centred column with the setup checklist above the discovery drawer. Every
/// button here is secondary or ghost — the page's single primary is "Scan for
/// devices" in the page header, and both entry points run the same scan.
class _FirstTimeOnboarding extends StatelessWidget {
  final SkotiqColors colors;
  final VoidCallback onStartSetup;
  final VoidCallback onManualSetup;

  const _FirstTimeOnboarding({
    required this.colors,
    required this.onStartSetup,
    required this.onManualSetup,
  });

  /// Width of the centred first-run column.
  static const double columnWidth = 480.0;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: _bodyPadding,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: columnWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Set up your first rig',
                  textAlign: TextAlign.center,
                  style: SkotiqTypography.pageTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceXl),
                const SkotiqPanel(
                  head: PanelHead(
                    label: 'Equipment setup',
                    icon: LucideIcons.listChecks,
                  ),
                  child: Checklist(
                    steps: [
                      // No action on the row: the header's "Scan for devices"
                      // IS this step, and offering it a third time reads as
                      // three different setups.
                      ChecklistStep(
                        title: 'Scan for connected equipment',
                        detail: 'Skotiq looks for native, ASCOM, Alpaca '
                            'and INDI devices.',
                        state: ChecklistStepState.next,
                      ),
                      ChecklistStep(
                        title: 'Choose the devices you want to use',
                        detail: 'Camera, mount, focuser, filter wheel, guider.',
                      ),
                      ChecklistStep(
                        title: 'Save them as a profile',
                        detail: 'One profile reconnects the whole rig next '
                            'launch.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceXl),
                // A Wrap, not a Row: the two labels are 249 px wider than a
                // 360 dp column, and a first-run screen that overflows is the
                // worst possible first impression.
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: SkotiqTokens.spaceSm,
                  runSpacing: SkotiqTokens.spaceSm,
                  children: [
                    SkotiqButton(
                      label: 'Build a profile by hand',
                      variant: ButtonVariant.ghost,
                      onPressed: onManualSetup,
                    ),
                    // SECONDARY: the page's one primary is "Scan for devices"
                    // in the header, and this runs that same scan rather than
                    // the 13-step onboarding wizard it used to open.
                    SkotiqButton(
                      label: 'Start setup',
                      icon: LucideIcons.search,
                      variant: ButtonVariant.secondary,
                      onPressed: onStartSetup,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The ONE banner this screen shows: the connected devices do not match what
/// the active profile assigns.
class _ProfileMismatchBanner extends ConsumerWidget {
  const _ProfileMismatchBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeProfile = ref.watch(activeEquipmentProfileProvider);
    if (activeProfile == null) return const SizedBox.shrink();

    // The per-device mismatch derivation is owned by the canonical
    // `profileConnectionStatusProvider` (single source of truth). The banner's
    // stricter rule — flag a slot only when both sides have a non-empty id and
    // they differ after PHD2-canonical collapse — lives in
    // `ProfileDeviceConnection.isMismatch`, so the same PHD2 guider recorded
    // under any representation is never reported as a mismatch here.
    final status = ref.watch(profileConnectionStatusProvider(activeProfile));
    final mismatches = status.mismatchedDeviceNames;

    if (mismatches.isEmpty) return const SizedBox.shrink();

    // Session-dismiss: hide when the user has dismissed *this exact* mismatch
    // set. Re-keying by the sorted device list means a newly-introduced
    // mismatch re-surfaces the banner rather than staying silently hidden.
    final signature = (mismatches.toList()..sort()).join('|');
    final dismissedSignature = ref.watch(dismissedMismatchSignatureProvider);
    if (dismissedSignature == signature) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
      child: SkotiqBanner(
        tone: BannerTone.warning,
        title: 'Connected devices do not match the profile.',
        message: 'The ${mismatches.join(", ")} '
            '${mismatches.length == 1 ? 'is' : 'are'} not what '
            '"${activeProfile.name}" assigns.',
        onDismiss: () => ref
            .read(dismissedMismatchSignatureProvider.notifier)
            .state = signature,
      ),
    );
  }
}
