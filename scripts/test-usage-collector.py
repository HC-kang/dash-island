#!/usr/bin/env python3
import contextlib
import importlib.util
import io
from pathlib import Path
import sqlite3
import json
import http.client
import socket
import subprocess
import sys
import tempfile
import time


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


c = load('usage-collector')
i = load('connect-usage')
db = sqlite3.connect(':memory:')
db.executescript(c.SCHEMA)


def record(account, **extra):
    attrs = {'event.name': 'codex.sse_event', 'event.kind': 'response.completed',
             'user.account_id': account, 'conversation.id': 'session', 'model': 'test',
             'input_token_count': 100, 'output_token_count': 20, 'cached_token_count': 30,
             'cache_write_token_count': 10, 'reasoning_token_count': 15}
    attrs.update(extra)
    return {'timeUnixNano': '1789200000000000000', 'attributes': [
        {'key': k, 'value': {'stringValue' if isinstance(v, str) else 'intValue': v}}
        for k, v in attrs.items()]}


def ingest(*records):
    return c.ingest(db, {'resourceLogs': [{'scopeLogs': [{'logRecords': records}]}]})


assert ingest(record('a'), record('b')) == 2
assert ingest(record('a')) == 0
nullable = record('nullable'); nullable['body'] = None
assert ingest(nullable) == 1
zero_time = record('zero-time', **{'event.timestamp':'2026-09-12T09:00:00.123Z'}); zero_time['timeUnixNano'] = '0'; zero_time['body'] = None
assert ingest(zero_time, zero_time) == 1
assert db.execute('select count(distinct identity) from usage_events').fetchone()[0] == 4
assert db.execute('select input,output,cache_write,cache_read from usage_events limit 1').fetchone() == (60,20,10,30)
assert ingest(record('a', **{'event.kind': 'response.failed'}), record(''), record('c', input_token_count=-1)) == 0
claude = record('unused', **{'event.name': 'api_request', 'user.account_uuid': 'claude-a',
    'organization.id': 'org', 'input_tokens': 5, 'output_tokens': 6,
    'cache_read_tokens': 20, 'request_id': 'req-a', 'cost_usd': '0.12'})
assert ingest(claude, claude) == 1
assert db.execute("select input,output,cache_read,dollars from usage_events where provider='claude'").fetchone() == (5,6,20,0.12)
assert c.identity('claude','a','org1') != c.identity('claude','a','org2')
assert c.identity('codex','A') == c.identity('codex','a')
assert c.parse_record(record('a'), {'dash_island.purpose':'auth_refresh'}) is None
config = i.codex_config('model="keep"\n[projects."/tmp"]\ntrust_level="trusted"\n', 'token')
assert i.codex_config(config, 'token') == config
assert i.tomllib.loads(config)['model'] == 'keep'
try:
    i.codex_config('[otel]\nexporter="none"\n', 'token')
    raise AssertionError('must preserve existing telemetry')
except ValueError:
    pass
settings = json.loads(i.claude_config('{"hooks":{"Stop":[{"keep":true}]},"env":{"KEEP":"yes"}}','token'))
assert settings['hooks']['Stop'][0]['keep'] and settings['env']['KEEP'] == 'yes'
assert settings['env']['OTEL_LOG_RAW_API_BODIES'] == '0'
launcher = load('account-cli')
for vendor, variable in [('codex','CODEX_HOME'),('claude','CLAUDE_CONFIG_DIR'),('grok','GROK_HOME'),('agy','HOME')]:
    env = launcher.launch_environment({'vendorID':vendor},Path('/tmp/account-a'),{'HOME':'/real','KEEP':'yes','OPENAI_API_KEY':'wrong','ANTHROPIC_API_KEY':'wrong'})
    assert env[variable] == '/tmp/account-a' and env['KEEP'] == 'yes'
    assert 'OPENAI_API_KEY' not in env and 'ANTHROPIC_API_KEY' not in env
print('PASS: account isolation, duplicates, cache/reasoning, malformed events, Claude cost, safe/idempotent config merge')


def quiet(function, *args):
    with contextlib.redirect_stdout(io.StringIO()):
        return function(*args)


def launchctl(calls, fail=False, before=None):
    # Tests never run the real launchctl: it would stop the user's installed collector.
    def run(args, **_):
        assert args[0] == 'launchctl'
        calls.append(args[1])
        if before:
            before(args)
        failed = fail and args[1] == 'bootstrap'
        return subprocess.CompletedProcess(args, 5 if failed else 0, b'', b'boom' if failed else b'')
    return run


source_collector = Path(c.__file__).read_bytes()
assert i.collector_version('x = 1\nVERSION = 7\n') == 7 and i.collector_version('') == 0
assert i.collector_version(source_collector.decode()) == c.VERSION > 1
with tempfile.TemporaryDirectory() as temporary:
    home = Path(temporary)
    tracking = home / 'Library/Application Support/DashIsland/tracking'
    calls = []
    quiet(i.install, home, {}, launchctl(calls))
    installed = tracking / 'usage-collector.py'
    assert installed.read_bytes() == source_collector and calls == ['bootout', 'bootstrap']
    installed.write_text('VERSION = %d\n' % (c.VERSION + 1))
    quiet(i.install, home, {}, launchctl(calls))
    assert installed.read_text() == 'VERSION = %d\n' % (c.VERSION + 1), 'a newer installed collector is kept'
    installed.write_text('VERSION = 1\n')
    quiet(i.install, home, {}, launchctl(calls))
    assert installed.read_bytes() == source_collector, 'an older installed collector is replaced'
print('PASS: connector installs the repo collector unless the installed copy is newer')

# A client can connect and disappear before sending headers. The collector must
# still accept the next export rather than waiting indefinitely on that socket.
with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    (directory / 'collector-token').write_text('test-token')
    with socket.socket() as reserved:
        reserved.bind(('127.0.0.1', 0))
        port = reserved.getsockname()[1]
    process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('usage-collector.py')),
                                '--directory', temporary, '--port', str(port)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    idle = None
    client = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    try:
        deadline = time.monotonic() + 5
        while idle is None:
            assert process.poll() is None, 'collector exited during startup'
            try:
                idle = socket.create_connection(('127.0.0.1', port), timeout=0.2)
            except OSError:
                assert time.monotonic() < deadline, 'collector did not start'
                time.sleep(0.05)
        payload = json.dumps({'resourceLogs': [{'scopeLogs': [{'logRecords': [record('http')]}]}]})
        client.request('POST', '/v1/logs', body=payload,
                       headers={'Authorization': 'Bearer test-token', 'Content-Type': 'application/json'})
        response = client.getresponse()
        assert response.status == 200 and response.read() == b'{}'
        with sqlite3.connect(directory / 'account-usage.sqlite') as captured:
            assert captured.execute('SELECT COUNT(*) FROM usage_events').fetchone()[0] == 1
        status = json.loads((directory / 'collector-status.json').read_text())
        assert status['version'] == c.VERSION and status['startedAt'] <= status['lastBatchAt']
    finally:
        client.close()
        if idle:
            idle.close()
        process.terminate()
        process.wait(timeout=5)
print('PASS: idle HTTP connection times out and the next usage export is stored')
