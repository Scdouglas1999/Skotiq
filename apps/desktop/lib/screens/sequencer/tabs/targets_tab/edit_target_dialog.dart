part of '../targets_tab.dart';

class EditTargetDialog extends ConsumerStatefulWidget {
  final dynamic target;

  const EditTargetDialog({super.key, required this.target});

  @override
  ConsumerState<EditTargetDialog> createState() => _EditTargetDialogState();
}

class _EditTargetDialogState extends ConsumerState<EditTargetDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _catalogIdController;
  late final TextEditingController _raController;
  late final TextEditingController _decController;
  late String _objectType;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.target.name);
    _catalogIdController = TextEditingController(
      text: widget.target.catalogId ?? '',
    );
    _raController = TextEditingController(text: widget.target.ra.toString());
    _decController = TextEditingController(text: widget.target.dec.toString());
    _objectType = widget.target.objectType ?? 'Nebula';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _catalogIdController.dispose();
    _raController.dispose();
    _decController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return SkotiqDialog(
      title: 'Edit Target',
      icon: LucideIcons.pencil,
      width: 400,
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.pop(context),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          label: 'Save Changes',
          icon: LucideIcons.check,
          size: ButtonSize.small,
          onPressed: () {
            final ra = double.tryParse(_raController.text);
            final dec = double.tryParse(_decController.text);

            if (_nameController.text.isNotEmpty && ra != null && dec != null) {
              ref
                  .read(targetsDaoProvider)
                  .updateTarget(
                    widget.target.copyWith(
                      name: _nameController.text,
                      catalogId: _catalogIdController.text.isEmpty
                          ? null
                          : _catalogIdController.text,
                      ra: ra,
                      dec: dec,
                      objectType: _objectType,
                    ),
                  );
              Navigator.pop(context);
            }
          },
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildField(colors, 'Name', _nameController, 'e.g., Orion Nebula'),
          _buildField(
            colors,
            'Catalog ID',
            _catalogIdController,
            'e.g., M42, NGC 7000',
          ),
          _buildField(colors, 'RA (hours)', _raController, 'e.g., 5.588'),
          _buildField(colors, 'Dec (degrees)', _decController, 'e.g., -5.391'),
          Text(
            'Object Type',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              fontWeight: FontWeight.w600,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
              border: Border.all(color: colors.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _objectType,
                isExpanded: true,
                dropdownColor: colors.surface,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize13,
                  color: colors.textPrimary,
                ),
                items:
                    ['Galaxy', 'Nebula', 'Cluster', 'Star', 'Planet', 'Other']
                        .map(
                          (type) =>
                              DropdownMenuItem(value: type, child: Text(type)),
                        )
                        .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _objectType = value);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField(
    SkotiqColors colors,
    String label,
    TextEditingController controller,
    String hint,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              fontWeight: FontWeight.w600,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
              border: Border.all(color: colors.border),
            ),
            child: TextField(
              controller: controller,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize13,
                color: colors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                  fontSize: SkotiqTypography.fontSize13,
                  color: colors.textMuted,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
