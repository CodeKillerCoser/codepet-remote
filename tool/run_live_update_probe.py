#!/usr/bin/env python3
"""Exercise native live-update tap and swipe on an isolated, authorized emulator."""
import argparse
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--swipe', action='store_true', help='Test system swipe dismissal instead of the explicit unpin action')
args = parser.parse_args()
if not args.device.startswith('emulator-'):
    parser.error('Use an isolated emulator')
root = Path(__file__).resolve().parents[1]
log_path = root / 'artifacts/live-update-probe.log'
log_path.parent.mkdir(exist_ok=True)
adb = ['adb', '-s', args.device]
def command(*values):
    return subprocess.check_output(adb + list(values), text=True, timeout=20)
def notification_bounds(label='需要授权'):
    command('shell', 'cmd', 'statusbar', 'expand-notifications')
    command('shell', 'uiautomator', 'dump', '/sdcard/live-probe.xml')
    xml = command('shell', 'cat', '/sdcard/live-probe.xml')
    for node in ET.fromstring(xml).iter('node'):
        if node.get('text') == label:
            return list(map(int, re.findall(r'\d+', node.get('bounds'))))
    return None
command('shell', 'cmd', 'statusbar', 'collapse')
with log_path.open('w') as log:
    process = subprocess.Popen(['flutter', 'test', '--no-pub', '-d', args.device,
        'integration_test/live_updates_test.dart', '--dart-define=LIVE_TAP_PROBE=true',
        '--dart-define=LIVE_DISMISS_PROBE=true'], cwd=root, stdout=log, stderr=subprocess.STDOUT)
    permission = tapped = swiped = False
    deadline = time.monotonic() + 300
    try:
        while process.poll() is None and time.monotonic() < deadline:
            text = log_path.read_text()
            if not permission and 'LIVE_READY_FOR_PERMISSION' in text:
                command('shell', 'uiautomator', 'dump', '/sdcard/live-probe.xml')
                xml = command('shell', 'cat', '/sdcard/live-probe.xml')
                for node in ET.fromstring(xml).iter('node'):
                    if 'permission_allow_button' in node.get('resource-id', ''):
                        a,b,c,d = map(int, re.findall(r'\d+', node.get('bounds')))
                        command('shell', 'input', 'tap', str((a+c)//2), str((b+d)//2))
                        permission = True
            if not tapped and 'LIVE_READY_FOR_TAP' in text:
                bounds = notification_bounds()
                if bounds:
                    a,b,c,d = bounds
                    command('shell', 'input', 'tap', str((a+c)//2), str((b+d)//2))
                    tapped = True
            if not swiped and 'LIVE_READY_FOR_DISMISS' in text:
                bounds = notification_bounds('需要授权' if args.swipe else '取消关注')
                if bounds:
                    a,b,c,d = bounds
                    if args.swipe:
                        command('shell', 'input', 'swipe', str((a+c)//2), str((b+d)//2), '1050', str((b+d)//2), '300')
                    else:
                        command('shell', 'input', 'tap', str((a+c)//2), str((b+d)//2))
                    swiped = True
            time.sleep(0.5)
        if process.poll() is None:
            raise TimeoutError('Live update probe timed out')
        print(log_path.read_text())
        if not tapped or not swiped:
            raise RuntimeError('Native interactions were not completed')
        raise SystemExit(process.returncode)
    finally:
        if process.poll() is None:
            process.terminate()
        command('shell', 'rm', '-f', '/sdcard/live-probe.xml')
