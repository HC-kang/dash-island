# Source from zsh or bash. Builds the driver once per source hash, then defines:
#   waitidle   wait for IDLE_S (default 15) seconds of pointer stillness; saves HOME_PT
#   ctl_begin  vertical wiggle + "controlling" HUD     ctl_end  HUD off + horizontal wiggle
#   restore    put the pointer back at HOME_PT         at X Y   pointer still at X,Y (global)?
# The user works on the same Mac: always waitidle → ctl_begin → … → restore → ctl_end.
E2E_SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
E2E_BIN="$HOME/Library/Caches/dash-island-checks/e2e"
mkdir -p "$E2E_BIN"
for t in drive hud; do
  h=$(shasum "$E2E_SRC/$t.swift" | cut -c1-12)
  [ -x "$E2E_BIN/$t-$h" ] || swiftc -O "$E2E_SRC/$t.swift" -o "$E2E_BIN/$t-$h" || return 1
  ln -sf "$E2E_BIN/$t-$h" "$E2E_BIN/$t"
done
drive() { "$E2E_BIN/drive" "$@"; }
pos() { drive info | sed -nE 's/^pointer: \(([0-9.]+), ([0-9.]+)\).*/\1 \2/p'; }
waitidle() { local prev cur still=0; prev=$(pos); for i in $(seq 1 600); do sleep 1; cur=$(pos); if [ "$cur" = "$prev" ]; then still=$((still+1)); else still=0; prev=$cur; fi; [ $still -ge ${IDLE_S:-15} ] && break; done; HOME_PT=$prev; }
restore() { echo "$HOME_PT" | xargs "$E2E_BIN/drive" warp; }
ctl_begin() { drive wiggle v; (nohup "$E2E_BIN/hud" >/dev/null 2>&1 &); sleep 0.3; }
ctl_end() { pkill -f "$E2E_BIN/hud" ; drive wiggle h; }
at() { local p; p=$(pos); python3 -c "import sys;x,y=map(float,'$p'.split());sys.exit(0 if abs(x-$1)<3 and abs(y-$2)<3 else 1)"; }
