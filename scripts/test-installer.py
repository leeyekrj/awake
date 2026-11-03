#!/usr/bin/env python3
"""Exercise the real installer against local copies of the release assets."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
archive = root/'dist/Awake-1.1.3-macOS-universal.zip'
assert archive.is_file(), 'Build the release first'
with tempfile.TemporaryDirectory(prefix='awake-install-test-') as temporary:
    base = Path(temporary)
    assets = base/'assets'; assets.mkdir()
    (assets/archive.name).write_bytes(archive.read_bytes())
    checksum = assets/'SHA256SUMS.txt'
    checksum.write_bytes((root/'dist/SHA256SUMS.txt').read_bytes())
    tools = base/'tools'; tools.mkdir()
    curl = tools/'curl'
    curl.write_text('''#!/bin/bash
set -eu
output=''; url=''
while [ "$#" -gt 0 ]; do
 case "$1" in -o) output="$2"; shift 2;; --retry|--proto|--tlsv1.2) if [ "$1" = --tlsv1.2 ]; then shift; else shift 2; fi;; https://*) url="$1"; shift;; *) shift;; esac
done
cp "$TEUM_TEST_ASSETS/${url##*/}" "$output"
''')
    curl.chmod(0o755)
    appdir = base/"Apps with spaces 'test'"
    env = dict(os.environ, PATH=str(tools)+':'+os.environ['PATH'], TEUM_TEST_ASSETS=str(assets))
    command = ['bash', str(root/'install.sh'), '--app-dir', str(appdir), '--no-open']
    def install(ok=True):
        p = subprocess.run(command, env=env, capture_output=True, text=True)
        assert (p.returncode == 0) == ok, p.stdout+p.stderr
        return p
    install()
    binary = appdir/'Awake.app/Contents/MacOS/Awake'
    before = hashlib.sha256(binary.read_bytes()).hexdigest()
    install()
    assert list(appdir.glob('Awake.app.backup-*')), 'Previous app was not backed up'
    checksum.write_text('0'*64+'  '+archive.name+'\n')
    p = install(False)
    assert '다운로드 검증 실패' in p.stderr
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == before
print('Installer: install, quoted paths, upgrade backup and checksum rejection passed')
