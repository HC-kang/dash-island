#!/usr/bin/env python3
"""Run a CLI using a selected Dash Island account, in this terminal's working directory."""
import json
import os
from pathlib import Path
import shutil
import sys


def launch_environment(account, directory, inherited):
    env = dict(inherited)
    for key in ('OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'ANTHROPIC_API_KEY',
                'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'XAI_API_KEY', 'GROK_API_KEY',
                'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GOOGLE_APPLICATION_CREDENTIALS'):
        env.pop(key, None)
    variable = {'codex': 'CODEX_HOME', 'claude': 'CLAUDE_CONFIG_DIR', 'grok': 'GROK_HOME', 'agy': 'HOME'}[account['vendorID']]
    env[variable] = str(directory)
    return env


def main():
    base = Path.home() / 'Library/Application Support/DashIsland'
    accounts = json.loads((base / 'accounts.json').read_text())
    if len(sys.argv) < 2:
        for a in accounts:
            print(a['id'][:8], a['vendorID'], a['label'])
        raise SystemExit('Usage: account-cli.py <account-id-prefix> [CLI arguments…]')
    matches = [a for a in accounts if a['id'].lower().startswith(sys.argv[1].lower())]
    if len(matches) != 1:
        raise SystemExit('Choose one unique account ID from account-cli.py.')
    account = matches[0]
    binary = shutil.which(account['vendorID'])
    if not binary:
        raise SystemExit(account['vendorID'] + ' is not installed.')
    directory = base / 'accounts' / account['credentialRef']
    if not directory.is_dir():
        raise SystemExit('Account folder is missing. Reauthenticate in Dash Island.')
    args = sys.argv[2:]
    if args[:1] == ['--']:
        args = args[1:]
    env = launch_environment(account, directory, os.environ)
    os.execve(binary, [binary, *args], env)


if __name__ == '__main__':
    main()
