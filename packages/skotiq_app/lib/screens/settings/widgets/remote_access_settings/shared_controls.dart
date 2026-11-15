part of '../remote_access_settings.dart';

class _PortRangeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;
    final port = int.tryParse(newValue.text);
    if (port == null) return oldValue;
    if (port > 65535) return oldValue;
    return newValue;
  }
}

/// One way to open the dashboard: what it is, the link, and the buttons that
/// open or copy it.
class _DashboardLinkRow extends StatelessWidget {
  const _DashboardLinkRow({
    required this.title,
    required this.description,
    required this.url,
    required this.actions,
  });

  final String title;
  final String description;
  final String url;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final narrow = SettingsFormScope.narrowOf(context);
    final buttons = Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      children: actions,
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: SettingsItem.titleStyle(context)),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          description,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        SelectableText(
          url,
          style: SkotiqTypography.readoutSm.copyWith(color: colors.textPrimary),
        ),
      ],
    );
    return SettingsItem(
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                text,
                const SizedBox(height: SkotiqTokens.spaceMd),
                buttons,
              ],
            )
          : Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: SkotiqTokens.space2xl),
                buttons,
              ],
            ),
    );
  }
}

/// Look up a localization [key], falling back to [fallback] when the key is
/// not present in the active locale's table.
///
/// [SkotiqLocalizations.text] returns the *key itself* for an unknown key
/// (see its `?? key` tail). The Tailscale strings introduced here are new and
/// may not yet exist in every `skotiq_localizations.dart` table; routing
/// them through this helper keeps the i18n contract live — a translator who
/// adds the key later wins automatically — while guaranteeing we never render a
/// raw `remoteAccessTailscale…` identifier to the operator. [params] tokens are
/// substituted into whichever string is used.
String _l10nOr(
  SkotiqLocalizations l10n,
  String key,
  String fallback, {
  Map<String, String> params = const {},
}) {
  final resolved = l10n.text(key, params: params);
  if (resolved != key) {
    return resolved;
  }
  var value = fallback;
  params.forEach((paramKey, paramValue) {
    value = value.replaceAll('{$paramKey}', paramValue);
  });
  return value;
}
