import plistlib
from pathlib import Path
import struct
import tempfile
import unittest

from scripts.verify_ios_minimum import inspect_app, macho_slices


def thin(minimum=0x000c0000, *, modern=True, platform=2, cpu=0x100000c, endian='<', wide=True):
    command = (struct.pack(endian + '6I', 0x32, 24, platform, minimum, 0x00120000, 0)
               if modern else struct.pack(endian + '4I', 0x25, 16, minimum, 0x00120000))
    header = struct.pack(endian + '7I', 0xfeedfacf if wide else 0xfeedface, cpu, 0, 2, 1, len(command), 0)
    return header + (b'\0' * 4 if wide else b'') + command


def fat(*slices, wide=False):
    stride = 32 if wide else 20
    offset = 8 + stride * len(slices)
    table = b''
    for data in slices:
        cpu = struct.unpack_from('<I', data, 4)[0]
        table += struct.pack('>IIQQII' if wide else '>IIIII', cpu, 0, offset, len(data), 0, *([0] if wide else []))
        offset += len(data)
    return struct.pack('>II', 0xcafebabf if wide else 0xcafebabe, len(slices)) + table + b''.join(slices)


class MinimumTests(unittest.TestCase):
    def test_both_load_commands_endians_and_header_sizes(self):
        for modern in (False, True):
            for endian in ('<', '>'):
                for wide in (False, True):
                    self.assertEqual(macho_slices(thin(modern=modern, endian=endian, wide=wide))[0]['minimum_os'], '12.0.0')

    def test_every_universal_architecture_checked(self):
        for wide in (False, True):
            self.assertEqual(len(macho_slices(fat(thin(cpu=12), thin(), wide=wide))), 2)
            with self.assertRaisesRegex(ValueError, 'above 12.0'):
                macho_slices(fat(thin(), thin(0x000d0000), wide=wide))

    def test_reject_simulator_missing_and_truncated_data(self):
        samples = [thin(platform=7), thin(cpu=0x1000007), b'garbage', thin()[:-1],
                   struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0), fat(thin())[:-1]]
        for data in samples:
            with self.subTest(data=data), self.assertRaises(ValueError):
                macho_slices(data)

    def test_reject_bad_command_bounds(self):
        data = bytearray(thin())
        struct.pack_into('<I', data, 36, 0)
        with self.assertRaises(ValueError):
            macho_slices(bytes(data))

    def test_app_frameworks_and_unrecognized_dylib(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'Runner.app'
            framework = app / 'Frameworks' / 'Example.framework'
            framework.mkdir(parents=True)
            for bundle, executable in ((app, 'Runner'), (framework, 'Example')):
                (bundle / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '12.0', 'CFBundleExecutable': executable}))
                (bundle / executable).write_bytes(thin())
            result = inspect_app(app)
            self.assertTrue(result['passed'], result)
            self.assertEqual(len(result['binaries']), 2)
            (framework / 'Example').write_bytes(thin(0x000f0000))
            self.assertFalse(inspect_app(app)['passed'])
            (framework / 'Example').write_bytes(thin())
            (app / 'Frameworks' / 'unrecognized.dylib').write_bytes(b'not a Mach-O')
            self.assertFalse(inspect_app(app)['passed'])

    def test_missing_bundle_executable_and_wrong_app_minimum(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '11.0', 'CFBundleExecutable': 'Runner'}))
            (app / 'Runner').write_bytes(thin(0x000b0000))
            self.assertFalse(inspect_app(app)['passed'])
            (app / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '12.0', 'CFBundleExecutable': 'Missing'}))
            self.assertFalse(inspect_app(app)['passed'])


if __name__ == '__main__':
    unittest.main()
