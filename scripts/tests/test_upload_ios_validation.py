from __future__ import annotations

import copy
from pathlib import Path, PurePosixPath
import plistlib
import tempfile
import unittest

from scripts.prepare_upload_ios_framework import copy_framework, select_framework
from scripts.run_upload_ios_tests import command, passed_methods, simulator
from scripts.verify_upload_ios_project import HOST, TESTS, OpenStep, read_project, validate

ROOT = Path(__file__).resolve().parents[2]


class UploadProjectTests(unittest.TestCase):
    def setUp(self):
        self.project = read_project(ROOT / 'ios/Runner.xcodeproj/project.pbxproj')

    def target(self, name):
        return next(value for value in self.project['objects'].values()
                    if value['isa'] == 'PBXNativeTarget' and value['name'] == name)

    def test_real_project_wires_isolated_host_and_all_tests(self):
        result = validate(ROOT, self.project)
        self.assertTrue(result['structure_passed'])
        self.assertFalse(result['xcode_build_executed'])
        self.assertEqual(result['host_sources'], 7)
        self.assertEqual(result['test_sources'], 3)
        self.assertEqual(result['minimum_ios'], '12.0')

    def test_parser_rejects_duplicate_ids_and_accepts_comments_and_paths(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            OpenStep('{ a = 1; a = 2; }').parse()
        value = OpenStep('// header\n{ a/*comment*/ = ../path/file; b = ("escaped\\\"quote",); }').parse()
        self.assertEqual(value, {'a': '../path/file', 'b': ['escaped"quote']})

    def test_dangling_object_reference_is_rejected(self):
        self.target(TESTS)['dependencies'].append('FFFFFFFFFFFFFFFFFFFFFFFF')
        with self.assertRaisesRegex(ValueError, 'Dangling'):
            validate(ROOT, self.project)

    def test_accidentally_compiling_runner_delegate_is_rejected(self):
        objects = self.project['objects']
        runner = self.target('Runner')
        runner_sources = next(objects[key] for key in runner['buildPhases'] if objects[key]['isa'] == 'PBXSourcesBuildPhase')
        app_delegate = next(key for key in runner_sources['files']
                            if objects[objects[key]['fileRef']].get('path') == 'AppDelegate.swift')
        host_sources = next(objects[key] for key in self.target(HOST)['buildPhases'] if objects[key]['isa'] == 'PBXSourcesBuildPhase')
        host_sources['files'].append(app_delegate)
        with self.assertRaisesRegex(ValueError, 'isolated app delegate'):
            validate(ROOT, self.project)

    def test_unsafe_bundle_test_host_minimum_or_platform_is_rejected(self):
        objects = self.project['objects']
        config_id = objects[self.target(TESTS)['buildConfigurationList']]['buildConfigurations'][0]
        samples = [('TEST_HOST', '$(BUILT_PRODUCTS_DIR)/Runner.app/Runner', 'outside'),
                   ('PRODUCT_BUNDLE_IDENTIFIER', 'com.oviewer.oviewer', 'isolated'),
                   ('IPHONEOS_DEPLOYMENT_TARGET', '13.0', 'iOS 12'),
                   ('SUPPORTED_PLATFORMS', 'iphoneos', 'simulator-only')]
        for key, value, reason in samples:
            with self.subTest(setting=key):
                project = copy.deepcopy(self.project)
                project['objects'][config_id]['buildSettings'][key] = value
                with self.assertRaisesRegex(ValueError, reason):
                    validate(ROOT, project)


class UploadFrameworkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.sdk = self.root / 'Flutter SDK'
        self.sdk.mkdir()
        (self.sdk / 'version').write_text('3.16.0\n', encoding='utf-8')
        self.xcframework = self.sdk / 'bin/cache/artifacts/engine/ios/Flutter.xcframework'
        self.framework = self.xcframework / 'ios-arm64_x86_64-simulator/Flutter.framework'
        (self.framework / 'Headers').mkdir(parents=True)
        (self.framework / 'Modules').mkdir()
        (self.framework / 'Flutter').write_bytes(b'simulator-test-fixture')
        (self.framework / 'Headers/Flutter.h').write_text('// fixture', encoding='utf-8')
        (self.framework / 'Modules/module.modulemap').write_text('// fixture', encoding='utf-8')
        (self.framework / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '11.0'}))
        self.manifest = {'AvailableLibraries': [{'LibraryIdentifier': 'ios-arm64_x86_64-simulator',
                         'LibraryPath': 'Flutter.framework', 'SupportedPlatform': 'ios',
                         'SupportedPlatformVariant': 'simulator', 'SupportedArchitectures': ['arm64', 'x86_64']}]}
        self.write_manifest()

    def tearDown(self):
        self.temp.cleanup()

    def write_manifest(self):
        (self.xcframework / 'Info.plist').write_bytes(plistlib.dumps(self.manifest))

    def test_selects_compatible_simulator_slice_and_copies_only_owned_product(self):
        source = select_framework(self.sdk, {'arm64'})
        self.assertEqual(source, self.framework.resolve())
        products = self.root / 'Build Products'
        products.mkdir()
        unrelated = products / 'Runner.app'
        unrelated.mkdir()
        (unrelated / 'keep').write_text('keep', encoding='utf-8')
        target = copy_framework(source, products)
        (target / 'obsolete').write_text('old generated file', encoding='utf-8')
        copy_framework(source, products)
        self.assertEqual((target / 'Flutter').read_bytes(), b'simulator-test-fixture')
        self.assertFalse((target / 'obsolete').exists())
        self.assertEqual((unrelated / 'keep').read_text(), 'keep')

    def test_device_slice_and_incompatible_architecture_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'compatible'):
            select_framework(self.sdk, {'armv7'})
        self.manifest['AvailableLibraries'][0].pop('SupportedPlatformVariant')
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'compatible'):
            select_framework(self.sdk, {'arm64'})

    def test_framework_path_cannot_escape_the_sdk_xcframework(self):
        self.manifest['AvailableLibraries'][0]['LibraryIdentifier'] = '../../../../../outside'
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'Invalid Flutter framework path'):
            select_framework(self.sdk, {'arm64'})

    def test_wrong_flutter_version_or_higher_minimum_is_rejected(self):
        (self.sdk / 'version').write_text('3.13.9', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, '3.16.0'):
            select_framework(self.sdk, {'arm64'})
        (self.sdk / 'version').write_text('3.16.0', encoding='utf-8')
        (self.framework / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '13.0'}))
        with self.assertRaisesRegex(ValueError, 'iOS 12'):
            select_framework(self.sdk, {'arm64'})


