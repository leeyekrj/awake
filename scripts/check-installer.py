"""Run the actual installer in an isolated filesystem; no root or power changes."""
import os, pathlib, plistlib, pwd, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
resources = root / 'build/Awake.app/Contents/Resources'
user = pwd.getpwuid(os.getuid()).pw_name

def install(target):
    return subprocess.run(['/bin/bash', str(resources/'awake-install.sh'), user, str(target)],
        env=dict(os.environ, AWAKE_INSTALL_TESTING='1'), capture_output=True, text=True)

with tempfile.TemporaryDirectory(prefix='awake-install-test-', dir='/private/tmp') as temp:
    target = pathlib.Path(temp)
    result = install(target)
    assert result.returncode == 0, result.stderr
    base = target/'Library/Application Support/Awake'
    for name, source in [('lidawake', 'awake-lidawake'), ('lidawake-watchdog', 'awake-watchdog')]:
        assert (base/name).read_bytes() == (resources/source).read_bytes()
        assert (base/name).stat().st_mode & 0o777 == 0o755
    plist = target/'Library/LaunchDaemons/io.paul.awake.lidawake.plist'
    daemon = plistlib.loads(plist.read_bytes())
    assert daemon['StartInterval'] == 60 and daemon['RunAtLoad'] is True
    assert daemon['ProgramArguments'] == ['/Library/Application Support/Awake/lidawake-watchdog']
    rule = target/f'private/etc/sudoers.d/awake-lidawake-{os.getuid()}'
    assert rule.stat().st_mode & 0o777 == 0o440
    assert rule.read_text() == f'{user} ALL=(root) NOPASSWD: /Library/Application\\ Support/Awake/lidawake\n'
    assert 'NOPASSWD: ALL' not in rule.read_text()
    assert install(target).returncode == 0  # Repeat installation is supported.
    base.chmod(0o777)
    assert install(target).returncode != 0  # Reject a writable privileged helper directory.

with tempfile.TemporaryDirectory(prefix='awake-install-test-', dir='/private/tmp') as temp:
    target = pathlib.Path(temp)
    (target/'Library/Application Support').mkdir(parents=True)
    (target/'Library/Application Support/Awake').symlink_to(target/'other')
    assert install(target).returncode != 0

for args in [[], ['off','extra'], ['0','30','-a'], ['481','30','-a'], ['60','0','-a'],
             ['60','30','-b'], ['60;touch /tmp/unsafe','30','-a'], ['999999999999999999999','30','-a']]:
    result = subprocess.run(['/bin/bash', str(resources/'awake-lidawake'), *args],capture_output=True)
    assert result.returncode == 2, (args, result.returncode)
print('PASS: isolated installation, sudoers scope and syntax, daemon and payload, repeat install, symlink/writable directory rejection, helper input validation')
