import os, pathlib, subprocess, tempfile, time
script = pathlib.Path(__file__).resolve().parent.parent / 'build/Awake.app/Contents/Resources/lidawake-netguard'
with tempfile.TemporaryDirectory(prefix='awake-netguard-check-') as temp:
    root = pathlib.Path(temp)
    (root/'lid').write_text('expiry=2000\n')
    (root/'enabled').write_text('1\n')
    (root/'config').write_text('HOTSPOT_SSID="Test iPhone"\nHOTSPOT_PASSWORD=""\n')
    env = dict(os.environ, NETGUARD_ENABLED_FILE=str(root/'enabled'), LIDAWAKE_STATE=str(root/'lid'),
        NETGUARD_STATE=str(root/'state'), NETGUARD_LOG=str(root/'log'), NETGUARD_CONF=str(root/'config'), AWAKE_HOTSPOT_CONFIG=str(root/'absent'),
        NETGUARD_DRYRUN='1', NETGUARD_FORCE_FAIL='1', NETGUARD_TEST_WIFI_ON='1')
    def tick(now, **extra):
        subprocess.run(['/bin/bash', str(script), 'run'], env=dict(env,NETGUARD_NOW=str(now),**extra), check=True, capture_output=True)
    for now in [1000,1045,1100,1180,1255,1310]: tick(now)
    log=(root/'log').read_text()
    # 4 recovery attempts; dry-run join never connects, so each falls through to a Wi-Fi restart
    assert log.count('(dry-run) setairportpower off/on')==4
    assert log.count('(dry-run) setairportnetwork')==4
    assert log.index('(dry-run) setairportnetwork') < log.index('(dry-run) setairportpower off/on'), 'Hotspot comes first'
    before=(root/'state').read_bytes()
    (root/'enabled').write_text('0\n'); tick(1500)
    assert (root/'state').read_bytes()==before
    assert (root/'log').read_text()==log
    (root/'enabled').write_text('1\n'); tick(1500)
    assert (root/'log').read_text()!=log
    # lidawake off: idle unless the always switch is on
    (root/'lid').write_text('expiry=1\n'); (root/'state').unlink(missing_ok=True); (root/'log').write_text('')
    env['NETGUARD_ALWAYS_FILE']=str(root/'always')
    for now in [3000,3045]: tick(now)
    assert (root/'log').read_text()=='' and not (root/'state').exists()
    (root/'always').write_text('1\n')
    for now in [3100,3145]: tick(now)
    assert '상시 감시' in (root/'log').read_text() and '(dry-run) setairportnetwork' in (root/'log').read_text()
    (root/'always').write_text('0\n'); tick(3160)
    assert not (root/'state').exists()
    # Sign-in page answering instead of the internet: never restart Wi-Fi, notify once.
    (root/'lid').write_text('expiry=99999\n'); (root/'log').write_text('')
    portal = dict(NETGUARD_FORCE_CAPTIVE='1', NETGUARD_TEST_SSID='Cafe "Free"', NETGUARD_TEST_LID='open')
    for now in [5000,5045,5100,5180,5255]: tick(now, **portal)
    log=(root/'log').read_text()
    assert log.count('동의·로그인 화면')==1 and 'Cafe "Free"' in log
    assert 'setairportpower' not in log and 'setairportnetwork' not in log, 'Lid open: leave the sign-in page alone'
    portal['NETGUARD_TEST_LID']='closed'
    for now in [5270,5325]: tick(now, **portal)
    log=(root/'log').read_text()
    assert log.count('(dry-run) setairportnetwork')==2 and 'setairportpower' not in log, 'Lid closed: hotspot only'
    (root/'state').unlink(missing_ok=True)
    (root/'lid').write_text('expiry=2000\n')
    # Test the actual deadline wrapper against a hung command, without networking.
    source = script.read_text()
    wrapper = next(line for line in source.splitlines() if line.startswith('bounded()'))
    start = time.monotonic()
    result = subprocess.run(['/bin/bash', '-c', wrapper + '\nbounded 1 /bin/sleep 20'],
                            capture_output=True, timeout=4)
    assert result.returncode == 142 and time.monotonic() - start < 3

    # Execute a real join branch against fake programs, never the system Wi-Fi.
    (root/'bin').mkdir()
    fake_network = root/'bin/networksetup'
    fake_network.write_text('#!/bin/bash\ncase "$1" in\n-listallhardwareports) echo "Hardware Port: Wi-Fi"; echo "Device: en0";;\n-getairportpower) echo "Wi-Fi Power (en0): On";;\n-setairportnetwork) echo called >>"$CALLS";;\n-setairportpower) echo "$3" >>"$POWER";;\nesac\n')
    fake_network.chmod(0o700)
    fake_ipconfig = root/'bin/ipconfig'
    fake_ipconfig.write_text('#!/bin/bash\necho "$FAKE_ROUTER"\n'); fake_ipconfig.chmod(0o700)
    fake_tool = root/'Library/Application Support/Awake/awake-credentials'
    fake_tool.parent.mkdir(parents=True)
    fake_tool.write_text('#!/bin/bash\nexit 1\n'); fake_tool.chmod(0o700)
    config = root/'hotspot.json'
    config.write_text('{"ssid":"Test iPhone","usesKeychain":true}')
    (root/'state').write_text('since=1000\nstage=1\nlast_act=1045\nlast_tick=1090\n')
    env.update(HOME=str(root), PATH=str(root/'bin')+':'+os.environ['PATH'],
               AWAKE_HOTSPOT_CONFIG=str(config), NETGUARD_DRYRUN='0', CALLS=str(root/'calls'),
               POWER=str(root/'power'), FAKE_ROUTER='192.168.0.1')
    tick(1100)
    assert not (root/'calls').exists(), 'Credential denial must not attempt a passwordless join'
    assert '키체인 암호를 읽지 못함' in (root/'log').read_text()
    assert (root/'power').read_text().split()==['off','on'], 'Credential failure falls through to a Wi-Fi restart'
    assert 'stage=2' in (root/'state').read_text(), 'Credential failure must leave recovery able to retry'

    # A join that reports no error is the recovery; no Wi-Fi restart on top of it.
    config.write_text('{"ssid":"Test iPhone","usesKeychain":false}')
    (root/'power').unlink()
    (root/'state').write_text('since=1000\nstage=1\nlast_act=1045\nlast_tick=1090\n')
    tick(1100)
    assert (root/'calls').read_text()=='called\n' and not (root/'power').exists()

    # Already on the hotspot (gateway 172.20.10.1): skip the join, restart Wi-Fi instead.
    (root/'calls').unlink()
    (root/'state').write_text('since=1000\nstage=1\nlast_act=1045\nlast_tick=1090\n')
    env['FAKE_ROUTER']='172.20.10.1'; tick(1100)
    assert not (root/'calls').exists() and (root/'power').read_text().split()==['off','on']
    print('PASS: hotspot-first recovery stages, sign-in page left alone (hotspot only with lid closed), enable/always switches, hung command deadline, credential-denied fallback, join success, on-hotspot skip; no system network changes')
