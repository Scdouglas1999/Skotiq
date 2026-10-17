import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'imaging_naming_pattern.dart';
import 'settings_widgets.dart';

class ImagingSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const ImagingSettings({super.key, this.isMobile = false});

  @override
  ConsumerState<ImagingSettings> createState() => _ImagingSettingsState();
}

class _ImagingSettingsState extends ConsumerState<ImagingSettings> {
  final _patternController = TextEditingController();
  String? _patternError;

  @override
  void dispose() {
    _patternController.dispose();
    super.dispose();
  }

  /// Refuse to persist a pattern the capture pipeline would reject.
  ///
  /// Throwing makes [SettingsTextInput] roll the field back to the last
  /// confirmed value, so the field never shows a value the DB does not hold.
  /// Without this the bad pattern was stored happily and only surfaced as a
  /// failed exposure — losing the frame that discovered it.
  Future<void> _commitPattern(String value) async {
    final check = checkNamingPattern(value);
    if (!check.isValid) {
      if (mounted) setState(() => _patternError = check.error);
      throw ArgumentError.value(value, 'fileNamingPattern', check.error);
    }
    if (mounted) setState(() => _patternError = null);
    await ref.read(appSettingsProvider.notifier).setFileNamingPattern(value);
  }

  /// Rejection reason for the last refused edit, otherwise the example path
  /// the *saved* pattern resolves to, so the operator can see the shape of
  /// tonight's filenames without capturing a frame first.
  ///
  /// A pattern persisted before this validation existed (or written by a
  /// remote host) is reported the same way, rather than sitting silently in
  /// the field until the first exposure of the night fails.
  Widget _patternFeedback(String savedPattern) {
    final colors = SkotiqColors.of(context);
    final saved = checkNamingPattern(savedPattern);
    final error = _patternError ?? saved.error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          SkotiqTokens.spaceMd,
          0,
          SkotiqTokens.spaceMd,
          SkotiqTokens.spaceSm,
        ),
        child: Text(
          error,
          key: const Key('imaging.namingPattern.error'),
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.error,
          ),
        ),
      );
    }
    final preview = saved.preview!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceMd,
        0,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceSm,
      ),
      child: Text(
        'Example: $preview',
        key: const Key('imaging.namingPattern.preview'),
        style: SkotiqTypography.monoCaption.copyWith(
          color: colors.textMuted,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => SettingsLoadingState(
        isMobile: widget.isMobile,
      ),
      error: (error, stack) => SettingsErrorState(
        isMobile: widget.isMobile,
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final authority = ref.watch(backendProvider);

        return SettingsPage(
          title: 'Imaging',
          description: 'Default capture settings',
          isMobile: widget.isMobile,
          hideHeader: widget.isMobile,
          children: [
            SettingsSection(
              title: 'File format',
              isMobile: widget.isMobile,
              children: [
                SettingRow(
                  icon: LucideIcons.file,
                  title: 'Archive format',
                  subtitle:
                      'Captured images are saved as lossless 16-bit FITS files',
                  trailing: Text(
                    '$kCaptureImageFormat · $kCaptureBitDepth',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  isMobile: widget.isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.fileText,
                  title: 'File naming pattern',
                  subtitle:
                      r'Variables: $TARGET, $FILTER, $DATE, $SEQ, $EXPOSURE',
                  trailing: SettingsTextInput(
                    controller: _patternController,
                    authoritativeValue: settings.fileNamingPattern,
                    authorityKey: authority,
                    width: widget.isMobile ? 160 : 220,
                    onChanged: _commitPattern,
                    isMobile: widget.isMobile,
                  ),
                  isLast: true,
                  isMobile: widget.isMobile,
                  stackOnMobile: widget.isMobile,
                ),
                _patternFeedback(settings.fileNamingPattern),
              ],
            ),
          ],
        );
      },
    );
  }
}
