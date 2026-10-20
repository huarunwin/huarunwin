#!/usr/bin/env python3
"""Validate read-only Mac application discovery using temporary app fixtures."""
import json
import os
import pathlib
import plistlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='huarun-installed-apps-') as work:
    work = pathlib.Path(work)
    main = work / 'main.swift'
    main.write_text('''
import Foundation
let roots = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
let apps = try InstalledApplicationReader.scan(in: roots)
let data = try JSONSerialization.data(withJSONObject: apps)
print(String(data: data, encoding: .utf8)!)
''')
    binary = work / 'reader'
    subprocess.run([
        'xcrun', 'swiftc', str(ROOT / 'macos/Runner/InstalledApplications.swift'),
        str(main), '-o', str(binary),
    ], check=True, capture_output=True, text=True)
    system, user = work / 'system', work / 'user'
    system.mkdir()
    user.mkdir()

    def app(directory, filename, *, version='0.9.0', executable=True):
        bundle = directory / filename
        contents = bundle / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        info = {
            'CFBundleName': 'Example',
            'CFBundleDisplayName': '示例应用',
            'CFBundleIdentifier': 'win.huarun.fixture',
            'CFBundleExecutable': 'Example',
            'CFBundleVersion': '2026101701',
        }
        if version is not None:
            info['CFBundleShortVersionString'] = version
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        target = contents / 'MacOS/Example'
        target.write_text('#!/bin/sh\nexit 0\n')
        if executable:
            target.chmod(0o755)
        return bundle

    def scan():
        return json.loads(subprocess.run([
            str(binary), str(system), str(user), str(system), str(work / 'missing'),
        ], check=True, capture_output=True, text=True).stdout)

    renamed = app(system, 'Renamed.app')
    result = scan()
    assert len(result) == 1
    assert result[0]['version'] == '0.9.0'
    assert result[0]['bundleIdentifier'] == 'win.huarun.fixture'
    assert set(result[0]['names']) == {'Example', '示例应用', 'Renamed'}
    assert result[0]['path'] == str(renamed)
    print('PASS actual bundle version, identity, display name and renamed application')

    app(system, 'MissingVersion.app', version=None)
    app(system, 'NotExecutable.app', executable=False)
    app(system, '.Hidden.app')
    os.symlink(renamed, user / 'Alias.app')
    assert len(scan()) == 1
    print('PASS ignores missing version, non-executable, hidden and symbolic-link bundles')

    second = app(user, 'SecondCopy.app', version='0.8.0')
    result = scan()
    assert {entry['path'] for entry in result} == {str(renamed), str(second)}
    assert {entry['version'] for entry in result} == {'0.9.0', '0.8.0'}
    print('PASS preserves multiple installed copies for conservative identity matching')

    info_path = renamed / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleShortVersionString'] = '0.9.1'
    info_path.write_bytes(plistlib.dumps(info))
    assert next(entry for entry in scan() if entry['path'] == str(renamed))['version'] == '0.9.1'
    print('PASS refresh reads changed version without launching applications')
