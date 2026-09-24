# Sourced by scripts/check-*.sh. compile_check <Check.swift> <out-binary>
# Compiles Sources (minus App.swift) + the check once per content hash and reuses
# the binary while nothing changed: repeat runs skip the ~1-4 min swiftc step.
compile_check() {
  local check="$1" out="$2"
  local cache_dir="${DASH_CHECK_CACHE:-$HOME/Library/Caches/dash-island-checks}"
  local sources
  sources=$(find Sources -name '*.swift' ! -path 'Sources/App/App.swift' | sort)
  local key
  # shellcheck disable=SC2086
  key=$( { swiftc --version 2>&1; cat $sources "$check"; } | shasum -a 256 | cut -c1-20)
  mkdir -p "$cache_dir"
  find "$cache_dir" -type f -mtime +7 -delete 2>/dev/null || true
  if [ ! -x "$cache_dir/$key" ]; then
    echo "→ compiling check ($key)"
    # shellcheck disable=SC2086
    swiftc -parse-as-library -target arm64-apple-macos13.0 -O \
      -framework SwiftUI -framework AppKit -framework Combine -framework Security \
      -framework ServiceManagement -framework CoreGraphics \
      $sources "$check" -o "$cache_dir/$key.tmp"
    mv "$cache_dir/$key.tmp" "$cache_dir/$key"
  else
    echo "→ reusing compiled check ($key)"
  fi
  cp "$cache_dir/$key" "$out"
}
