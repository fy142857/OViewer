"""Validate native-upload XCTest wiring without claiming an Xcode build passed."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

GUID = re.compile(r'^[A-Fa-f0-9]{24}$')
GENERATED = {'GeneratedPluginRegistrant.h', 'GeneratedPluginRegistrant.m', 'Generated.xcconfig'}
HOST = 'UploadValidationHost'
TESTS = 'UploadValidationTests'


class OpenStep:
    """Strict parser for the dictionaries, arrays and strings used by pbxproj."""
    def __init__(self, text: str):
        pattern = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|(?:(?!/\*|//)[^\s{}()=;,"])+', re.S)
        self.tokens = []
        cursor = 0
        for match in pattern.finditer(text):
            if match.start() != cursor:
                raise ValueError(f'Invalid project syntax at offset {cursor}')
            token = match.group()
            if not (token.isspace() or token.startswith('/*') or token.startswith('//')):
                self.tokens.append(token)
            cursor = match.end()
        if cursor != len(text):
            raise ValueError('Unparsed project suffix')
        self.index = 0

    def take(self, expected: str | None = None) -> str:
        if self.index >= len(self.tokens):
            raise ValueError('Truncated project')
        token = self.tokens[self.index]
        self.index += 1
        if expected is not None and token != expected:
            raise ValueError(f'Expected {expected}, found {token}')
        return token

    def value(self):
        token = self.take()
        if token == '{':
            result = {}
            while self.tokens[self.index] != '}':
                key = self.value()
                if not isinstance(key, str) or key in result:
                    raise ValueError(f'Duplicate or invalid project key: {key}')
                self.take('=')
                result[key] = self.value()
                self.take(';')
            self.take('}')
            return result
        if token == '(':
            result = []
            while self.tokens[self.index] != ')':
                result.append(self.value())
                if self.tokens[self.index] == ',':
                    self.take(',')
                elif self.tokens[self.index] != ')':
                    raise ValueError('Missing array separator')
            self.take(')')
            return result
        if token.startswith('"'):
            return re.sub(r'\\(.)', lambda m: {'n': '\n', 'r': '\r', 't': '\t'}.get(m[1], m[1]), token[1:-1])
        if token in '{}()=;,':
            raise ValueError('Unexpected project punctuation')
        return token

    def parse(self) -> dict:
        result = self.value()
        if self.index != len(self.tokens) or not isinstance(result, dict):
            raise ValueError('Invalid project root')
        return result


def read_project(path: Path) -> dict:
    return OpenStep(path.read_text(encoding='utf-8')).parse()


def read_xcconfig(path: Path, visited: set[Path] | None = None) -> dict[str, str]:
    visited = set() if visited is None else visited
    path = path.resolve()
    if path in visited:
        raise ValueError('Cyclic xcconfig include')
    visited.add(path)
    result = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        stripped = line.strip()
        include = re.fullmatch(r'#include(\?)?\s+"([^"]+)"', stripped)
        if include:
            target = path.parent / include[2]
            if target.name == 'Generated.xcconfig':
                continue  # Generated SDK paths do not override the test target's policy.
            if target.is_file():
                result.update(read_xcconfig(target, visited.copy()))
            elif not include[1]:
                raise ValueError(f'Missing xcconfig: {target}')
        elif stripped and not stripped.startswith('//') and '=' in stripped:
            key, value = stripped.split('=', 1)
            result[key.strip()] = value.strip()
    return result


def validate(root: Path, project: dict | None = None) -> dict:
    root = root.resolve()
    ios = root / 'ios'
    project = project if project is not None else read_project(ios / 'Runner.xcodeproj/project.pbxproj')
    objects = project['objects']
    if any(not GUID.fullmatch(key) for key in objects):
        raise ValueError('Invalid project object ID')

    def check_refs(value):
        if isinstance(value, dict):
            for key, item in value.items():
                check_refs(key); check_refs(item)
        elif isinstance(value, list):
            for item in value:
                check_refs(item)
        elif isinstance(value, str) and GUID.fullmatch(value) and value not in objects:
            raise ValueError(f'Dangling project object: {value}')

    check_refs(project)
    for item in objects.values():
        if item['isa'] == 'PBXBuildFile' and objects[item['fileRef']]['isa'] not in {'PBXFileReference', 'PBXVariantGroup'}:
            raise ValueError('A build phase file does not reference a file or localized resource')
    files: dict[str, Path] = {}
    generated = []
    group_stack = set()

    def visit(key: str, parent: Path):
        item = objects[key]
        source = item.get('sourceTree', '<group>')
        base = ios if source == 'SOURCE_ROOT' else parent
        path = (base / item.get('path', '')).resolve()
        if item['isa'] in {'PBXGroup', 'PBXVariantGroup'}:
            if key in group_stack:
                raise ValueError('Cyclic project group')
            group_stack.add(key)
            for child in item.get('children', []):
                visit(child, path)
            group_stack.remove(key)
        elif item['isa'] == 'PBXFileReference':
            if source in {'BUILT_PRODUCTS_DIR', 'SDKROOT', 'DEVELOPER_DIR'}:
                generated.append(item.get('path', key))
                return
            if source not in {'<group>', 'SOURCE_ROOT', '<absolute>'}:
                raise ValueError(f'Unsupported file reference source tree: {source}')
            files[key] = path
            if not path.exists():
                if path.name in GENERATED or 'Pods' in path.parts:
                    generated.append(str(path.relative_to(root)))
                else:
                    raise ValueError(f'Missing project file: {path}')

    project_object = objects[project['rootObject']]
    visit(project_object['mainGroup'], ios)
    # The framework file reference intentionally lives outside a source group.
    for key, item in objects.items():
        if item['isa'] == 'PBXFileReference' and key not in files and item.get('sourceTree') not in {'BUILT_PRODUCTS_DIR', 'SDKROOT', 'DEVELOPER_DIR'}:
            raise ValueError(f'Unreachable source file reference: {key}')

    targets = {item['name']: (key, item) for key, item in objects.items() if item['isa'] == 'PBXNativeTarget'}
    host_id, host = targets[HOST]
    tests_id, tests = targets[TESTS]
    flutter_refs = {key for key, item in objects.items() if item['isa'] == 'PBXFileReference'
                    and item.get('path') == 'UploadValidationFlutter/Flutter.framework'
                    and item.get('sourceTree') == 'BUILT_PRODUCTS_DIR'}
    if len(flutter_refs) != 1:
        raise ValueError('Validation must link its own prepared Flutter framework')
    for target in [host, tests]:
        frameworks = [objects[key] for key in target['buildPhases'] if objects[key]['isa'] == 'PBXFrameworksBuildPhase']
        if len(frameworks) != 1 or {objects[key]['fileRef'] for key in frameworks[0]['files']} != flutter_refs:
            raise ValueError('Validation framework linkage is incomplete')
    embeddings = [objects[key] for key in host['buildPhases'] if objects[key]['isa'] == 'PBXCopyFilesBuildPhase']
    if len(embeddings) != 1 or embeddings[0]['dstSubfolderSpec'] != '10' or {objects[key]['fileRef'] for key in embeddings[0]['files']} != flutter_refs:
        raise ValueError('Validation host must embed its Flutter framework')

    def phase_files(target: dict, kind: str) -> set[Path]:
        result = set()
        for key in target['buildPhases']:
            phase = objects[key]
            if phase['isa'] == kind:
                for build_id in phase['files']:
                    reference = objects[build_id]['fileRef']
                    if reference not in files:
                        raise ValueError('A source/resource phase points at a generated product')
                    result.add(files[reference])
        return result

    expected_sources = {path.resolve() for path in (ios / 'Runner').glob('Upload*.swift')}
    expected_sources.add((ios / 'UploadValidationHost/UploadValidationAppDelegate.swift').resolve())
    if phase_files(host, 'PBXSourcesBuildPhase') != expected_sources:
        raise ValueError('Validation host must compile exactly the shared upload sources and its isolated app delegate')
    expected_tests = {path.resolve() for path in (ios / 'RunnerTests').glob('*Tests.swift')}
    if phase_files(tests, 'PBXSourcesBuildPhase') != expected_tests or len(expected_tests) != 3:
        raise ValueError('The XCTest target does not include all three upload test sources')
    for path in expected_tests:
        if '@testable import UploadValidationHost' not in path.read_text(encoding='utf-8'):
            raise ValueError('Upload tests must import the isolated host module')
    fixture = (root / 'test/fixtures/uploads/uploaded.html').resolve()
    if phase_files(tests, 'PBXResourcesBuildPhase') != {fixture}:
        raise ValueError('The real sanitized fixture is missing from XCTest resources')
    fixture_text = fixture.read_text(encoding='utf-8')
    if re.findall(r'var\s+apiuid\s*=\s*(\d+)', fixture_text) != ['101'] or re.findall(r'var\s+apikey\s*=\s*"([^"]+)"', fixture_text) != ['fixture-api-key']:
        raise ValueError('The XCTest fixture is not the sanitized account fixture')
    if host['dependencies'] or [objects[key]['target'] for key in tests['dependencies']] != [host_id]:
        raise ValueError('Upload validation must not depend on the production Runner target')

    for name, target in [(HOST, host), (TESTS, tests)]:
        configs = objects[target['buildConfigurationList']]['buildConfigurations']
        if {objects[key]['name'] for key in configs} != {'Debug', 'Release', 'Profile'}:
            raise ValueError('Missing validation target configuration')
        for key in configs:
            configuration = objects[key]
            settings = read_xcconfig(files[configuration['baseConfigurationReference']])
            settings.update(configuration['buildSettings'])
            if settings.get('IPHONEOS_DEPLOYMENT_TARGET') != '12.0':
                raise ValueError('Upload validation must retain the iOS 12.0 target')
            if settings.get('SUPPORTED_PLATFORMS') != 'iphonesimulator' or settings.get('SDKROOT') != 'iphonesimulator':
                raise ValueError('Upload validation must be simulator-only')
            expected_bundle = 'com.oviewer.oviewer.uploadvalidation' + ('.tests' if name == TESTS else '')
            if settings.get('PRODUCT_BUNDLE_IDENTIFIER') != expected_bundle:
                raise ValueError('Validation bundle identity is not isolated')
            if settings.get('CODE_SIGNING_ALLOWED') != 'YES' or settings.get('CODE_SIGN_IDENTITY') != '-' or settings.get('CODE_SIGN_STYLE') != 'Manual' or settings.get('DEVELOPMENT_TEAM') or settings.get('ENABLE_TESTABILITY') != 'YES':
                raise ValueError('Invalid validation signing/testability settings')
            if name == TESTS and (settings.get('TEST_HOST') != '$(BUILT_PRODUCTS_DIR)/UploadValidationHost.app/UploadValidationHost' or settings.get('BUNDLE_LOADER') != '$(TEST_HOST)'):
                raise ValueError('XCTest host points outside the validation application')
    info = plistlib.loads((ios / 'UploadValidationHost/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != '$(PRODUCT_BUNDLE_IDENTIFIER)' or info.get('UIMainStoryboardFile'):
        raise ValueError('Validation host plist must not launch Runner storyboard')
    entitlements = plistlib.loads((ios / 'UploadValidationHost/UploadValidationHost.entitlements').read_bytes())
    if entitlements.get('application-identifier') != 'com.oviewer.oviewer.uploadvalidation' or entitlements.get('keychain-access-groups') != ['com.oviewer.oviewer.uploadvalidation']:
        raise ValueError('Validation Keychain access must remain in its own namespace')

    # The independent validation scheme does not consume or alter Runner's
    # historical TestAction. Validate only the new scheme's target references.
    for path in [ios / 'Runner.xcodeproj/xcshareddata/xcschemes/UploadValidation.xcscheme']:
        scheme = ET.parse(path)
        for reference in scheme.iter('BuildableReference'):
            item = objects.get(reference.attrib['BlueprintIdentifier'], {})
            if item.get('isa') != 'PBXNativeTarget' or item['name'] != reference.attrib['BlueprintName']:
                raise ValueError(f'Dangling scheme target in {path.name}')
            product = objects[item['productReference']]['path']
            if product != reference.attrib['BuildableName']:
                raise ValueError(f'Incorrect scheme product in {path.name}')
        if path.name == 'UploadValidation.xcscheme':
            ids = {reference.attrib['BlueprintIdentifier'] for reference in scheme.iter('BuildableReference')}
            if ids != {host_id, tests_id}:
                raise ValueError('UploadValidation scheme includes a non-isolated target')
            testables = scheme.findall('.//TestableReference')
            if len(testables) != 1 or testables[0].attrib.get('parallelizable') != 'NO':
                raise ValueError('Upload native tests must run serially in their isolated host')
    if not (ios / 'Runner.xcodeproj/xcshareddata/xcschemes/UploadValidation.xcscheme').is_file():
        raise ValueError('The shared UploadValidation scheme is missing')
    scripts = [objects[key] for key in host['buildPhases'] if objects[key]['isa'] == 'PBXShellScriptBuildPhase']
    if len(scripts) != 1 or scripts[0]['shellScript'] != 'python3 "$SRCROOT/../scripts/prepare_upload_ios_framework.py"':
        raise ValueError('Validation framework preparation is not wired correctly')
    if scripts[0]['outputPaths'] != ['$(BUILT_PRODUCTS_DIR)/UploadValidationFlutter/Flutter.framework']:
        raise ValueError('Xcode must know that the build phase produces the linked framework directory')
    if not (root / 'scripts/prepare_upload_ios_framework.py').is_file():
        raise ValueError('Missing framework preparation script')
    return {'structure_passed': True, 'xcode_build_executed': False, 'objects': len(objects),
            'checked_source_references': len(files), 'host_sources': len(expected_sources),
            'test_sources': len(expected_tests), 'scheme': 'UploadValidation', 'minimum_ios': '12.0',
            'generated_references': sorted(set(generated))}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    print(json.dumps(validate(args.root), ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
