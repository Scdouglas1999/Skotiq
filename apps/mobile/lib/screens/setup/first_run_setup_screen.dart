// First-run setup for a phone that has just paired with a host.
//
// A freshly installed host is usually missing three things a first night
// needs: a capture folder (every frame would fail to save), a star catalog
// (plate solving and target search fail) and an equipment profile (nothing can
// be connected). This wizard covers the first two in a step each and points at
// the host for the third, so a phone user can get a new rig ready in a minute.
//
// [FirstRunSetupGate] shows it between pairing and the app shell, at most once
// per install: finishing or skipping it, or linking a host that needs nothing,
// sets `MobilePreferences.firstRunCompleted`.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/skotiq_app.dart' show SkotiqSplashGate;
import 'package:skotiq_app/widgets/remote_directory_picker_dialog.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../services/mobile_preferences.dart';
import '../../utils/error_snackbar.dart';

/// What the linked host is missing for a first night.
class FirstRunSetupNeeds {
  final bool missingImageOutputPath;
  final bool missingProfiles;
  final bool missingCatalogs;

  const FirstRunSetupNeeds({
    required this.missingImageOutputPath,
    required this.missingProfiles,
    required this.missingCatalogs,
  });

  bool get hasAnyMissing =>
      missingImageOutputPath || missingProfiles || missingCatalogs;

  static const FirstRunSetupNeeds none = FirstRunSetupNeeds(
    missingImageOutputPath: false,
    missingProfiles: false,
    missingCatalogs: false,
  );
}

