import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import stage_linux_libraw as staging


def elf_fixture(jpeg=True):
    def names(path):
        if path.name == 'libskotiq_bridge.so':
            return None, ['libraw.so.20', 'libc.so.6']
        return 'libraw.so.20', (['libjpeg.so.8'] if jpeg else []) + ['libc.so.6']
    return names


class LibRawStagingTests(unittest.TestCase):
    def test_stages_only_libraw_and_its_resolved_jpeg_abi(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            raw = root / 'libraw.so.20'
            jpeg = root / 'libjpeg.so.8'
            raw.touch()
            jpeg.touch()
            libraries = {'libraw.so.20': raw, 'libjpeg.so.8': jpeg,
                         'libraw.so.19': root / 'old-libraw.so.19',
                         'libc.so.6': root / 'libc.so.6'}
            libraries['libraw.so.19'].touch()
            with patch.object(staging, 'elf_names', side_effect=elf_fixture()), \
                    patch.object(staging, 'stage_library', return_value={}) as copy:
                staging.stage(root, libraries)
            self.assertEqual(copy.call_args_list[0].args,
                             (raw, root, 'libraw-copyright.txt'))
            self.assertEqual(copy.call_args_list[1].args,
                             (jpeg, root, 'libjpeg-turbo-copyright.txt'))
            self.assertEqual(copy.call_count, 2)

    def test_missing_jpeg_abi_refuses_before_staging(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'raw').touch()
            with patch.object(staging, 'elf_names', side_effect=elf_fixture()), \
                    patch.object(staging, 'stage_library') as copy:
                with self.assertRaisesRegex(FileNotFoundError, 'libjpeg.so.8'):
                    staging.stage(root, {'libraw.so.20': root / 'raw'})
            copy.assert_not_called()

    def test_libraw_without_jpeg_does_not_copy_unrelated_codec(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'raw').touch()
            with patch.object(staging, 'elf_names', side_effect=elf_fixture(jpeg=False)), \
                    patch.object(staging, 'stage_library', return_value={}) as copy:
                staging.stage(root, {'libraw.so.20': root / 'raw',
                                     'libjpeg.so.8': root / 'jpeg'})
            self.assertEqual(copy.call_count, 1)

    def test_different_installed_libraw_abi_does_not_satisfy_bridge(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            old = root / 'libraw.so.19'
            old.touch()
            with patch.object(staging, 'elf_names', side_effect=elf_fixture()), \
                    patch.object(staging, 'stage_library') as copy:
                with self.assertRaisesRegex(FileNotFoundError, 'Bridge needs libraw.so.20'):
                    staging.stage(root, {'libraw.so.19': old})
            copy.assert_not_called()


if __name__ == '__main__':
    unittest.main()
