#!/usr/bin/env python3
"""Connect provider telemetry to Dash Island without changing logins or CLI commands."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import time

if sys.version_info < (3, 11):  # tomllib; stock macOS /usr/bin/python3 is 3.9.
    raise SystemExit('connect-usage.py needs Python 3.11 or newer; this is Python %d.%d. '
                     'Run it with a newer python3 (Homebrew or uv).' % tuple(sys.version_info[:2]))
import tomllib

BEGIN = '# BEGIN Dash Island account usage'
END = '# END Dash Island account usage'
PORT = 43190
LABEL = 'dev.dashisland.usage-collector'


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


def claude_env(token):
    return {
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


def claude_config(text, token):
    obj = json.loads(text or '{}')
    env = obj.setdefault('env', {})
    desired = claude_env(token)
    endpoint = env.get('OTEL_EXPORTER_OTLP_LOGS_ENDPOINT') or env.get('OTEL_EXPORTER_OTLP_ENDPOINT')
    if endpoint and endpoint != desired['OTEL_EXPORTER_OTLP_LOGS_ENDPOINT']:
        raise ValueError('an existing Claude telemetry destination is configured')
    env.update(desired)
    return json.dumps(obj, ensure_ascii=False, indent=2) + '\n'


def codex_disconnect(text, token, original, created):
    if BEGIN not in text:
        return text
    before, rest = text.split(BEGIN, 1)
    if END not in rest:
        raise ValueError('incomplete Dash Island config block')
    kept = [part for part in (before.rstrip(), rest.split(END, 1)[1].strip()) if part]
    if not kept and created:
        return None
    result = '\n\n'.join(kept) + '\n' if kept else ''
    tomllib.loads(result)
    return result


def claude_disconnect(text, token, original, created):
    """Undo only values that are still ours; restore values the file had before connecting."""
    obj = json.loads(text or '{}')
    env = obj.get('env') if isinstance(obj, dict) else None
    if not isinstance(env, dict):
        return text
    before = json.loads(original or '{}')
    before = before if isinstance(before, dict) else {}
    prior = before.get('env') if isinstance(before.get('env'), dict) else {}
    changed = False
    for key, value in claude_env(token).items():
        if env.get(key) != value:
            continue  # Absent, or changed since connecting: the user's value now.
        if key in prior:
            env[key] = prior[key]
        else:
            del env[key]
        changed = True
    if not changed:
        return text
    if not env and 'env' not in before:
        del obj['env']
    if not obj and created:
        return None
    return json.dumps(obj, ensure_ascii=False, indent=2) + '\n'


def configurations(home, environ):
    support = home / 'Library/Application Support'
    codex = {home / '.codex'}
    claude = {home / '.claude'}
    for key, roots in [('CODEX_HOME', codex), ('CLAUDE_CONFIG_DIR', claude)]:
        for value in environ.get(key, '').split(','):
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


def real(path):
    # Dotfile managers (stow, chezmoi) link these files; replacing the link would detach it.
    return path.resolve() if path.is_symlink() else path


def atomic_write(path, data):
    path = real(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.dash-island-tmp')
    with temp.open('wb') as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def collector_version(text):
    match = re.search(r'^VERSION = (\d+)$', text, re.MULTILINE)
    return int(match.group(1)) if match else 0


def apply(edits, directory):
    """Back up, then write every (path, original, updated); updated None deletes. All or nothing."""
    if not edits:
        return None
    backup = directory / 'config-backups' / str(time.time_ns())
    manifest = []
    for index, (path, original, updated) in enumerate(edits):
        saved = backup / str(index)
        if original is not None:
            atomic_write(saved, original)
        manifest.append({'path': str(path), 'backup': str(saved) if original is not None else None})
    atomic_write(backup / 'manifest.json', json.dumps(manifest, indent=2).encode())
    changed = []
    try:
        for path, original, updated in edits:
            if (path.read_bytes() if path.exists() else None) != original:
                raise RuntimeError('%s changed during this run; earlier changes were rolled back. Run again.' % path)
            if updated is None:
                real(path).unlink()
            else:
                atomic_write(path, updated)
            changed.append((path, original))
    except Exception:
        for path, original in reversed(changed):
            if original is None:
                real(path).unlink(missing_ok=True)
            else:
                atomic_write(path, original)
        raise
    return backup


def start_collector(run, plist):
    domain = 'gui/' + str(os.getuid())
    run(['launchctl', 'bootout', domain + '/' + LABEL], capture_output=True)
    for attempt in range(3):
        if attempt:
            time.sleep(1)  # bootout can return before launchd releases the label.
        result = run(['launchctl', 'bootstrap', domain, str(plist)], capture_output=True)
        if result.returncode == 0:
            return
    detail = result.stderr.decode(errors='replace').strip() or 'exit %d' % result.returncode
    raise SystemExit('Could not start the collector (launchctl bootstrap: %s). No CLI configuration was changed.' % detail)


def install(home, environ, run):
    directory = home / 'Library/Application Support/DashIsland/tracking'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    token_path = directory / 'collector-token'
    token = token_path.read_text().strip() if token_path.exists() else secrets.token_hex(32)
    # Prepare and validate every config before any mutation.
    edits = []
    for path, transform in configurations(home, environ):
        original = path.read_bytes() if path.exists() else None
        updated = transform((original or b'').decode(), token).encode()
        if original != updated:
            edits.append((path, original, updated))
    atomic_write(token_path, token.encode())
    script = directory / 'usage-collector.py'
    collector = Path(__file__).with_name('usage-collector.py').read_bytes()
    installed = script.read_bytes() if script.exists() else b''
    ours, theirs = collector_version(collector.decode()), collector_version(installed.decode(errors='replace'))
    if theirs > ours:
        print('Kept the installed collector (version %d); this copy is version %d.' % (theirs, ours))
    else:
        atomic_write(script, collector)
    launcher = directory / 'account-cli'
    source = Path(__file__).with_name('account-cli.py').read_text().split('\n', 1)[1]
    atomic_write(launcher, ('#!' + sys.executable + '\n' + source).encode())
    os.chmod(launcher, 0o700)
    plist = home / 'Library/LaunchAgents' / (LABEL + '.plist')
    atomic_write(plist, plistlib.dumps({
        'Label': LABEL,
        'ProgramArguments': [sys.executable, str(script), '--directory', str(directory), '--port', str(PORT)],
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
        'StandardErrorPath': str(directory / 'collector-errors.log'),
    }))
    # Start the collector before any CLI points at it, so a failed start changes no config.
    start_collector(run, plist)
    backup = apply(edits, directory)
    print('Connected %d configurations. New Codex/Claude processes export account usage locally.' % len(edits))
    # The LaunchAgent pins this interpreter; if it is removed, launchd restarts a missing binary.
    print('Collector: 127.0.0.1:%d, run by %s (run this again if that Python is removed)' % (PORT, sys.executable))
    if backup:
        print('Config backups: %s' % backup)
    print('Undo with: python3 %s --disconnect' % Path(__file__).name)


def disconnect(home, environ, run):
    directory = home / 'Library/Application Support/DashIsland/tracking'
    token_path = directory / 'collector-token'
    token = token_path.read_text().strip() if token_path.exists() else ''
    # The earliest manifest that lists a file holds its state before Dash Island changed it.
    first = {}
    manifests = directory.glob('config-backups/*/manifest.json')
    for manifest in sorted(manifests, key=lambda m: int(m.parent.name) if m.parent.name.isdigit() else 0):
        for entry in json.loads(manifest.read_text()):
            first.setdefault(entry['path'], entry['backup'])
    edits = []
    for name in sorted({str(path) for path, _ in configurations(home, environ)} | set(first)):
        path = Path(name)
        if not path.exists():
            continue
        backup = first.get(name, '')  # None: the connector created the file; '': never recorded.
        original = Path(backup).read_text() if backup and Path(backup).exists() else None
        transform = codex_disconnect if path.name == 'config.toml' else claude_disconnect
        current = path.read_bytes()
        updated = transform(current.decode(), token, original, backup is None)
        if updated is None or updated.encode() != current:
            edits.append((path, current, None if updated is None else updated.encode()))
    apply(edits, directory)
    run(['launchctl', 'bootout', 'gui/' + str(os.getuid()) + '/' + LABEL], capture_output=True)
    (home / 'Library/LaunchAgents' / (LABEL + '.plist')).unlink(missing_ok=True)
    token_path.unlink(missing_ok=True)
    print('Disconnected %d configurations and stopped the collector.' % len(edits))
    print('Kept captured usage and config backups in %s' % directory)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--disconnect', action='store_true',
                        help='remove the Dash Island telemetry settings and stop the collector')
    arguments = parser.parse_args()
    os.umask(0o077)
    (disconnect if arguments.disconnect else install)(Path.home(), os.environ, subprocess.run)