class UploadXcodeRunnerTests(unittest.TestCase):
    def test_only_available_ios_simulator_identifiers_are_accepted(self):
        devices = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-18-0': [
            {'udid': 'A', 'isAvailable': True, 'name': 'Isolated simulator'},
            {'udid': 'B', 'isAvailable': False}]}}
        self.assertEqual(simulator(devices, 'A')['udid'], 'A')
        for identifier in ['B', 'physical-device']:
            with self.assertRaises(ValueError):
                simulator(devices, identifier)
        with self.assertRaisesRegex(ValueError, 'iOS Simulator'):
            simulator({'devices': {'com.apple.CoreSimulator.SimRuntime.tvOS-18-0': devices['devices']['com.apple.CoreSimulator.SimRuntime.iOS-18-0']}}, 'A')

    def test_command_uses_only_isolated_scheme_and_serial_simulator_tests(self):
        args = command(PurePosixPath('/repo'), PurePosixPath('/Flutter SDK'), 'A', PurePosixPath('/results'))
        self.assertEqual(args[args.index('-scheme') + 1], 'UploadValidation')
        self.assertEqual(args[args.index('-destination') + 1], 'platform=iOS Simulator,id=A')
        self.assertEqual(args[args.index('-parallel-testing-enabled') + 1], 'NO')
        self.assertIn('-only-testing:UploadValidationTests', args)
        self.assertIn('FLUTTER_ROOT=/Flutter SDK', args)
        self.assertIn('CODE_SIGN_IDENTITY=-', args)
        self.assertIn('CODE_SIGNING_ALLOWED=YES', args)
        self.assertNotIn('-workspace', args)

    def test_pass_evidence_does_not_count_started_or_skipped_tests(self):
        log = """Test Case '-[UploadValidationTests.SomeTests testStarted]' started.
Test Case '-[UploadValidationTests.SomeTests testPassed]' passed (0.01 seconds).
Test case 'SomeTests.testOtherPassed()' passed on 'Simulator' (0.01 seconds).
Test Case '-[UploadValidationTests.SomeTests testSkipped]' skipped (0.01 seconds).
"""
        self.assertEqual(passed_methods(log), {'testPassed', 'testOtherPassed'})


if __name__ == '__main__':
    unittest.main()