/// What the linked host is missing, or [FirstRunSetupNeeds.none] when this
/// phone has already been through setup or is not linked to a host.
///
/// A check that fails counts as missing: the wizard then shows the step, where
/// the failure can be retried in view, instead of the first capture failing
/// later with a less useful error.
final shouldRunFirstRunSetupProvider = FutureProvider<FirstRunSetupNeeds>((
  ref,
) async {
  final prefs = await ref.watch(mobilePreferencesProvider.future);
  if (prefs.firstRunCompleted) return FirstRunSetupNeeds.none;

  final backend = ref.watch(backendProvider);
  final linkedHost = backend.remoteHost;
  if (linkedHost == null) return FirstRunSetupNeeds.none;

  Future<bool> missing(String what, Future<bool> Function() check) async {
    try {
      return await check();
    } catch (e, st) {
      developer.log(
        'first-run: could not check $what: $e',
        name: 'FirstRunSetup',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      return true;
    }
  }

  final (missingPath, missingProfiles, missingCatalogs) = await (
    missing(
      'the capture folder',
      () async => (await backend.getSettings()).imageOutputPath.trim().isEmpty,
    ),
    missing(
      'equipment profiles',
      () async => (await backend.getProfiles()).isEmpty,
    ),
    missing(
      'catalogs',
      () async => !(await linkedHost.catalogs.getCatalogStatus()).catalogs.any(
        (c) => c.isInstalled,
      ),
    ),
  ).wait;

  return FirstRunSetupNeeds(
    missingImageOutputPath: missingPath,
    missingProfiles: missingProfiles,
    missingCatalogs: missingCatalogs,
  );
});

/// Stands between pairing and the app shell until first-run setup is done.
///
/// Checks the linked host once when mounted. A host that needs nothing passes
/// straight to [child] and marks setup done, so later launches skip the check.
/// Once passed, the gate stays out of the way for as long as it is mounted, so
/// a later reconnect or rig switch never swaps the shell for the wizard.
class FirstRunSetupGate extends ConsumerStatefulWidget {
  const FirstRunSetupGate({
    super.key,
    required this.frame,
    required this.child,
  });

  /// Puts the wizard (and the brief check before it) in the app's themed
  /// [MaterialApp]; [child] brings its own.
  final Widget Function(Widget home) frame;

  /// The app shell.
  final Widget child;

  @override
  ConsumerState<FirstRunSetupGate> createState() => _FirstRunSetupGateState();
}

class _FirstRunSetupGateState extends ConsumerState<FirstRunSetupGate> {
  FirstRunSetupNeeds? _needs;
  bool _passed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final linked = ref.read(isRemoteModeProvider);
    FirstRunSetupNeeds needs;
    try {
      needs = await ref.read(shouldRunFirstRunSetupProvider.future);
      if (linked && !needs.hasAnyMissing) {
        final prefs = await ref.read(mobilePreferencesProvider.future);
        await prefs.setFirstRunCompleted(true);
      }
    } catch (e, st) {
      // Setup is help, not a requirement: if this phone's own preferences
      // cannot be read, open the app rather than strand the user here.
      developer.log(
        'first-run: setup check failed, opening the app: $e',
        name: 'FirstRunSetup',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      needs = FirstRunSetupNeeds.none;
    }
    if (!mounted) return;
    setState(() {
      _needs = needs;
      _passed = !needs.hasAnyMissing;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_passed) return widget.child;
    final needs = _needs;
    if (needs == null) {
      return widget.frame(
        const SkotiqSplashGate(
          ready: false,
          statusText: 'Checking your rig',
          child: SizedBox.shrink(),
        ),
      );
    }
    return widget.frame(
      FirstRunSetupScreen(
        needs: needs,
        onCompleted: () => setState(() => _passed = true),
      ),
    );
  }
}

/// Three steps: the capture folder on the host, the catalogs to install, and
/// the equipment profile (made on the host; this step shows what exists).
/// The wizard opens on the first step the host still needs.
class FirstRunSetupScreen extends ConsumerStatefulWidget {
  final FirstRunSetupNeeds needs;
  final VoidCallback onCompleted;

  const FirstRunSetupScreen({
    super.key,
    required this.needs,
    required this.onCompleted,
  });

  @override
  ConsumerState<FirstRunSetupScreen> createState() =>
      _FirstRunSetupScreenState();
}

class _FirstRunSetupScreenState extends ConsumerState<FirstRunSetupScreen> {
  int _activeStep = 0;
  bool _busy = false;

  final TextEditingController _customPathController = TextEditingController();
  String? _lastBrowsedHostPath;

  /// True once the host has accepted and saved a capture folder in this
  /// session. The step's tick comes from this, never from navigation: a tick
  /// for a step the user only tapped past would send the first capture of the
  /// night to a folder that does not exist.
  bool _outputPathCommitted = false;

  List<RemoteAvailableCatalog>? _availableCatalogs;
  final Set<String> _catalogsToInstall = {};
  final Set<String> _catalogsInFlight = {};
  String? _catalogLoadError;

  List<EquipmentProfile>? _profiles;
  String? _profileLoadError;
  bool _loadingBootstrapData = false;

  /// False when the host refused this phone's folder access: phones pair
  /// without filesystem rights unless the user grants full admin access, so
  /// the capture folder has to be set on the imaging computer.
  bool _canChooseFolders = true;

  /// False once the host refused to start a catalog download for the same
  /// reason.
  bool _canInstallCatalogs = true;

  @override
  void initState() {
    super.initState();
    if (!widget.needs.missingImageOutputPath) {
      _activeStep = widget.needs.missingCatalogs ? 1 : 2;
    }
    unawaited(_loadCatalogsAndProfiles());
  }

  @override
  void dispose() {
    _customPathController.dispose();
    super.dispose();
  }

  Future<void> _loadCatalogsAndProfiles() async {
    if (_loadingBootstrapData) return;
    _loadingBootstrapData = true;
    final backend = ref.read(backendProvider);
    final linkedHost = backend.remoteHost;
    if (linkedHost == null) {
      if (mounted) {
        setState(() {
          _loadingBootstrapData = false;
          _catalogLoadError = 'This phone is not connected to a rig.';
          _profileLoadError = 'This phone is not connected to a rig.';
        });
      }
      return;
    }

    List<RemoteAvailableCatalog>? catalogs;
    List<EquipmentProfile>? profiles;
    String? catalogError;
    String? profileError;
    var canChooseFolders = _canChooseFolders;

    await Future.wait<void>([
      if (widget.needs.missingImageOutputPath && !_outputPathCommitted)
        () async {
          try {
            await linkedHost.files.browseRemoteDirectories();
          } catch (e) {
            // Only a refusal changes the step; any other failure is reported
            // by the field when the folder is saved.
            if (isAccessLevelRefusal(e)) {
              canChooseFolders = false;
            } else {
              developer.log(
                'first-run: folder access check failed: $e',
                name: 'FirstRunSetup',
                level: 900,
              );
            }
          }
        }(),
      () async {
        try {
          catalogs = await linkedHost.catalogs.listAvailableCatalogs();
        } catch (e, st) {
          catalogError = userFacingError(e);
          developer.log(
            'first-run: failed to load catalogs: $e',
            name: 'FirstRunSetup',
            level: 1000,
            error: e,
            stackTrace: st,
          );
        }
      }(),
      () async {
        try {
          profiles = await backend.getProfiles();
        } catch (e, st) {
          profileError = userFacingError(e);
          developer.log(
            'first-run: failed to load profiles: $e',
            name: 'FirstRunSetup',
            level: 1000,
            error: e,
            stackTrace: st,
          );
        }
      }(),
    ]);

    if (!mounted) return;
    setState(() {
      _loadingBootstrapData = false;
      _catalogLoadError = catalogError;
      _profileLoadError = profileError;
      _availableCatalogs = catalogs;
      _canChooseFolders = canChooseFolders;
      // The catalogs plate solving needs start ticked; the rest are opt-in.
      for (final c in catalogs ?? const <RemoteAvailableCatalog>[]) {
        if (c.requiredForPlateSolve) _catalogsToInstall.add(c.name);
      }
      _profiles = profiles;
    });
  }

  Future<void> _browseImageOutputPath() async {
    if (_busy) return;
    final selected = await RemoteDirectoryPickerDialog.show(
      context,
      title: 'Choose the capture folder on the rig',
      initialPath: _lastBrowsedHostPath,
    );
    if (selected == null || !mounted) return;
    setState(() {
      _lastBrowsedHostPath = selected;
      _customPathController.text = selected;
    });
  }

  Future<void> _commitImageOutputPath() async {
    if (_busy) return;
    final backend = ref.read(backendProvider);
    final linkedHost = backend.remoteHost;
    if (linkedHost == null) return;
    final path = _customPathController.text.trim();
    if (path.isEmpty) {
      showApiError(
        context,
        ServerError(
          code: 'invalid_input',
          message: 'Choose a folder on the rig, or type its path.',
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final validation = await linkedHost.files.validateRemoteDirectory(
        path,
        mustExist: true,
        mustBeWritable: true,
      );
      if (validation['valid'] != true) {
        final reason = validation['error'];
        throw ServerError(
          code: 'invalid_output_path',
          message: reason is String && reason.trim().isNotEmpty
              ? reason.trim()
              : 'Choose a folder on the rig that exists and can be written '
                    'to.',
        );
      }
      final normalized = validation['normalizedPath'];
      final validatedPath = normalized is String && normalized.trim().isNotEmpty
          ? normalized.trim()
          : path;
      final current = await backend.getSettings();
      await backend.updateSettings(
        current.copyWith(imageOutputPath: validatedPath),
      );
      if (!mounted) return;
      setState(() {
        _customPathController.text = validatedPath;
        _lastBrowsedHostPath = validatedPath;
        _outputPathCommitted = true;
        _busy = false;
        _activeStep = 1;
      });
    } catch (e) {
      if (!mounted) return;
      if (isAccessLevelRefusal(e)) {
        setState(() {
          _busy = false;
          _canChooseFolders = false;
        });
        return;
      }
      setState(() => _busy = false);
      showApiErrorWithPrefix(context, 'Could not save the capture folder', e);
    }
  }

  Future<void> _commitCatalogs() async {
    if (_busy) return;
    final linkedHost = ref.read(backendProvider).remoteHost;
    if (linkedHost == null) return;
    if (_catalogsToInstall.isEmpty) {
      setState(() => _activeStep = 2);
      return;
    }
    setState(() => _busy = true);
    var startedAny = false;
    final names = {
      for (final c in _availableCatalogs ?? const <RemoteAvailableCatalog>[])
        c.name: c.displayName,
    };
    for (final name in _catalogsToInstall.toList(growable: false)) {
      try {
        await linkedHost.catalogs.downloadCatalog(name);
        startedAny = true;
        if (!mounted) return;
        setState(() => _catalogsInFlight.add(name));
      } catch (e) {
        if (!mounted) return;
        if (isAccessLevelRefusal(e)) {
          setState(() => _canInstallCatalogs = false);
          break;
        }
        // One failed download does not stop the others; the rest can be
        // retried from Settings > Catalogs.
        showApiErrorWithPrefix(
          context,
          'Could not start ${names[name] ?? name}',
          e,
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (startedAny) _activeStep = 2;
    });
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final prefs = await ref.read(mobilePreferencesProvider.future);
      await prefs.setFirstRunCompleted(true);
      ref.invalidate(shouldRunFirstRunSetupProvider);
      if (!mounted) return;
      widget.onCompleted();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showApiErrorWithPrefix(context, 'Could not finish setup', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              icon: SkotiqIcons.checklist,
              title: 'Set up your rig',
              actions: [
                // Skipping counts as done: the wizard interrupts once, and
                // every step is also in Settings.
                SkotiqButton(
                  label: 'Skip',
                  variant: ButtonVariant.ghost,
                  onPressed: _busy ? null : _finish,
                ),
              ],
            ),
            Expanded(
              child: Stepper(
                currentStep: _activeStep,
                controlsBuilder: (context, details) => const SizedBox.shrink(),
                onStepTapped: _busy
                    ? null
                    : (step) => setState(() => _activeStep = step),
                steps: [
                  Step(
                    title: const Text('Capture folder'),
                    isActive: _activeStep == 0,
                    state: _outputPathState,
                    content: _buildImagePathStep(colors),
                  ),
                  Step(
                    title: const Text('Star catalogs'),
                    isActive: _activeStep == 1,
                    state: _catalogsState,
                    content: _buildCatalogsStep(colors),
                  ),
                  Step(
                    title: const Text('Equipment profile'),
                    isActive: _activeStep == 2,
                    state: _profileState,
                    content: _buildProfileStep(colors),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A step's tick is a claim about the host, so each one is answered from a
  /// fact: the host already had it when the wizard opened, or this session
  /// did something about it.
  StepState get _outputPathState =>
      !widget.needs.missingImageOutputPath || _outputPathCommitted
      ? StepState.complete
      : StepState.indexed;

  /// Ticked once the host has accepted at least one download. A skipped step
  /// stays unticked, because plate solving really is unavailable.
  StepState get _catalogsState =>
      !widget.needs.missingCatalogs || _catalogsInFlight.isNotEmpty
      ? StepState.complete
      : StepState.indexed;

  /// From the profile list read back from the host when there is one: a
  /// profile may have been made on the host while the wizard was open.
  StepState get _profileState {
    final profiles = _profiles;
    if (profiles != null) {
      return profiles.isEmpty ? StepState.indexed : StepState.complete;
    }
    return widget.needs.missingProfiles
        ? StepState.indexed
        : StepState.complete;
  }

  Widget _stepText(SkotiqColors colors, String text) => Text(
    text,
    style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
  );

  Widget _buildImagePathStep(SkotiqColors colors) {
    if (!_canChooseFolders) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SkotiqBanner(
            title: 'Set the capture folder on the imaging computer',
            message:
                'This phone was paired without full admin access, so the rig '
                'does not let it choose folders. Set the folder in Settings '
                'on the imaging computer, or pair this phone again with full '
                'admin access.',
            tone: BannerTone.warning,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqButton(
            onPressed: _busy
                ? null
                : () => setState(
                    () => _activeStep = widget.needs.missingCatalogs ? 1 : 2,
                  ),
            label: 'Continue',
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepText(
          colors,
          'Where should the rig save its frames? The folder is on the imaging '
          'computer, not this phone, and must already exist.',
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        SkotiqTextField(
          controller: _customPathController,
          enabled: !_busy,
          label: 'Capture folder on the rig',
          hint: r'e.g. D:\Astro\Captures or /mnt/captures',
          prefixIcon: SkotiqIcons.folder,
          mono: true,
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Align(
          alignment: Alignment.centerLeft,
          child: SkotiqButton(
            onPressed: _busy ? null : _browseImageOutputPath,
            label: 'Browse the rig',
            icon: SkotiqIcons.folderOpen,
            variant: ButtonVariant.secondary,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        SkotiqButton(
          onPressed: _busy ? null : _commitImageOutputPath,
          label: _busy ? 'Saving…' : 'Save and continue',
        ),
      ],
    );
  }

  Widget _buildCatalogsStep(SkotiqColors colors) {
    final loadError = _catalogLoadError;
    if (loadError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkotiqBanner(
            title: 'Could not list the catalogs',
            message: loadError,
            tone: BannerTone.error,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqButton(
            onPressed: _busy || _loadingBootstrapData
                ? null
                : () {
                    setState(() {
                      _catalogLoadError = null;
                      _availableCatalogs = null;
                    });
                    unawaited(_loadCatalogsAndProfiles());
                  },
            label: 'Try again',
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqButton(
            onPressed: _busy ? null : () => setState(() => _activeStep = 2),
            label: 'Skip catalogs',
            variant: ButtonVariant.ghost,
          ),
        ],
      );
    }
    final catalogs = _availableCatalogs;
    if (catalogs == null) return const _StepLoading();
    if (!_canInstallCatalogs) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SkotiqBanner(
            title: 'Install catalogs on the imaging computer',
            message:
                'This phone was paired without full admin access, so the rig '
                'does not let it install catalogs. Install them in Settings '
                'on the imaging computer, or pair this phone again with full '
                'admin access.',
            tone: BannerTone.warning,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqButton(
            onPressed: _busy ? null : () => setState(() => _activeStep = 2),
            label: 'Continue',
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepText(
          colors,
          'Plate solving needs at least one star catalog. Downloads run on '
          'the rig, so you can finish setup before they are done.',
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        for (final c in catalogs)
          _CatalogRow(
            catalog: c,
            selected: _catalogsToInstall.contains(c.name),
            downloading: _catalogsInFlight.contains(c.name),
            onChanged: _busy
                ? null
                : (selected) => setState(() {
                    if (selected) {
                      _catalogsToInstall.add(c.name);
                    } else {
                      _catalogsToInstall.remove(c.name);
                    }
                  }),
          ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        SkotiqButton(
          onPressed: _busy ? null : _commitCatalogs,
          label: _busy
              ? 'Starting downloads…'
              : _catalogsToInstall.isEmpty
              ? 'Continue without catalogs'
              : 'Install and continue',
        ),
      ],
    );
  }

  Widget _buildProfileStep(SkotiqColors colors) {
    final loadError = _profileLoadError;
    if (loadError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkotiqBanner(
            title: 'Could not list the equipment profiles',
            message: loadError,
            tone: BannerTone.error,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqButton(
            onPressed: _busy || _loadingBootstrapData
                ? null
                : () {
                    setState(() {
                      _profileLoadError = null;
                      _profiles = null;
                    });
                    unawaited(_loadCatalogsAndProfiles());
                  },
            label: _loadingBootstrapData ? 'Trying again…' : 'Try again',
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqButton(
            onPressed: _busy ? null : _finish,
            label: 'Finish without a profile',
            variant: ButtonVariant.ghost,
          ),
        ],
      );
    }
    final profiles = _profiles;
    if (profiles == null) return const _StepLoading();
    if (profiles.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepText(
            colors,
            profiles.length == 1
                ? 'The rig has an equipment profile.'
                : 'The rig has ${profiles.length} equipment profiles.',
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          for (final p in profiles)
            ListRow(icon: SkotiqIcons.layers, title: p.name),
          const SizedBox(height: SkotiqTokens.spaceLg),
          SkotiqButton(
            onPressed: _busy ? null : _finish,
            label: 'Finish setup',
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepText(
          colors,
          'The rig has no equipment profile yet. Make one on the imaging '
          'computer, under Equipment; this phone uses it as soon as it '
          'exists. You can finish now.',
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        SkotiqButton(
          onPressed: _busy ? null : _finish,
          label: 'Finish without a profile',
        ),
      ],
    );
  }
}

class _StepLoading extends StatelessWidget {
  const _StepLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: SkotiqTokens.space2xl),
      child: Center(
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
      ),
    );
  }
}

class _CatalogRow extends StatelessWidget {
  const _CatalogRow({
    required this.catalog,
    required this.selected,
    required this.downloading,
    required this.onChanged,
  });

  final RemoteAvailableCatalog catalog;
  final bool selected;
  final bool downloading;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final change = onChanged;
    return Semantics(
      checked: selected,
      enabled: change != null,
      child: InkWell(
        onTap: change == null ? null : () => change(!selected),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: SkotiqTokens.minTouchTarget,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: SkotiqCheckbox(
                    value: selected,
                    onChanged: change == null
                        ? null
                        : (v) => change(v ?? false),
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: SkotiqTokens.spaceSm,
                        runSpacing: SkotiqTokens.spaceXs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            catalog.displayName,
                            style: SkotiqTypography.bodyStrong.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                          if (downloading || catalog.requiredForPlateSolve)
                            SkotiqChip(
                              label: downloading
                                  ? 'Downloading'
                                  : 'Plate solving',
                              tone: downloading
                                  ? ChipTone.success
                                  : ChipTone.primary,
                            ),
                        ],
                      ),
                      Text(
                        '${catalog.description} · '
                        '${ByteFormat.size(catalog.sizeBytes)}',
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
