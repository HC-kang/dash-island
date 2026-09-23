#!/usr/bin/env bash
# Tail the DashIsland log. Usage: logs.sh [-f] [pattern]
set -euo pipefail
LOG="$HOME/Library/Application Support/DashIsland/logs/dashisland.log"
follow=0
if [[ "${1:-}" == "-f" ]]; then follow=1; shift; fi
pattern="${1:-}"
if (( follow )); then
  tail -n 200 -F "$LOG" | { if [[ -n "$pattern" ]]; then grep --line-buffered -- "$pattern"; else cat; fi; }
else
  tail -n 200 "$LOG" | { if [[ -n "$pattern" ]]; then grep -- "$pattern"; else cat; fi; }
fi
