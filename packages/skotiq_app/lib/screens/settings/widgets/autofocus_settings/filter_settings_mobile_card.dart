part of '../autofocus_settings.dart';

class _FilterSettingsMobileCard extends StatelessWidget {
  final int position;
  final String filterName;
  final FilterAutofocusConfig config;
  final List<String> allFilterNames;
  final bool isLast;
  final _FilterConfigUpdate onConfigChanged;

  const _FilterSettingsMobileCard({
    required this.position,
    required this.filterName,
    required this.config,
    required this.allFilterNames,
    required this.isLast,
    required this.onConfigChanged,
  });

  @override
  Widget build(BuildContext context) {
    final fields = _FilterAfFields(
      filterName: filterName,
      config: config,
      allFilterNames: allFilterNames,
      onConfigChanged: onConfigChanged,
      height: 32,
      defaultHint: 'default',
      flexibleDropdowns: true,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: SkotiqColors.of(context).border.withValues(alpha: 0.5),
                ),
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: position + name
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: SkotiqDecorations.chip(SkotiqColors.of(context),
                    tone: SkotiqColors.of(context).primary),
                child: Center(
                  child: Text(
                    '${position}',
                    style: SkotiqTypography.caption
                        .copyWith(fontWeight: FontWeight.w600)
                        .copyWith(color: SkotiqColors.of(context).primary),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                filterName,
                style: SkotiqTypography.bodyStrong
                    .copyWith(color: SkotiqColors.of(context).textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Settings grid (2 columns)
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _buildMobileField(context, 'Focus Offset', fields.focusOffset),
              _buildMobileField(context, 'AF Exp Time', fields.exposure),
              _buildMobileField(context, 'AF Filter', fields.afFilter),
              _buildMobileField(context, 'Binning', fields.binning),
              _buildMobileField(context, 'Gain', fields.gain),
              _buildMobileField(context, 'Offset', fields.offset),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMobileField(BuildContext context, String label, Widget input) {
    return SizedBox(
      width: 140,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: SkotiqTypography.eyebrow.copyWith(
              color: SkotiqColors.of(context).textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          input,
        ],
      ),
    );
  }
}
