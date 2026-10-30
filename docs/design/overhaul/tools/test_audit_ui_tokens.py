import unittest
from audit_ui_tokens import violations

class UiTokenAuditTest(unittest.TestCase):
    def test_blocks_literal_and_conditional_values(self):
        for source in (
            'color: const Color(0xFFA48CF2)', 'color: Colors.purple',
            'fontSize: 12', 'fontSize: compact ? 12 : 14',
            'fontSize: compact ? token : 14',
            'BorderRadius.circular(8)', 'Radius.circular(compact ? 12 : 16)',
            'extensions: [SkotiqColors.dark]',
            'SliderThemeData(trackHeight: 4)',
            "fontFamily: 'monospace'",
        ):
            with self.subTest(source=source):
                self.assertTrue(violations(source))

    def test_accepts_tokens_geometry_and_comment_examples(self):
        for source in (
            'fontSize: SkotiqTypography.fontSize12',
            'fontSize: compact ? SkotiqTypography.fontSize12 : null',
            'fontSize: label.fontSize! * zoom.clamp(0.5, 2.0)',
            'Radius.circular(height / 2)', 'color: Colors.transparent',
            'color: context.skotiqColors.primary',
            '// Color(0xFF000000)\n/* fontSize: 12 */',
        ):
            with self.subTest(source=source):
                self.assertEqual(violations(source), [])

if __name__ == '__main__':
    unittest.main()
