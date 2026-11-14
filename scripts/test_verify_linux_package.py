import unittest

from verify_linux_package import validate_fits


def fits(width=128, exposure='0.01'):
    fields = {'SIMPLE': 'T', 'BITPIX': '16', 'NAXIS': '2',
              'NAXIS1': str(width), 'NAXIS2': '96',
              'OBJECT': "'Package smoke simulator'", 'EXPTIME': exposure,
              'DATE-OBS': "'2026-11-14T16:00:00'"}
    header = ''.join(f'{key:<8}= {value}'.ljust(80) for key, value in fields.items())
    return (header + 'END'.ljust(80)).ljust(2880).encode('ascii') + bytes(128 * 96 * 2)


class PackageSmokeTests(unittest.TestCase):
    def test_actual_geometry_and_payload_required(self):
        self.assertEqual(validate_fits(fits())['NAXIS1'], '128')
        with self.assertRaisesRegex(ValueError, 'NAXIS1'):
            validate_fits(fits(width=64))
        with self.assertRaisesRegex(ValueError, 'truncated'):
            validate_fits(fits()[:3000])

    def test_exposure_metadata_must_match_capture(self):
        with self.assertRaisesRegex(ValueError, 'exposure metadata'):
            validate_fits(fits(exposure='30'))


if __name__ == '__main__':
    unittest.main()
