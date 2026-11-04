#!/usr/bin/env python3
"""Run native notification integration checks on an isolated Android emulator."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True, help='An isolated emulator serial, e.g. emulator-5580')
parser.add_argument('--adb', default=shutil.which('adb'), help='Path to adb if it is not on PATH')
args = parser.parse_args()
if not args.device.startswith('emulator-') or not args.adb:
    parser.error('Use an isolated emulator and supply --adb if needed')
root = Path(__file__).resolve().parents[1]
adb = [args.adb, '-s', args.device]


def device(*command):
    return subprocess.check_output(adb + list(command), timeout=20, text=True)


def tap(match):
    device('shell', 'uiautomator', 'dump', '/sdcard/codepet-notification-probe.xml')
    xml = device('shell', 'cat', '/sdcard/codepet-notification-probe.xml')
    for node in ET.fromstring(xml).iter('node'):
        if match(node.attrib):
            x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.attrib['bounds']))
            device('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
            return True
    return False


old_setting = device('shell', 'settings', 'get', 'global', 'always_finish_activities').strip()
process = None
with tempfile.NamedTemporaryFile(prefix='codepet-notifications-', suffix='.log', delete=False) as log_file:
    log_path = Path(log_file.name)
    try:
        process = subprocess.Popen([
            'flutter', 'test', '--no-pub', '-d', args.device,
            '--dart-define=NOTIFICATION_TAP_PROBE=true',
            'integration_test/notifications_test.dart',
        ], cwd=root, stdout=log_file, stderr=subprocess.STDOUT)
        permission = tapped = background = reopened = False
        deadline = time.monotonic() + 600
        while process.poll() is None and time.monotonic() < deadline:
            log = log_path.read_text()
            if not permission and 'NOTIFICATION_READY_FOR_PERMISSION' in log:
                time.sleep(1)
                permission = tap(lambda a: 'permission_allow_button' in a.get('resource-id', ''))
            if not tapped and 'NOTIFICATION_READY_FOR_TAP' in log:
                device('shell', 'cmd', 'statusbar', 'expand-notifications')
                time.sleep(1)
                tapped = tap(lambda a: a.get('text') == '需要授权')
            if not background and 'NOTIFICATION_READY_FOR_BACKGROUND' in log:
                device('shell', 'settings', 'put', 'global', 'always_finish_activities', '1')
                device('shell', 'input', 'keyevent', 'KEYCODE_HOME')
                background = True
            if not reopened and 'NOTIFICATION_POSTED_IN_BACKGROUND' in log:
                device('shell', 'cmd', 'statusbar', 'expand-notifications')
                time.sleep(1)
                reopened = tap(lambda a: a.get('text') == '任务已完成')
            time.sleep(0.5)
        if process.poll() is None:
            raise TimeoutError('Notification probe timed out')
        print(log_path.read_text())
        raise SystemExit(process.returncode)
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
        if old_setting == 'null':
            device('shell', 'settings', 'delete', 'global', 'always_finish_activities')
        else:
            device('shell', 'settings', 'put', 'global', 'always_finish_activities', old_setting)
        device('shell', 'rm', '-f', '/sdcard/codepet-notification-probe.xml')
        print(f'Probe log: {log_path}')
