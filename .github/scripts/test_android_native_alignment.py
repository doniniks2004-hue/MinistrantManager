import struct
import tempfile
import unittest
from pathlib import Path
import zipfile

from android_native_alignment import check_elf, check_package


def elf(alignment=16384, address=0):
    data = bytearray(120)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 1)
    struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0, address, 0, 120, 120, alignment)
    return data


class NativeAlignmentTest(unittest.TestCase):
    def test_16k_and_64k_segments(self):
        for alignment in (16384, 65536):
            check_elf(elf(alignment))

    def test_rejects_4k_and_invalid_alignment(self):
        for alignment in (0, 4096, 24576):
            with self.assertRaises(ValueError):
                check_elf(elf(alignment))

    def test_rejects_misaligned_virtual_address(self):
        with self.assertRaises(ValueError):
            check_elf(elf(address=4096))

    def test_rejects_missing_or_truncated_headers(self):
        for data in (b'not ELF', elf()[:100], bytes(120)):
            with self.assertRaises(ValueError):
                check_elf(data)

    def package(self, root, suffix, data, compression=zipfile.ZIP_STORED, padded=False):
        path = root / ('app' + suffix)
        prefix = 'base/lib/' if suffix == '.aab' else 'lib/'
        entry = zipfile.ZipInfo(prefix + 'arm64-v8a/libtest.so')
        entry.compress_type = compression
        if padded:
            length = (-(30 + len(entry.filename))) % 16384
            entry.extra = struct.pack('<HH', 0xffff, length - 4) + bytes(length - 4)
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr(entry, data)
        return path

    def test_apk_needs_zip_alignment_but_bundle_does_not(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(ValueError, 'entry offset'):
                check_package(self.package(root, '.apk', elf()))
            self.assertEqual(check_package(self.package(root, '.apk', elf(), padded=True)), 1)
            self.assertEqual(check_package(self.package(root, '.aab', elf())), 1)
            self.assertEqual(check_package(self.package(root, '.apk', elf(), zipfile.ZIP_DEFLATED)), 1)

    def test_compression_does_not_fix_bad_elf(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, 'PT_LOAD alignment'):
                check_package(self.package(Path(temp), '.aab', elf(4096), zipfile.ZIP_DEFLATED))

    def test_empty_package_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'empty.apk'
            with zipfile.ZipFile(path, 'w'):
                pass
            with self.assertRaisesRegex(ValueError, 'no 64-bit'):
                check_package(path)


if __name__ == '__main__':
    unittest.main()
