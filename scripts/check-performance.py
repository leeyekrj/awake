#!/usr/bin/env python3
"""Exercise the real panel/controller with isolated preferences and no power commands.

--source-dir can point at a pre-fix Sources snapshot to demonstrate the regression.
The fixture never becomes key, accepts input, or invokes production startup tasks.
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--source-dir', type=pathlib.Path, default=root / 'Sources')
parser.add_argument('--iterations', type=int, default=10_000)
args = parser.parse_args()
if not 1 <= args.iterations <= 200_000:
    parser.error('iterations must be between 1 and 200000')

with tempfile.TemporaryDirectory(prefix='awake-performance-') as temp:
    directory = pathlib.Path(temp)
    for name in ['PowerController.swift', 'PanelView.swift', 'SetupController.swift', 'SetupView.swift']:
        source = (args.source_dir / name).read_text()
        if name == 'PowerController.swift':
            source = source.replace('io.paul.awake.preview', r'io.paul.awake.performance.\(getpid())')
        if name == 'PanelView.swift':
            source = source.replace('    var body: some View {',
                                    '    var body: some View {\n        let _ = PerformanceCounts.rootBodies += 1', 1)
        (directory / name).write_text(source)

    # Reuse AppDelegate, leaving out the CLI/main and preview entry points.
    source = (args.source_dir / 'main.swift').read_text().split('@MainActor func renderPreviews')[0]
    source = source.replace('let power = PowerController()', 'let power = PowerController(monitor: false)')
    begin = source.index('        Task {\n            await power.refresh(checkWatchdog: true)')
    end = source.index('\n    func ', begin)
    source = source[:begin] + '    }\n' + source[end:]
    source = source.replace('        Task { await power.refresh(checkWatchdog: true) }', '')
    source = source.replace('panel.makeKeyAndOrderFront(nil)',
                            'panel.orderFrontRegardless(); panel.ignoresMouseEvents = true')
    source = source.replace('panel.ignoresMouseEvents = false', 'panel.ignoresMouseEvents = true')
    # Keep test windows noninteractive and visually unobtrusive.
    source = source.replace('panel.alphaValue = visibilityProgress', 'panel.alphaValue = 0.02')
    source = source.replace('self.panel.alphaValue = value', 'self.panel.alphaValue = 0.02')
    fixture = (root / 'tests/Performance.swift').read_text()
    if 'let displayClock = DisplayClock()' not in (args.source_dir / 'PowerController.swift').read_text():
        fixture = fixture.split('// Fixed-version lifecycle checks')[0] + '''
            exit(1)
        }
    }
    withExtendedLifetime(delegate) { app.run() }
}
MainActor.assumeIsolated { runPerformanceRegression() }
'''
    (directory / 'main.swift').write_text(source + fixture)
    binary = directory / 'AwakePerformance'
    command = ['swiftc', '-swift-version', '5', '-Onone', '-target', 'arm64-apple-macosx14.0']
    command += [str(directory / name) for name in ['PowerController.swift', 'PanelView.swift', 'SetupController.swift', 'SetupView.swift', 'main.swift']]
    command += ['-o', str(binary)]
    for framework in ['AppKit', 'SwiftUI', 'IOKit', 'ServiceManagement', 'Security', 'LocalAuthentication']:
        command += ['-framework', framework]
    subprocess.run(command, check=True)
    result = subprocess.run([str(binary), str(args.iterations)], capture_output=True, text=True,
                            timeout=max(120, args.iterations * 0.05))
    print(result.stdout, end='', flush=True)
    if result.stderr:
        print(result.stderr, end='', file=sys.stderr)
    if result.returncode:
        raise SystemExit(result.returncode)
    if 'PASS: performance regression complete' not in result.stdout:
        raise SystemExit('FAIL: fixture exited before completing its checks')
