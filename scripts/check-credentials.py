#!/usr/bin/env python3
"""Test a bundled tool with disposable Keychain accounts; never replace the live tool."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unicodedata
import uuid

root = Path(__file__).resolve().parents[1]
account = 'Awake fixture 한글 ' + str(uuid.uuid4())
secret = b'Awake-fixture-only'
with tempfile.TemporaryDirectory(prefix='awake-credential-test-') as temporary:
    tool = Path(temporary)/'awake-credentials'
    shutil.copy2(root/'build/Awake.app/Contents/Resources/awake-credentials',tool)
    def run(binary, command, name, **kwargs):
        return subprocess.run([str(binary),command,name],capture_output=True,timeout=8,**kwargs)
    result = run(tool,'put',account,input=secret)
    assert result.returncode == 0, result.stderr
    try:
        for _ in range(20):
            result = run(tool,'get',account)
            assert result.returncode == 0 and result.stdout == secret
        assert run(tool,'get',unicodedata.normalize('NFD',account)).stdout == secret
        foreign = Path(temporary)/'foreign-tool'
        shutil.copy2(tool,foreign)
        subprocess.run(['codesign','--force','--sign','-','--identifier','io.paul.awake.foreign-fixture',str(foreign)],check=True,capture_output=True)
        started = time.monotonic()
        denied = run(foreign,'get',account)
        assert denied.returncode != 0 and not denied.stdout
        assert time.monotonic()-started < 5
    finally:
        assert run(tool,'delete',account).returncode == 0
print('PASS: 20 background reads, Unicode account matching, foreign identity denied without UI, fixture deleted; live credential tool untouched')
