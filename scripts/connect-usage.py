#!/usr/bin/env python3
"""Connect provider telemetry to Dash Island without changing logins or CLI commands."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import subprocess
import sys
import time
import tomllib

BEGIN = '# BEGIN Dash Island account usage'
END = '# END Dash Island account usage'
PORT = 43190


def codex_config(text, token):
    if BEGIN in text:
        before, rest = text.split(BEGIN, 1)
        if END not in rest:
            raise ValueError('incomplete Dash Island config block')
        text = before + rest.split(END, 1)[1]
    parsed = tomllib.loads(text)
    if 'otel' in parsed:
        raise ValueError('an existing Codex telemetry destination is configured')
    block = '\n'.join([
        BEGIN, '[otel]', 'log_user_prompt = false',
        'exporter = { otlp-http = { endpoint = "http://127.0.0.1:%d/v1/logs", protocol = "json", headers = { Authorization = "Bearer %s" } } }' % (PORT, token), END])
    result = text.rstrip() + '\n\n' + block + '\n'
    tomllib.loads(result)
    return result


def claude_config(text, token):
    obj = json.loads(text or '{}')
    env = obj.setdefault('env', {})
    desired = {
        'CLAUDE_CODE_ENABLE_TELEMETRY': '1',
        'OTEL_LOGS_EXPORTER': 'otlp',
        'OTEL_EXPORTER_OTLP_LOGS_PROTOCOL': 'http/json',
        'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT': 'http://127.0.0.1:%d/v1/logs' % PORT,
        'OTEL_EXPORTER_OTLP_LOGS_HEADERS': 'Authorization=Bearer ' + token,
        'OTEL_LOG_USER_PROMPTS': '0',
        'OTEL_LOG_TOOL_DETAILS': '0',
        'OTEL_LOG_TOOL_CONTENT': '0',
        'OTEL_LOG_RAW_API_BODIES': '0',
        'OTEL_METRICS_INCLUDE_ACCOUNT_UUID': 'true',
    }
    endpoint = env.get('OTEL_EXPORTER_OTLP_LOGS_ENDPOINT') or env.get('OTEL_EXPORTER_OTLP_ENDPOINT')
    if endpoint and endpoint != desired['OTEL_EXPORTER_OTLP_LOGS_ENDPOINT']:
        raise ValueError('an existing Claude telemetry destination is configured')
    env.update(desired)
    return json.dumps(obj, ensure_ascii=False, indent=2) + '\n'


def configurations(home):
    support = home / 'Library/Application Support'
    codex = {home / '.codex'}
    claude = {home / '.claude'}
    for key, roots in [('CODEX_HOME', codex), ('CLAUDE_CONFIG_DIR', claude)]:
        for value in os.environ.get(key, '').split(','):
            if value.strip():
                roots.add(Path(value.strip()))
    orca = support / 'orca'
    codex.update(orca.glob('codex-accounts/*/home'))
    if (orca / 'codex-runtime-home/home').exists():
        codex.add(orca / 'codex-runtime-home/home')
    claude.update(orca.glob('claude-accounts/*/auth'))
    accounts = support / 'DashIsland/accounts.json'
    if accounts.exists():
        for account in json.loads(accounts.read_text()):
            root = support / 'DashIsland/accounts' / account['credentialRef']
            if account['vendorID'] == 'codex':
                codex.add(root)
            if account['vendorID'] == 'claude':
                claude.add(root)
    return [(p / 'config.toml', codex_config) for p in sorted(codex)] + [
        (p / 'settings.json', claude_config) for p in sorted(claude)]


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.dash-island-tmp')
    with temp.open('wb') as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def install():
    home = Path.home()
    directory = home / 'Library/Application Support/DashIsland/tracking'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    token_path = directory / 'collector-token'
    token = token_path.read_text().strip() if token_path.exists() else secrets.token_hex(32)
    # Prepare and validate every config before any mutation.
    edits = []
    for path, transform in configurations(home):
        original = path.read_bytes() if path.exists() else None
        updated = transform((original or b'').decode(), token).encode()
        if original != updated:
            edits.append((path, original, updated))
    atomic_write(token_path, token.encode())
    script = directory / 'usage-collector.py'
    atomic_write(script, Path(__file__).with_name('usage-collector.py').read_bytes())
    launcher = directory / 'account-cli'
    source = Path(__file__).with_name('account-cli.py').read_text().split('\n', 1)[1]
    atomic_write(launcher, ('#!' + sys.executable + '\n' + source).encode())
    os.chmod(launcher, 0o700)
    backup = directory / 'config-backups' / str(time.time_ns())
    manifest = []
    for index, (path, original, updated) in enumerate(edits):
        saved = backup / str(index)
        if original is not None:
            atomic_write(saved, original)
        manifest.append({'path': str(path), 'backup': str(saved) if original is not None else None})
    if manifest:
        atomic_write(backup / 'manifest.json', json.dumps(manifest, indent=2).encode())
    changed = []
    try:
        for path, original, updated in edits:
            atomic_write(path, updated)
            changed.append((path, original))
    except Exception:
        for path, original in reversed(changed):
            if original is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, original)
        raise
    label = 'dev.dashisland.usage-collector'
    plist = home / 'Library/LaunchAgents' / (label + '.plist')
    atomic_write(plist, plistlib.dumps({
        'Label': label,
        'ProgramArguments': [sys.executable, str(script), '--directory', str(directory), '--port', str(PORT)],
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
        'StandardErrorPath': str(directory / 'collector-errors.log'),
    }))
    domain = 'gui/' + str(os.getuid())
    subprocess.run(['launchctl', 'bootout', domain + '/' + label], capture_output=True)
    subprocess.run(['launchctl', 'bootstrap', domain, str(plist)], check=True)
    print('Connected %d configurations. New Codex/Claude processes export account usage locally.' % len(edits))
    print('Collector: 127.0.0.1:%d; config backups: %s' % (PORT, backup))


if __name__ == '__main__':
    os.umask(0o077)
    install()
