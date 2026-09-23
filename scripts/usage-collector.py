#!/usr/bin/env python3
"""Local, metadata-only OTLP/JSON sink for account-attributed Codex/Claude usage.

Only completed usage events are stored. Raw OTLP payloads (which may include tool
output) never reach disk. Uses Python's stdlib; runs independently of the UI.
"""
import argparse
from datetime import datetime
import hashlib
import hmac
import json
import math
import os
import time
from pathlib import Path
import sqlite3
from http.server import BaseHTTPRequestHandler, HTTPServer

# Bump on every behavior change: connect-usage.py replaces an installed copy with a lower
# VERSION, and collector-status.json reports which copy is running.
VERSION = 2
MAX_BODY = 4 * 1024 * 1024
SCHEMA = """
CREATE TABLE IF NOT EXISTS usage_events (
 provider TEXT NOT NULL, identity TEXT NOT NULL, event_id TEXT NOT NULL,
 timestamp REAL NOT NULL, model TEXT NOT NULL,
 input INTEGER NOT NULL, output INTEGER NOT NULL,
 cache_write INTEGER NOT NULL, cache_read INTEGER NOT NULL,
 dollars REAL, PRIMARY KEY(provider, identity, event_id)
);
"""


def identity(provider, account, organization=""):
    if not isinstance(account, str) or not account or len(account) > 512:
        return None
    if not isinstance(organization, str) or len(organization) > 512:
        return None
    return hashlib.sha256((provider + "\0" + account.lower() + "\0" + organization.lower()).encode()).hexdigest()


def attributes(items):
    out = {}
    for item in items or []:
        value = item.get("value", {})
        for kind in ("stringValue", "intValue", "doubleValue", "boolValue"):
            if kind in value:
                out[item.get("key", "")] = value[kind]
                break
    return out


def integer(value):
    if isinstance(value, bool):
        raise ValueError("boolean counter")
    number = float(value)
    if not math.isfinite(number) or not number.is_integer() or not 0 <= number <= 1e12:
        raise ValueError("invalid counter")
    return int(number)


def parse_record(record, resource):
    a = dict(resource)
    a.update(attributes(record.get("attributes")))
    if a.get("dash_island.purpose") == "auth_refresh":
        return None
    name = a.get("event.name") or (record.get("body") or {}).get("stringValue", "")
    stamp = int(record.get("timeUnixNano") or 0)
    if stamp > 0:
        timestamp = stamp / 1e9
    else:
        # Rust tracing leaves the OTLP timestamp at zero; use its event time,
        # never the collector receive time (which changes on exporter retries).
        stamp = a.get("event.timestamp", "")
        date = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        if date.tzinfo is None:
            return None
        timestamp = date.timestamp()
    if name in ("claude_code.api_request", "api_request"):
        provider = "claude"
        owner = identity(provider, a.get("user.account_uuid"), a.get("organization.id", ""))
        tokens = [integer(a[k]) for k in ("input_tokens", "output_tokens")]
        tokens += [integer(a.get(k, 0)) for k in ("cache_creation_tokens", "cache_read_tokens")]
        event_id = a.get("request_id") or a.get("client_request_id")
        if not event_id:
            session, sequence = a.get("session.id"), a.get("event.sequence")
            if not session or sequence is None:
                return None
            event_id = str(session) + ":" + str(sequence)
        dollars = a.get("cost_usd")
        if dollars is not None:
            dollars = float(dollars)
            if not math.isfinite(dollars) or not 0 <= dollars <= 1e6:
                dollars = None
    elif name == "codex.sse_event" and a.get("event.kind") == "response.completed":
        # Codex emits this completion event for both SSE and WebSocket transports.
        provider = "codex"
        owner = identity(provider, a.get("user.account_id"))
        full_input = integer(a["input_token_count"])
        output = integer(a["output_token_count"])
        read = integer(a.get("cached_token_count", 0))
        write = integer(a.get("cache_write_token_count", 0))
        if read + write > full_input:
            return None
        tokens = [full_input - read - write, output, write, read]
        session = a.get("conversation.id")
        if not session:
            return None
        event_id = str(session) + ":" + str(stamp)
        dollars = None
    else:
        return None
    if not owner or not isinstance(event_id, str) or not 0 < len(event_id) <= 1024:
        return None
    model = a.get("model") or a.get("slug")
    if not isinstance(model, str) or not 0 < len(model) <= 256:
        return None
    if not math.isfinite(timestamp) or timestamp <= 0 or sum(tokens) == 0:
        return None
    return (provider, owner, event_id, timestamp, model, *tokens, dollars)


def ingest(db, payload):
    accepted = 0
    for resource in payload.get("resourceLogs", []):
        common = attributes(resource.get("resource", {}).get("attributes"))
        for scope in resource.get("scopeLogs", []):
            for record in scope.get("logRecords", []):
                try:
                    row = parse_record(record, common)
                except (ValueError, TypeError, KeyError, OverflowError, AttributeError):
                    continue
                if row:
                    cursor = db.execute("INSERT OR IGNORE INTO usage_events VALUES (?,?,?,?,?,?,?,?,?,?)", row)
                    accepted += cursor.rowcount
    db.commit()
    return accepted


def write_status(directory, status):
    temp = directory / "collector-status.tmp"
    temp.write_text(json.dumps(status))
    temp.replace(directory / "collector-status.json")


def serve(directory, port):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    token = (directory / "collector-token").read_text().strip()
    db = sqlite3.connect(directory / "account-usage.sqlite")
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(SCHEMA)
    try:
        status = json.loads((directory / "collector-status.json").read_text())
    except (OSError, ValueError):
        status = {}
    if not isinstance(status, dict):
        status = {}
    # Keep lastBatchAt across restarts; version/startedAt say which copy is running.
    status.update(version=VERSION, startedAt=time.time())
    write_status(directory, status)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Do not log bodies, request headers, URLs, or usage identities.

        def do_POST(self):
            if self.path != "/v1/logs":
                self.send_error(404)
                return
            if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token):
                self.send_error(401)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY or self.headers.get("Transfer-Encoding"):
                    self.send_error(413)
                    return
                if self.headers.get("Content-Encoding", "identity") != "identity":
                    self.send_error(415)
                    return
                raw = self.rfile.read(length)
                if len(raw) != length:
                    self.send_error(400)
                    return
                payload = json.loads(raw)
                if not isinstance(payload, dict):
                    raise ValueError("object required")
                accepted = ingest(db, payload)
                status.update(lastBatchAt=time.time(), accepted=accepted)
                write_status(directory, status)
            except (ValueError, TypeError, KeyError, AttributeError, TimeoutError):
                db.rollback()
                self.send_error(400)
                return
            except sqlite3.Error:
                db.rollback()
                self.send_error(503)  # Exporter may retry; event IDs prevent duplicate totals.
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

    class CollectorServer(HTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            # Apply before BaseHTTPRequestHandler reads the request line/headers.
            # A body-only timeout leaves every later export blocked by an idle client.
            connection.settimeout(5)
            return connection, address

    # ponytail: serial requests bound memory and SQLite writes; a queue is only needed at higher local throughput.
    server = CollectorServer(("127.0.0.1", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--port", type=int, default=43190)
    args = parser.parse_args()
    os.umask(0o077)
    serve(args.directory, args.port)
