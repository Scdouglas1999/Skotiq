import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';
import 'admin_only.dart';

/// Where catalog downloads come from, for self-hosters: a mirror of the
/// catalog release asked before each catalog's own site. The editor stays
/// folded away behind "Change"; most installs never need it.
class CatalogDownloadSourceCard extends ConsumerStatefulWidget {
  const CatalogDownloadSourceCard({super.key});

  @override
  ConsumerState<CatalogDownloadSourceCard> createState() =>
      _CatalogDownloadSourceCardState();
}

class _CatalogDownloadSourceCardState
    extends ConsumerState<CatalogDownloadSourceCard> {
  final _controller = TextEditingController();
  bool _open = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle(String saved) {
    setState(() {
      _open = !_open;
      _error = null;
      if (_open) _controller.text = saved;
    });
  }

  Future<void> _save(String url) async {
    final trimmed = url.trim();
    final problem = trimmed.isEmpty ? null : catalogBaseUrlProblem(trimmed);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(appSettingsProvider.notifier).setCatalogBaseUrl(trimmed);
      if (!mounted) return;
      setState(() => _open = false);
      context.showSuccessSnackBar(
        trimmed.isEmpty
            ? 'Catalogs download from the Skotiq release again.'
            : 'Catalogs now download from $trimmed first.',
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not save: ${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final settings = ref.watch(appSettingsProvider);
    final saved = settings.valueOrNull?.catalogBaseUrl ?? '';
    final linked = ref.watch(isRemoteModeProvider);
    final adminOnlyRefused = hostRefusesAdminOnly(ref);
    final bodyStyle = SkotiqTypography.bodySm.copyWith(
      color: colors.textSecondary,
    );

    return SkotiqPanel(
      head: PanelHead(
        label: 'Download source',
        icon: LucideIcons.server,
        trailing: [
          if (!adminOnlyRefused)
            SkotiqButton(
              label: _open ? 'Close' : 'Change',
              icon: _open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: settings.hasValue ? () => _toggle(saved) : null,
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            settings.hasError
                ? 'The download source could not be read: '
                    '${userFacingError(settings.error!)}'
                : saved.isEmpty
                    ? 'Catalogs download from the Skotiq release on GitHub, '
                        "then from each catalog's own site."
                    : 'Catalogs download from your mirror first, then from '
                        "each catalog's own site.",
            style: bodyStyle.copyWith(
              color: settings.hasError ? colors.warning : null,
            ),
          ),
          if (saved.isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            SelectableText(
              saved,
              style: SkotiqTypography.readoutXs.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ],
          if (adminOnlyRefused) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            const Align(
              alignment: AlignmentDirectional.centerStart,
              child: AdminOnlyNotice(),
            ),
          ] else if (_open) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            Text(
              'For a self-hosted copy of the catalog release. Skotiq adds each '
              "catalog's file name to this address and checks the download "
              'against the published checksum, so a mirror must hold the same '
              'files.${linked ? ' This is the imaging host\'s setting; '
                  'downloads to this computer use it too.' : ''}',
              style: bodyStyle,
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqTextField(
              controller: _controller,
              label: 'Mirror address',
              hint: kCatalogReleaseBaseUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              enabled: !_saving,
              errorText: _error,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: _save,
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              children: [
                if (saved.isNotEmpty)
                  SkotiqButton(
                    label: 'Reset to default',
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                    onPressed: _saving ? null : () => _save(''),
                  ),
                SkotiqButton(
                  label: 'Save',
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                  isLoading: _saving,
                  onPressed: _saving ? null : () => _save(_controller.text),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
