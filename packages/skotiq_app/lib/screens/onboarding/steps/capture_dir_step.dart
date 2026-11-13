import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/host_folders.dart';

typedef OnboardingCaptureDirectoryWriter = Future<void> Function(String path);

/// Makes the folder a first run suggests and returns its path, or null where
/// there is no sensible default (no home directory, a phone).
typedef OnboardingDefaultCaptureDirectory = Future<String?> Function();

/// Resolve a leading `~` against this machine's home directory.
///
/// Returns [path] unchanged when there is no tilde to expand or no home to
/// expand it against — a guess is worse than the honest "does not exist".
/// Exported so the onboarding tests can pin the behaviour without reaching into
/// the step's private state.
String expandCaptureDirHome(String path) {
  if (path != '~' && !path.startsWith('~/')) return path;
  final home = Platform.environment['HOME'];
  if (home == null || home.trim().isEmpty) return path;
  if (path == '~') return home;
  return '$home${Platform.pathSeparator}${path.substring(2)}';
}

/// The pictures folder the XDG user-dirs file in [configDir] names, if any.
String? _xdgPicturesDir(String home, String configDir) {
  final file = File('$configDir/user-dirs.dirs');
  if (!file.existsSync()) return null;
  final match = RegExp(r'^XDG_PICTURES_DIR="(.+)"', multiLine: true)
      .firstMatch(file.readAsStringSync());
  return match?.group(1)?.replaceFirst(r'$HOME', home);
}

/// Makes `Skotiq` inside the pictures folder of [home] (inside [home] itself
/// when it has none) and returns its path. [configDir] is where Linux keeps
/// the user-dirs file that can rename the pictures folder.
@visibleForTesting
Future<String> makeCaptureDirectoryIn(String home, {String? configDir}) async {
  final sep = Platform.pathSeparator;
  final pictures = (configDir == null ? null : _xdgPicturesDir(home, configDir)) ??
      '$home${sep}Pictures';
  final parent = await Directory(pictures).exists() ? pictures : home;
  final folder = await Directory('$parent${sep}Skotiq').create(recursive: true);
  return folder.path;
}

