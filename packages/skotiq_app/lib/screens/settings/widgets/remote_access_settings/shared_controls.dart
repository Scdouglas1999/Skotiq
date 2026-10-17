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

class _RemoteAccessNoticeCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;

  const _RemoteAccessNoticeCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccessActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String url;
  final String primaryLabel;
  final IconData primaryIcon;
  final VoidCallback onPrimary;
  final String secondaryLabel;
  final IconData secondaryIcon;
  final VoidCallback onSecondary;

  const _AccessActionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.url,
    required this.primaryLabel,
    required this.primaryIcon,
    required this.onPrimary,
    required this.secondaryLabel,
    required this.secondaryIcon,
    required this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            ),
            child: SelectableText(
              url,
              style: SkotiqTypography.readoutSm.copyWith(
                color: colors.primary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SkotiqButton(
                label: primaryLabel,
                icon: primaryIcon,
                variant: ButtonVariant.primary,
                size: ButtonSize.small,
                onPressed: onPrimary,
              ),
              SkotiqButton(
                label: secondaryLabel,
                icon: secondaryIcon,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: onSecondary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
