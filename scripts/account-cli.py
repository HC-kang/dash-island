#!/usr/bin/env python3
"""Run a CLI using a selected Dash Island account, in this terminal's working directory.

Isolation covers what the CLI reads from its home variable, plus the API-key and
provider-routing variables removed below. Proxies, other variables and files outside that
home stay shared. agy finds its login only under $HOME, so everything inside that agy
session, including commands the agent runs, sees the account folder as HOME; git keeps the
user's global config through GIT_CONFIG_GLOBAL, other tools do not find their ~ config.
"""
import json
import os
from pathlib import Path
import shutil
import sys

HOMES = {'codex': 'CODEX_HOME', 'claude': 'CLAUDE_CONFIG_DIR', 'grok': 'GROK_HOME', 'agy': 'HOME'}
# Credentials or routing that would send calls somewhere other than the selected account.
CLEARED = ('OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'ANTHROPIC_API_KEY',
           'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'XAI_API_KEY', 'GROK_API_KEY',
           'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GOOGLE_APPLICATION_CREDENTIALS',
           'ANTHROPIC_BASE_URL', 'OPENAI_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX',
           'CLAUDE_CODE_USE_FOUNDRY')


def launch_environment(account, directory, inherited):
    env = dict(inherited)
    for key in CLEARED:
        env.pop(key, None)
    variable = HOMES.get(account['vendorID'])
    if not variable:
        raise SystemExit('account-cli does not support %s accounts.' % account['vendorID'])
    if variable == 'HOME' and env.get('HOME') and 'GIT_CONFIG_GLOBAL' not in env:
        real = Path(env['HOME'])
        for config in (real / '.gitconfig', Path(env.get('XDG_CONFIG_HOME') or real / '.config') / 'git/config'):
            if config.is_file():
                env['GIT_CONFIG_GLOBAL'] = str(config)
                break
    env[variable] = str(directory)
    return env


def account_directory(base, account):
    # An empty or relative reference would select the folder that holds every account.
    reference = account.get('credentialRef')
    if not isinstance(reference, str) or reference in ('', '.', '..') or '/' in reference:
        raise SystemExit('Account folder is invalid. Reauthenticate in Dash Island.')
    return base / 'accounts' / reference


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
    directory = account_directory(base, account)
    env = launch_environment(account, directory, os.environ)
    binary = shutil.which(account['vendorID'])
    if not binary:
        raise SystemExit(account['vendorID'] + ' is not installed.')
    if not directory.is_dir():
        raise SystemExit('Account folder is missing. Reauthenticate in Dash Island.')
    args = sys.argv[2:]
    if args[:1] == ['--']:
        args = args[1:]
    os.execve(binary, [binary, *args], env)


if __name__ == '__main__':
    main()