/// The capture folder a first run on this computer starts with, made if it is
/// not there yet. Null where there is no sensible default (no home directory,
/// a phone).
Future<String?> prepareDefaultCaptureDirectory() async {
  if (Platform.isAndroid || Platform.isIOS) return null;
  final env = Platform.environment;
  final home = env[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  if (home == null || home.trim().isEmpty) return null;
  return makeCaptureDirectoryIn(
    home,
    configDir: Platform.isLinux
        ? env['XDG_CONFIG_HOME'] ?? '$home/.config'
        : null,
  );
}

/// No suggestion unless the app installs [prepareDefaultCaptureDirectory]
/// (see `appProviderOverrides`), so a test never makes folders in the home
/// directory of the machine it runs on.
final onboardingDefaultCaptureDirectoryProvider =
    Provider<OnboardingDefaultCaptureDirectory>((ref) => () async => null);

final onboardingCaptureDirectoryWriterProvider =
    Provider<OnboardingCaptureDirectoryWriter>((ref) {
  return ref.read(onboardingDraftProvider.notifier).setCaptureDirectory;
});

/// The editable capture-folder box. Exposed so tests can drive it without
/// matching on hint copy.
const Key onboardingCaptureDirFieldKey = Key('onboarding.captureDir.field');

/// What the step currently knows about the chosen folder.
///
/// Writability records an actual filesystem check, never just a stored path.
enum _FolderCheck {
  checking,

  /// A check passed for [_OnboardingCaptureDirStepState._checkedPath].
  writable,

  /// A check ran and rejected the folder.
  failed,

  /// No check could be made (the host is unreachable). Reported as unknown
  /// rather than dressed up as either outcome.
  unverified,
}

/// Capture-directory step.
///
/// Lets the user pick a folder where Skotiq will save captures.
/// Validation runs immediately on the chosen path:
///   * the path must already exist — nothing here creates a folder,
///   * the process must be able to write a probe file there.
/// Both checks happen against the real filesystem — no shortcuts — so
/// the user discovers permission issues before their first session
/// instead of mid-capture.
///
/// The same checks re-run when the step is re-entered carrying a remembered
/// path, and after a host switch, so the confirmation on screen always
/// describes a check that actually happened against the filesystem the captures
/// will land on.
class OnboardingCaptureDirStep extends ConsumerStatefulWidget {
  const OnboardingCaptureDirStep({super.key});

  @override
  ConsumerState<OnboardingCaptureDirStep> createState() =>
      _OnboardingCaptureDirStepState();
}

class _OnboardingCaptureDirStepState
    extends ConsumerState<OnboardingCaptureDirStep> {
  /// Outcome of the most recent check, or null when there is no folder to
  /// report on.
  _FolderCheck? _check;

  /// The folder [_check] describes. A draft path that does not match this has
  /// not been checked in this session, so no verdict is shown for it.
  String? _checkedPath;

  /// Why the folder was rejected, or why it could not be checked.
  String? _checkDetail;

  bool _selecting = false;
  bool _validating = false;

  /// A verdict belongs to the folders it was checked on, which change with
  /// the imaging host, and only the newest operation may apply its result.
  late final AsyncScopes<HostFolders> _operations = AsyncScopes(
    ref.read,
    hostFoldersProvider,
    alive: () => mounted,
  );

  /// Re-check pending for the text now in the box.
  Timer? _editDebounce;

  /// How long a pause in typing counts as "the user has finished the path".
  /// Short enough that correcting a rejected folder answers while they are
  /// still looking at it, long enough not to probe the filesystem per keystroke.
  static const _editSettle = Duration(milliseconds: 500);

  /// Editable folder input with a platform-picker alternative.
  late final TextEditingController _pathController;
  late final FocusNode _pathFocus;

  /// Last value handed to the controller from the draft, so an external change
  /// (Browse) overwrites the box while a half-typed edit is left alone.
  String _pathSyncedFrom = '';

  @override
  void initState() {
    super.initState();
    _pathController = TextEditingController();
    _pathFocus = FocusNode()..addListener(_onPathFocusChange);
    // Re-check a remembered path on entry. The draft persists across restarts
    // and the user reaches this step again by walking Back through the wizard;
    // in both cases the folder may have moved, been deleted, or belong to a
    // different machine since it was picked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final path = ref.read(onboardingDraftProvider).captureDirectory;
      if (path == null || path.trim().isEmpty) {
        unawaited(_suggestDefault());
        return;
      }
      unawaited(_verify(path.trim()));
    });
  }

  /// Start a first run with a folder already chosen and checked, as NINA and
  /// ASIAIR do, instead of an empty box and "Pick a capture folder.". Only on
  /// this machine: a linked host's folders are the host's to suggest.
  Future<void> _suggestDefault() async {
    if (ref.read(isRemoteModeProvider)) return;
    final String? suggested;
    try {
      suggested = await ref.read(onboardingDefaultCaptureDirectoryProvider)();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _check = _FolderCheck.failed;
        _checkDetail = 'Could not make a Skotiq folder in your pictures '
            'folder: ${userFacingError(error)}. Pick a folder instead.';
      });
      return;
    }
    if (suggested == null || !mounted) return;
    final current = ref.read(onboardingDraftProvider).captureDirectory;
    if ((current ?? '').trim().isNotEmpty ||
        _pathController.text.trim().isNotEmpty) {
      return;
    }
    await _commitTypedPath(suggested);
  }

  @override
  void dispose() {
    _editDebounce?.cancel();
    _pathFocus.removeListener(_onPathFocusChange);
    _pathFocus.dispose();
    _pathController.dispose();
    super.dispose();
  }

  /// Tabbing out of the box is how people leave a path field, so commit there
  /// as well as on Enter — otherwise the typed folder is silently dropped.
  void _onPathFocusChange() {
    if (_pathFocus.hasFocus) return;
    unawaited(_commitTypedPath(_pathController.text));
  }

  /// Keep the verdict describing what is in the box.
  ///
  /// A verdict belongs to the text that was checked. The moment the user edits
  /// it away, that verdict is about something they can no longer see, so it goes
  /// — otherwise correcting a rejected path leaves the rejection standing over
  /// a folder that is perfectly good, with nothing on screen to suggest a cure.
  /// The check then re-runs once typing settles, so the field answers for its
  /// own contents without waiting for Enter or for focus to move somewhere else.
  void _onPathChanged(String raw) {
    final path = _resolve(raw);
    if (_check != null && _checkedPath != path) {
      setState(() {
        _check = null;
        _checkedPath = null;
        _checkDetail = null;
      });
    }
    _editDebounce?.cancel();
    if (path.isEmpty) return;
    _editDebounce = Timer(_editSettle, () {
      if (!mounted) return;
      final current =
          ref.read(onboardingDraftProvider).captureDirectory?.trim();
      // Typing back to the folder already on record still deserves an answer;
      // the commit path would take it for a no-op and leave the box silent.
      if (path == current) {
        if (_check == null && !_selecting && !_validating) {
          unawaited(_verify(path));
        }
        return;
      }
      unawaited(_commitTypedPath(raw));
    });
  }

  /// The path a typed string actually names.
  ///
  /// "~/Astro/Captures" is what people paste out of a terminal and dart:io does
  /// not expand it. Only a local path may expand — a tilde in a host path is the
  /// HOST's home, not this machine's.
  String _resolve(String raw) => ref.read(isRemoteModeProvider)
      ? raw.trim()
      : expandCaptureDirHome(raw.trim());

  /// Adopt a hand-typed or pasted folder, subject to the same existence and
  /// writability check the picker's result goes through.
  ///
  /// The draft is written only once the check passes — a typo must not become
  /// the answer that unblocks Next and then a night of frames written nowhere.
  /// The failed text is left in the box so it can be corrected rather than
  /// retyped.
  Future<void> _commitTypedPath(String raw) async {
    _editDebounce?.cancel();
    final path = _resolve(raw);
    final current = ref.read(onboardingDraftProvider).captureDirectory?.trim();
    if (path.isEmpty || path == current) return;
    if (_selecting || _validating) return;

    final operation = _operations.beginLatest();
    setState(() {
      _validating = true;
      _check = null;
      _checkedPath = null;
      _checkDetail = null;
    });
    try {
      // Part of this commit, not a new operation, so its result is this
      // commit's; staying `_validating` keeps the box disabled for the round
      // trip, which stops the focus-loss listener asking a second time.
      await _verify(path, operation: operation);
      if (operation.isStale) return;
      setState(() => _validating = false);
      if (_check == _FolderCheck.writable && _checkedPath == path) {
        await ref.read(onboardingCaptureDirectoryWriterProvider)(path);
      }
    } catch (error) {
      if (operation.isStale) return;
      setState(() {
        _validating = false;
        _check = _FolderCheck.failed;
        _checkDetail = 'Could not set the capture folder: ${userFacingError(error)}';
      });
    } finally {
      if (operation.isCurrent && _validating) {
        setState(() => _validating = false);
      }
    }
  }

  /// Re-run the writability check for [path] and record the outcome.
  ///
  /// Local paths go through the same probe the picker uses. A host path is
  /// checked by the host itself; when there is no host to ask the result is
  /// [_FolderCheck.unverified] — the step says it does not know rather than
  /// claiming a folder on a machine it cannot reach is fine.
  ///
  /// [operation] joins an already-open operation instead of starting a new one.
  /// A caller that keeps working after the check (the typed-path commit, which
  /// still has a draft write to do) must share its scope, or it supersedes
  /// itself and discards its own result.
  Future<void> _verify(String path, {AsyncScope<HostFolders>? operation}) async {
    final scope = operation ?? _operations.beginLatest();
    setState(() {
      _check = _FolderCheck.checking;
      _checkedPath = path;
      _checkDetail = null;
    });

    _FolderCheck outcome;
    String? detail;
    try {
      (outcome, detail) = _describe(await scope.value.check(path));
    } catch (error) {
      outcome = _FolderCheck.unverified;
      detail = 'Could not check this folder: ${userFacingError(error)}';
    }

    if (scope.isStale) return;
    setState(() {
      _check = outcome;
      _checkDetail = detail;
    });
  }

  /// The step's verdict for a [FolderCheck]. Onboarding makes no folder: a
  /// missing one is the operator's to create or correct.
  static (_FolderCheck, String?) _describe(FolderCheck verdict) =>
      switch (verdict) {
        FolderUsable() => (_FolderCheck.writable, null),
        FolderMissing() => (_FolderCheck.failed, 'That folder does not exist.'),
        FolderRefused(:final reason) => (_FolderCheck.failed, reason),
        FolderUnchecked(:final reason) => (_FolderCheck.unverified, reason),
      };

  Future<void> _pickDirectory() async {
    final operation = _operations.beginLatest();
    final folders = operation.value;
    setState(() {
      _selecting = true;
      _check = null;
      _checkedPath = null;
      _checkDetail = null;
    });
    try {
      final picked = await folders.pickChecked(
        context,
        title: ref.read(isRemoteModeProvider)
            ? 'Choose capture folder on host'
            : 'Choose capture folder',
        initialPath: ref.read(onboardingDraftProvider).captureDirectory,
        confirmLabel: 'Use this folder',
      );
      if (picked == null || operation.isStale) return;
      final selected = picked.path;
      final (outcome, detail) = _describe(picked.verdict);
      setState(() {
        _selecting = false;
        _checkedPath = selected;
        _check = outcome;
        _checkDetail = detail;
      });
      if (outcome == _FolderCheck.writable) {
        await ref.read(onboardingCaptureDirectoryWriterProvider)(selected);
      }
    } catch (error) {
      if (operation.isStale) return;
      setState(() {
        _selecting = false;
        _validating = false;
        _check = _FolderCheck.failed;
        _checkDetail = 'Could not set the capture folder: ${userFacingError(error)}';
      });
    } finally {
      if (operation.isCurrent) {
        setState(() {
          _selecting = false;
          _validating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<HostFolders>(hostFoldersProvider, (previous, next) {
      if (previous == null || identical(previous, next)) return;
      // A verdict earned against the previous host says nothing about this one:
      // /mnt/captures may be a real, writable folder on the Pi and not exist at
      // all on the laptop the app just fell back to. Drop the outcome and
      // re-check the remembered path against whoever is answering now.
      _operations.cancelAll();
      setState(() {
        _selecting = false;
        _validating = false;
        _check = null;
        _checkedPath = null;
        _checkDetail = null;
      });
      final path = ref.read(onboardingDraftProvider).captureDirectory;
      if (path != null && path.trim().isNotEmpty) {
        unawaited(_verify(path.trim()));
      }
    });
    final draft = ref.watch(onboardingDraftProvider);
    final colors = SkotiqColors.of(context);

    // Mirror the stored folder into the box whenever it changes underneath us
    // (Browse, a host switch, a resumed draft) without stamping on an edit the
    // user is in the middle of typing.
    final storedPath =
        draft.captureDirectory == null ? '' : draft.captureDirectory!;
    if (storedPath != _pathSyncedFrom) {
      _pathSyncedFrom = storedPath;
      if (_pathController.text != storedPath) {
        _pathController.value = TextEditingValue(
          text: storedPath,
          selection: TextSelection.collapsed(offset: storedPath.length),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      // Hug the content: the panel this sits in is sized to what the step
      // needs, and a Column that fills brings back the empty card of F5.
      mainAxisSize: MainAxisSize.min,
      children: [
        const SectionTitle(
          icon: SkotiqIcons.folder,
          title: 'Where should we save captures?',
        ),
        // Describe the naming pattern, which is what actually controls layout.
        // The shipped default is `$TARGET_$FILTER_$DATE_$SEQ` — flat, so every
        // frame lands directly in the chosen folder. Subfolders are real (a `/`
        // in the pattern creates directories) but are not the default.
        Text(
          'Every capture is saved here. File names — and any subfolders — come '
          'from the naming pattern in Settings → Imaging.',
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        // NOT inside a `well`: a field's own fill is the well tone, so the
        // path box had no edge against the block behind it.
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: SkotiqTextField(
                    key: onboardingCaptureDirFieldKey,
                    controller: _pathController,
                    focusNode: _pathFocus,
                    enabled: !_selecting && !_validating,
                    prefixIcon: SkotiqIcons.folder,
                    hint: 'Type or paste a folder, or use Browse',
                    mono: true,
                    onChanged: _onPathChanged,
                    onSubmitted: (value) => unawaited(_commitTypedPath(value)),
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                SkotiqButton(
                  icon: SkotiqIcons.folderOpen,
                  label: 'Browse',
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: _selecting || _validating ? null : _pickDirectory,
                ),
              ],
            ),
            if (_selecting ||
                _validating ||
                _check == _FolderCheck.checking) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              Row(
                children: [
                  if (_selecting)
                    Icon(
                      SkotiqIcons.folderOpen,
                      size: SkotiqTokens.iconXs,
                      color: colors.primary,
                    )
                  else
                    SizedBox(
                      width: SkotiqTokens.iconXs,
                      height: SkotiqTokens.iconXs,
                      child: SkotiqSpinner(
                          size: SkotiqTokens.iconXs, color: colors.primary),
                    ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Text(
                    _selecting
                        ? 'Waiting for folder selection…'
                        : 'Checking write permissions…',
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ] else
              ..._buildVerdict(colors, draft.captureDirectory),
          ],
        ),
      ],
    );
  }

  /// The one line under the folder row that states what is known about it.
  ///
  /// Every branch is backed by a check that ran: the success line appears only
  /// for the folder the last passing check actually looked at, and a folder that
  /// could not be reached is reported as unknown instead of being folded into
  /// either verdict.
  List<Widget> _buildVerdict(
    SkotiqColors colors,
    String? draftPath,
  ) {
    Widget line(IconData icon, Color color, String message) => Padding(
          padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: SkotiqTokens.iconSm, color: color),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  message,
                  style: SkotiqTypography.bodySm.copyWith(color: color),
                ),
              ),
            ],
          ),
        );

    switch (_check) {
      case _FolderCheck.failed:
        return [
          line(
            SkotiqIcons.warning,
            colors.error,
            _checkDetail ?? 'That folder cannot be used.',
          ),
        ];
      case _FolderCheck.unverified:
        return [
          line(
            SkotiqIcons.info,
            colors.warning,
            '${_checkDetail ?? 'This folder could not be checked.'} '
            'Skotiq has not confirmed it is writable.',
          ),
        ];
      case _FolderCheck.writable:
        // Only for the folder the check examined. A draft path that has since
        // changed has not been checked, and silence is honest where a green
        // tick would not be.
        if (draftPath != null && draftPath.trim() == _checkedPath) {
          return [
            line(
                LucideIcons.checkCircle2, colors.success, 'Folder is writable.')
          ];
        }
        return const [];
      case _FolderCheck.checking:
      case null:
        return const [];
    }
  }
}
